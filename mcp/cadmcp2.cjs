#!/usr/bin/env node
'use strict';
/**
 * cadmcp2 - MCP server for a LIVE AutoCAD 2021 session (v2, hardened).
 *
 * Host desktop (DSH spawns this over stdio)  ->  TCP 8773  ->  bridge_server2.ps1
 * on the DSH isolated desktop (AutoCAD COM ROT is not visible across desktops).
 *
 * v2 protocol: framed UTF-8 JSON.  Request and response frames are
 *   "CADMCP2 <byteLength>\n" + <byteLength bytes of JSON>
 * so long payloads (>32KB) and TCP fragmentation are handled on both sides.
 */
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');

const HOST = process.env.CADMCP2_HOST || '127.0.0.1';
const PORT = Number(process.env.CADMCP2_PORT || 8773);
// Runtime scratch dir next to this file: the whole CAD bridge travels as one
// package, so nothing depends on a machine-specific folder. Override with
// CADMCP2_SNAP_DIR (the bridge honours the same variable).
const SNAP_DIR = process.env.CADMCP2_SNAP_DIR || path.join(__dirname, 'cad_fig');

function bridge(op, args, timeoutMs, reqTimeoutMs) {
  return new Promise((resolve, reject) => {
    const payload = { id: 1, op: op, args: args || {} };
    if (reqTimeoutMs) payload.timeoutMs = reqTimeoutMs;
    const body = Buffer.from(JSON.stringify(payload), 'utf8');
    const head = Buffer.from('CADMCP2 ' + body.length + '\n', 'ascii');
    const sock = net.createConnection({ host: HOST, port: PORT });
    const ms = timeoutMs || 30000;
    let buf = Buffer.alloc(0);
    let settled = false;
    const timer = setTimeout(function () {
      if (settled) return;
      settled = true;
      sock.destroy();
      reject(new Error('CAD v2 bridge timed out after ' + ms + 'ms (' + HOST + ':' + PORT +
        ') - is AutoCAD + bridge_server2.ps1 running on the isolated desktop? Try cad_health.'));
    }, ms);
    function settle(fn, v) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { sock.end(); } catch (e) { /* ignore */ }
      fn(v);
    }
    sock.on('connect', function () { sock.write(Buffer.concat([head, body])); });
    sock.on('data', function (d) {
      buf = Buffer.concat([buf, d]);
      const nl = buf.indexOf(0x0a);
      if (nl < 0) return;
      const header = buf.slice(0, nl).toString('ascii').trim();
      const m = /^CADMCP2 (\d+)$/.exec(header);
      if (!m) { settle(reject, new Error('bad bridge response header: ' + header)); return; }
      const len = Number(m[1]);
      if (buf.length < nl + 1 + len) return; // keep accumulating: the frame is split
      let parsed;
      try { parsed = JSON.parse(buf.slice(nl + 1, nl + 1 + len).toString('utf8')); }
      catch (e) { settle(reject, new Error('bad bridge response body: ' + e.message)); return; }
      settle(resolve, parsed);
    });
    sock.on('error', function (e) {
      settle(reject, new Error('CAD v2 bridge unreachable on ' + HOST + ':' + PORT + ' - ' + e.message));
    });
  });
}

function errText(r) {
  return 'CAD bridge error [' + (r.code || 'ERR') + ']: ' + (r.message || 'no message');
}
function pairText(d) {
  if (!d) return '';
  return Object.keys(d).map(function (k) { return k + '=' + d[k]; }).join(' ');
}
function text(s, isError) {
  return { content: [{ type: 'text', text: s }], isError: !!isError };
}
async function call(op, args, ms, reqTimeoutMs) {
  const r = await bridge(op, args, ms, reqTimeoutMs);
  if (!r || r.ok !== true) return { error: (r && r.code) ? r : { code: 'BAD_REPLY', message: JSON.stringify(r) }, data: r && r.data };
  return { data: r.data || {} };
}

const TOOLS = [
  {
    name: 'cad_status',
    description: 'Live AutoCAD state: drawing name, model-space entity count, whether a command is active (CMDACTIVE/CMDNAMES), last command-line prompt, bridge busy/tainted flags.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'cad_exec',
    description: 'Run AutoCAD command-line input in the live session. "|" means Enter, e.g. "_.line|0,0|80,0||". AutoLISP is accepted, e.g. "(setvar \"DIMTXT\" 3.0)". The reply carries status (done/busy/timeout), the resulting entity count and the LASTPROMPT text so silent command errors are visible.',
    inputSchema: {
      type: 'object',
      properties: {
        commands: { type: 'string', description: 'AutoCAD command line input; "|" means Enter.' },
        wait_ms: { type: 'number', description: 'How long to wait for the command to finish before returning status=timeout (default 8000, max 120000).' }
      },
      required: ['commands'],
      additionalProperties: false
    }
  },
  {
    name: 'cad_eval',
    description: 'Evaluate AutoLISP inside the live drawing and return its value or the LISP error text (wrapped in vl-catch-all-apply), so a failed expression is never silent. "|" means Enter. Examples: (getvar "DWGNAME"), (sslength (ssget "_X")), (entget (entlast)).',
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'string', description: 'One or more AutoLISP expressions.' },
        wait_ms: { type: 'number', description: 'Max wait in ms (default 15000).' }
      },
      required: ['code'],
      additionalProperties: false
    }
  },
  {
    name: 'cad_snapshot',
    description: 'Export the current view of the drawing to a unique PNG and return it as an image (desktop screenshots cannot capture AutoCAD model space).',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'cad_dump',
    description: 'List model-space entities (type, layer, text/measurement) as text - for verifying a drawing without a screenshot.',
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'number', description: 'Max entities to list (default 1500).' } },
      additionalProperties: false
    }
  },
  {
    name: 'cad_undo',
    description: 'Undo the last N operations in the live drawing.',
    inputSchema: {
      type: 'object',
      properties: { times: { type: 'number', description: 'How many operations to undo (default 1, max 50).' } },
      additionalProperties: false
    }
  },
  {
    name: 'cad_save',
    description: 'Save (QSAVE) the active drawing in place.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'cad_health',
    description: 'Bridge health: alive/busy/tainted, pending op, last error, acad process id and responsiveness, cached drawing info. Answers even while a command is stuck.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false }
  },
  {
    name: 'cad_restart_acad',
    description: 'Recovery: kill the isolated-desktop acad.exe and start it again (optionally with a dwg path), wait for COM, close the "drawing recovery" dialog. Use when cad_exec reports TIMEOUT/STUCK or cad_health says acad is gone. Unsaved changes are lost.',
    inputSchema: {
      type: 'object',
      properties: {
        dwg: { type: 'string', description: 'Optional drawing path to open after restart.' },
        force: { type: 'boolean', description: 'Kill acad first (default true).' }
      },
      additionalProperties: false
    }
  }
];

async function callTool(name, args) {
  args = args || {};
  switch (name) {
    case 'cad_status': {
      const r = await call('INFO', {}, 15000);
      if (r.error) return text(errText(r.error), true);
      return text('doc=' + r.data.doc + ' ents=' + r.data.ents + ' cmdactive=' + r.data.cmdactive +
        ' cmdnames=' + (r.data.cmdnames || '-') + (r.data.stale ? ' [cached:' : '') +
        (r.data.busy ? ' (a command is in flight)' : '') + (r.data.tainted ? ' [tainted: ' + r.data.taintedReason + ']' : '') +
        (r.data.lastprompt ? ' lastprompt=' + r.data.lastprompt : ''));
    }
    case 'cad_exec': {
      const cmds = String(args.commands || '');
      if (!cmds) return text('commands is required', true);
      const waitMs = Math.max(1000, Math.min(120000, Number(args.wait_ms || 8000)));
      const r = await call('EXEC', { commands: cmds, waitMs: waitMs }, waitMs + 45000, waitMs + 20000);
      if (r.error) return text(errText(r.error), true);
      const d = r.data;
      const tail = ' ents=' + d.ents + ' cmdactive=' + d.cmdactive + (d.cmdnames ? ' cmdnames=' + d.cmdnames : '') +
        (d.lastprompt ? ' lastprompt=' + d.lastprompt : '');
      if (d.status === 'busy') return text('BUSY: AutoCAD is already running a command (' + (d.cmdnames || '?') + ')' + tail, true);
      if (d.status === 'timeout') return text('TIMEOUT: the command is still active after ' + waitMs + 'ms - it may be waiting for input or showing a modal dialog. The bridge stays alive: check cad_health / cad_snapshot, and use cad_restart_acad if it is really stuck.' + tail, true);
      return text('ok(' + (d.ms || 0) + 'ms)' + tail);
    }
    case 'cad_eval': {
      const code = String(args.code || '');
      if (!code) return text('code is required', true);
      const waitMs = Math.max(1000, Math.min(120000, Number(args.wait_ms || 15000)));
      const r = await call('EVAL', { code: code, waitMs: waitMs }, waitMs + 45000, waitMs + 20000);
      if (r.error) return text(errText(r.error), true);
      const d = r.data;
      const head = 'status=' + d.status + ' ents=' + d.ents + ' ms=' + d.ms;
      if (d.error) return text(head + '\nLISP ERROR: ' + d.error, true);
      if (d.status !== 'done') return text('TIMEOUT: expression still running; ' + head + '\nlastprompt=' + d.lastprompt, true);
      return text(head + '\nvalue= ' + (d.value === null || d.value === undefined ? 'nil' : d.value));
    }
    case 'cad_snapshot': {
      const r = await call('SNAP', {}, 120000, 90000);
      if (r.error) return text(errText(r.error), true);
      const p = r.data.png;
      if (!p) return text('unexpected bridge reply: ' + JSON.stringify(r.data), true);
      const b64 = fs.readFileSync(p).toString('base64');
      return {
        content: [
          { type: 'text', text: 'snapshot: ' + p + ' (' + r.data.bytes + ' bytes, ' + r.data.width + 'x' + r.data.height + ')' },
          { type: 'image', data: b64, mimeType: 'image/png' }
        ]
      };
    }
    case 'cad_dump': {
      const limit = Math.max(1, Math.min(20000, Number(args.limit || 1500)));
      const r = await call('DUMP', { limit: limit }, 90000, 60000);
      if (r.error) return text(errText(r.error), true);
      const d = r.data;
      return text('entities=' + d.count + ' listed=' + d.listed + (d.truncated ? ' (truncated)' : '') + '\n' + d.text);
    }
    case 'cad_undo': {
      const n = Math.max(1, Math.min(50, Number(args.times || 1)));
      const r = await call('EXEC', { commands: '_.undo|' + n + '|', waitMs: 15000 }, 60000, 20000);
      if (r.error) return text(errText(r.error), true);
      return text('ok ents=' + r.data.ents + ' status=' + r.data.status);
    }
    case 'cad_save': {
      const r = await call('EXEC', { commands: '_.qsave|', waitMs: 20000 }, 60000, 25000);
      if (r.error) return text(errText(r.error), true);
      return text('ok ents=' + r.data.ents + ' status=' + r.data.status);
    }
    case 'cad_health': {
      const r = await call('HEALTH', {}, 10000);
      if (r.error) return text(errText(r.error), true);
      return text(pairText(r.data));
    }
    case 'cad_restart_acad': {
      const a = { force: args.force === false ? false : true };
      if (args.dwg) a.dwg = String(args.dwg);
      const r = await call('RESTARTACAD', a, 240000, 200000);
      if (r.error) return text(errText(r.error), true);
      return text('acad restarted: ' + pairText(r.data));
    }
    default:
      return text('unknown tool: ' + name, true);
  }
}

function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: id, result: result }) + '\n'); }
function replyError(id, code, message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: id, error: { code: code, message: message } }) + '\n'); }

async function handle(line) {
  let msg;
  try { msg = JSON.parse(line); } catch (e) { return; }
  const id = msg.id;
  const method = msg.method;
  const params = msg.params;
  const isNotification = id === undefined || id === null;
  try {
    if (method === 'initialize') {
      reply(id, {
        protocolVersion: (params && params.protocolVersion) || '2025-06-18',
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'cadmcp2', version: '2.0.0' },
        instructions: 'Live AutoCAD control over the hardened cadmcp v2 bridge. AutoCAD + bridge_server2.ps1 (127.0.0.1:' + PORT + ') must already run on the DSH isolated desktop. Start with cad_health, then cad_status.'
      });
      return;
    }
    if (method === 'notifications/initialized' || method === 'initialized') return;
    if (method === 'ping') { reply(id, {}); return; }
    if (method === 'tools/list') { reply(id, { tools: TOOLS }); return; }
    if (method === 'tools/call') {
      const out = await callTool(params && params.name, params && params.arguments);
      reply(id, out);
      return;
    }
    if (!isNotification) replyError(id, -32601, 'method not found: ' + method);
  } catch (e) {
    if (!isNotification) replyError(id, -32000, String((e && e.message) || e));
  }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', function (chunk) {
  buf += chunk;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).replace(/\r$/, '').trim();
    buf = buf.slice(i + 1);
    if (line) void handle(line);
  }
});
process.stdin.on('end', function () { process.exit(0); });
process.stderr.write('cadmcp2 ready (bridge ' + HOST + ':' + PORT + ', snap dir ' + SNAP_DIR + ')\n');
