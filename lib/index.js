import { defineTool } from '@deepseek-ai/dsh-tools'
import Schema from '@deepseek-ai/schemastery'
import { normalizeKeys } from './keys.js'
import { toPixelPoint, describeCoordinateSpace } from './coords.js'
import { describeWindows } from './windows.js'
import { invokeHost, invokeIsolated } from './shell.js'

/**
 * dsh-computer-use - computer use for DeepSeek Harness 0.1.7.
 *
 * Deliberate differences from the 0.1.x-era plugin this replaces:
 *
 *   * No settings service. The old row called ctx.settings.register/get, which
 *     0.1.7 removed; every call here reads the loader's own config object, so the
 *     plugin cannot be broken by the settings API changing again.
 *   * No global tools/pre-execute hook. The old isolated row installed one to ask
 *     for approval, and when the settings lookup threw, that hook made every tool
 *     call in the profile fail. requireApproval is enforced per tool instead.
 *   * Both tool families live in one entry, so one bundle row enables everything.
 *
 * The Win32 work is not reimplemented in JavaScript: a driver process per call
 * keeps native state (input, capture, desktops) out of the host event loop.
 */
export const name = 'computer-use'

// 'attachments' is what turns a captured PNG into an image the model can see.
export const inject = ['tools', 'attachments']

export const Config = Schema.object({
  // This harness denies every approval ask outright, so a true default would
  // make every tool unusable. See the bundle patch for the full explanation.
  requireApproval: Schema.boolean().default(false),
  actionDelayMs: Schema.number().default(80),
  callTimeoutMs: Schema.number().default(60000),
  maxScreenshotWidth: Schema.number().default(1600),
  maxScreenshotHeight: Schema.number().default(1200),
  // true: pointer coordinates are 0-1000 over the desktop (resolution
  // independent). false: they are literal desktop pixels.
  normalizedCoordinates: Schema.boolean().default(true),
  desktopName: Schema.string().default('DSHIsolated'),
})

const imageSchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    attachment: {
      type: 'object',
      required: true,
      additionalProperties: false,
      properties: {
        attachmentId: { type: 'string', required: true },
        mediaType: { type: 'string', required: true },
        bytes: { type: 'integer', required: true },
        width: { type: 'integer', required: true },
        height: { type: 'integer', required: true },
        name: { type: 'string' },
      },
    },
    width: { type: 'integer', required: true },
    height: { type: 'integer', required: true },
    desktopWidth: { type: 'integer', required: true },
    desktopHeight: { type: 'integer', required: true },
  },
}

function textOutput() {
  return { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] }
}

function imageOutput(caption) {
  return {
    schema: imageSchema,
    render: (_args, value) => [
      { type: 'image', attachment: value.attachment },
      { type: 'text', text: caption(value) },
    ],
  }
}

function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

function assertInteger(value, label) {
  if (!Number.isInteger(value)) throw new Error(label + ' must be an integer')
}

function assertDuration(value, label) {
  assertInteger(value, label)
  if (value < 0 || value > 10000) throw new Error(label + ' must be between 0 and 10000')
}

function assertText(value, label) {
  if (typeof value !== 'string') throw new Error(label + ' must be a string')
  if (value.length === 0) throw new Error(label + ' must not be empty')
  if (value.length > 10000) throw new Error(label + ' exceeds the 10000 character limit')
}

function buttonNumber(name) {
  if (name === 'right') return 2
  if (name === 'middle') return 3
  return 1
}

export function apply(ctx, config) {
  const callTimeout = Number(config.callTimeoutMs) || 60000
  const actionDelay = Number(config.actionDelayMs) || 0
  const normalized = config.normalizedCoordinates !== false
  const desktopName = typeof config.desktopName === 'string' && config.desktopName !== '' ? config.desktopName : 'DSHIsolated'

  const assertAllowed = (tool) => {
    if (config.requireApproval) {
      throw new Error(tool + ' is blocked: requireApproval is true in this profile, but this harness denies an approval ask outright instead of prompting.'
        + ' Set requireApproval: false in the profile patch, or run on a harness whose approval prompts a human can answer.')
    }
  }

  // ------------------------------------------------------------ real desktop

  // Virtual screen bounds, learned once per plugin instance.
  let hostBounds = null
  const ensureHostBounds = async () => {
    if (hostBounds === null) {
      const result = await invokeHost('screen', {}, callTimeout)
      hostBounds = { left: result.left, top: result.top, width: result.width, height: result.height }
    }
    return hostBounds
  }
  const hostPixels = async (x, y) => toPixelPoint(x, y, await ensureHostBounds(), normalized)

  // -------------------------------------------------------- isolated desktop

  // Pixel size of the isolated desktop, learned from start / ping / screenshot
  // so normalized coordinates can be converted.
  let desktopSize = null
  // The window the agent last acted on. A hidden desktop has no reliable
  // foreground window, so keystrokes are posted to this explicit target.
  let activeWindow = null

  const ensureDesktopSize = async () => {
    if (desktopSize === null) {
      const result = await invokeIsolated('ping', {}, callTimeout, desktopName)
      desktopSize = { width: result.desktopWidth, height: result.desktopHeight }
    }
    return desktopSize
  }

  const desktopPixels = async (x, y) => {
    if (!normalized) return { x, y }
    return toPixelPoint(x, y, await ensureDesktopSize(), true)
  }

  const learnDesktopSize = (result) => {
    if (result && typeof result.desktopWidth === 'number' && typeof result.desktopHeight === 'number') {
      desktopSize = { width: result.desktopWidth, height: result.desktopHeight }
    }
  }

  // Remember the most useful window of a result so desktop_type / desktop_keypress
  // have a target even when the agent only launched or listed.
  const learnActiveWindow = (windows, preferNew) => {
    if (!Array.isArray(windows) || windows.length === 0) return
    const visible = windows.filter(w => w.visible)
    const pick = (visible.length > 0 ? visible : windows)[0]
    if (preferNew || activeWindow === null) activeWindow = pick.hwnd
  }

  const desktopPayload = (args, extra) => {
    const payload = Object.assign({ activeWindow: activeWindow }, extra || {})
    if (args && args.hwnd !== undefined && args.hwnd !== null) payload.hwnd = args.hwnd
    return payload
  }

  const desktopCall = (action, args, extra) => invokeIsolated(action, desktopPayload(args, extra), callTimeout, desktopName)

  const desktopTargetNote = () => activeWindow === null
    ? 'No target window yet: call desktop_launch or desktop_focus first.'
    : 'Target window: hwnd=' + activeWindow + '.'

  // ------------------------------------------------------------------ tools

  ctx.tools.register(defineTool({
    name: 'computer_screenshot',
    description: 'Capture the current Windows virtual desktop. Inspect this image before choosing coordinates for another computer tool.',
    parameters: {},
    output: imageOutput(value => 'Screenshot captured: ' + value.width + 'x' + value.height + '. '
      + describeCoordinateSpace(normalized, { width: value.desktopWidth, height: value.desktopHeight })),
    async execute() {
      if (ctx.attachments === undefined) throw new Error('Screenshot storage is unavailable in this DSH profile.')
      const image = await invokeHost('screenshot', { maxWidth: config.maxScreenshotWidth, maxHeight: config.maxScreenshotHeight }, callTimeout)
      hostBounds = { left: image.left, top: image.top, width: image.desktopWidth, height: image.desktopHeight }
      const attachment = await ctx.attachments.saveImage({
        data: Buffer.from(image.pngBase64, 'base64'),
        mediaType: 'image/png',
        name: 'computer-screenshot.png',
      })
      return { attachment, width: image.width, height: image.height, desktopWidth: image.desktopWidth, desktopHeight: image.desktopHeight }
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_windows',
    description: 'List the top-level windows currently open on the real desktop.',
    parameters: {},
    output: textOutput(),
    async execute() {
      const result = await invokeHost('windows', {}, callTimeout)
      return describeWindows(result.windows, '(no windows)')
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_click',
    description: 'Move the real pointer to a screen coordinate and click. Uses SendInput, so it takes the real mouse and focus.',
    parameters: {
      x: { type: 'integer', required: true },
      y: { type: 'integer', required: true },
      button: { type: 'string', default: 'left' },
      clicks: { type: 'integer', default: 1 },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('computer_click')
      const point = await hostPixels(args.x, args.y)
      const result = await invokeHost('click', {
        x: point.x, y: point.y,
        button: buttonNumber(args.button),
        clicks: Math.min(3, Math.max(1, args.clicks || 1)),
      }, callTimeout)
      await wait(actionDelay)
      return 'Clicked ' + (args.button || 'left') + ' at (' + point.x + ', ' + point.y + ') on the real desktop. ' + JSON.stringify(result)
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_type',
    description: 'Type Unicode text into the focused control of the real desktop.',
    parameters: { text: { type: 'string', required: true } },
    output: textOutput(),
    async execute(args) {
      assertAllowed('computer_type')
      assertText(args.text, 'text')
      await invokeHost('type', { text: args.text }, callTimeout)
      await wait(actionDelay)
      return 'Typed ' + args.text.length + ' character(s) into the real desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_keypress',
    description: 'Press one key or a shortcut such as CTRL+L on the real desktop.',
    parameters: { keys: { type: 'array', items: { type: 'string' }, required: true } },
    output: textOutput(),
    async execute(args) {
      assertAllowed('computer_keypress')
      const keys = normalizeKeys(args.keys)
      await invokeHost('key', { keys }, callTimeout)
      await wait(actionDelay)
      return 'Pressed ' + keys.join('+') + ' on the real desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_scroll',
    description: 'Scroll the real desktop. Positive amounts scroll up, negative scroll down.',
    parameters: {
      amount: { type: 'integer', required: true },
      x: { type: 'integer' },
      y: { type: 'integer' },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('computer_scroll')
      const payload = { amount: args.amount }
      if (args.x !== undefined && args.y !== undefined) {
        const point = await hostPixels(args.x, args.y)
        payload.x = point.x
        payload.y = point.y
      }
      await invokeHost('scroll', payload, callTimeout)
      return 'Scrolled ' + args.amount + ' notch(es) on the real desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_drag',
    description: 'Drag from one real screen coordinate to another.',
    parameters: {
      fromX: { type: 'integer', required: true },
      fromY: { type: 'integer', required: true },
      toX: { type: 'integer', required: true },
      toY: { type: 'integer', required: true },
      durationMs: { type: 'integer', default: 400 },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('computer_drag')
      assertDuration(args.durationMs === undefined ? 400 : args.durationMs, 'durationMs')
      const from = await hostPixels(args.fromX, args.fromY)
      const to = await hostPixels(args.toX, args.toY)
      await invokeHost('drag', { fromX: from.x, fromY: from.y, toX: to.x, toY: to.y, durationMs: args.durationMs || 400 }, callTimeout)
      await wait(actionDelay)
      return 'Dragged (' + from.x + ', ' + from.y + ') -> (' + to.x + ', ' + to.y + ') on the real desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_launch',
    description: 'Launch an application on the real desktop, by executable path or by exact Start Menu app name (see computer_list_apps).',
    parameters: {
      path: { type: 'string' },
      name: { type: 'string' },
      arguments: { type: 'array', items: { type: 'string' } },
      waitMs: { type: 'integer', default: 1500 },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('computer_launch')
      if (!args.path && !args.name) throw new Error('launch requires either path or name')
      const result = await invokeHost('launch', {
        path: args.path || '',
        name: args.name || '',
        arguments: Array.isArray(args.arguments) ? args.arguments : [],
        waitMs: args.waitMs === undefined ? 1500 : args.waitMs,
      }, callTimeout)
      return 'Launched ' + (args.name ? '"' + args.name + '"' : args.path) + ' (pid ' + result.pid + ') on the real desktop.\n'
        + describeWindows(result.windows, '(no new windows yet)')
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_list_apps',
    description: 'List the applications in the Start Menu so computer_launch can start one by exact name.',
    parameters: {},
    output: textOutput(),
    async execute() {
      const result = await invokeHost('listApps', {}, callTimeout)
      const apps = Array.isArray(result.apps) ? result.apps : []
      if (apps.length === 0) return '(no Start Menu entries found)'
      return apps.map(app => '- ' + app.name).join('\n') + '\n(' + apps.length + ' entries)'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_clipboard_read',
    description: 'Read the current clipboard text. The clipboard is shared with the isolated desktop.',
    parameters: {},
    output: textOutput(),
    async execute() {
      const result = await invokeHost('clipboardRead', {}, callTimeout)
      const text = typeof result.text === 'string' ? result.text : ''
      if (text.length === 0) return '(the clipboard is empty)'
      if (text.length > 20000) return text.slice(0, 20000) + '\n[truncated, ' + text.length + ' characters total]'
      return text
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_clipboard_write',
    description: 'Replace the clipboard text. The clipboard is shared with the isolated desktop.',
    parameters: { text: { type: 'string', required: true } },
    output: textOutput(),
    async execute(args) {
      assertText(args.text, 'text')
      await invokeHost('clipboardWrite', { text: args.text }, callTimeout)
      return 'Wrote ' + args.text.length + ' character(s) to the clipboard.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'computer_wait',
    description: 'Wait briefly for the real desktop to finish updating before taking another screenshot.',
    parameters: { durationMs: { type: 'integer', default: 500 } },
    output: textOutput(),
    async execute(args) {
      const duration = args.durationMs === undefined ? 500 : args.durationMs
      assertDuration(duration, 'durationMs')
      await wait(duration)
      return 'Waited ' + duration + ' ms.'
    },
  }))

  // --------------------------------------------------------- isolated desktop

  ctx.tools.register(defineTool({
    name: 'desktop_start',
    description: 'Start (or reuse) an isolated Windows desktop. GUI applications launched there run in a separate desktop object: they never appear on the real desktop and never take the real mouse, keyboard or foreground focus.',
    parameters: {},
    output: textOutput(),
    async execute() {
      assertAllowed('desktop_start')
      const result = await invokeIsolated('start', {}, callTimeout, desktopName)
      learnDesktopSize(result)
      return 'Isolated desktop ' + result.name + ' is ready (' + (result.created ? 'newly created' : 'reused')
        + '). Display ' + result.desktopWidth + 'x' + result.desktopHeight
        + '. Everything driven here stays off the real desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_stop',
    description: 'Close every application on the isolated desktop and tear the desktop down. The real desktop is never touched.',
    parameters: {},
    output: textOutput(),
    async execute() {
      await invokeIsolated('stop', {}, callTimeout, desktopName)
      activeWindow = null
      desktopSize = null
      return 'Isolated desktop stopped and all of its windows were closed.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_windows',
    description: 'List the windows currently open on the isolated desktop.',
    parameters: {},
    output: textOutput(),
    async execute() {
      const result = await desktopCall('windows', null)
      learnActiveWindow(result.windows, false)
      return describeWindows(result.windows, '(no windows on the isolated desktop)') + '\n' + desktopTargetNote()
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_screenshot',
    description: 'Capture the isolated desktop and return it as an image. An inactive desktop is not composited by DWM, so the picture is rebuilt from per-window captures.',
    parameters: {},
    output: imageOutput(value => 'Isolated desktop ' + value.width + 'x' + value.height
      + ' (desktop ' + value.desktopWidth + 'x' + value.desktopHeight + '). '
      + describeCoordinateSpace(normalized, { width: value.desktopWidth, height: value.desktopHeight })),
    async execute() {
      if (ctx.attachments === undefined) throw new Error('Image storage is unavailable in this DSH profile.')
      const os = await import('node:os')
      const path = await import('node:path')
      const fs = await import('node:fs/promises')
      const pngPath = path.join(os.tmpdir(), 'dsh-isolated-' + Date.now() + '-' + Math.random().toString(16).slice(2) + '.png')
      try {
        const result = await invokeIsolated('screenshot', {
          maxWidth: config.maxScreenshotWidth,
          maxHeight: config.maxScreenshotHeight,
          pngPath,
        }, callTimeout, desktopName)
        const data = await fs.readFile(result.pngPath || pngPath)
        learnDesktopSize(result)
        const attachment = await ctx.attachments.saveImage({ data, mediaType: 'image/png', name: 'isolated-desktop.png' })
        return {
          attachment,
          width: result.imageWidth,
          height: result.imageHeight,
          desktopWidth: result.desktopWidth,
          desktopHeight: result.desktopHeight,
        }
      } finally {
        await fs.rm(pngPath, { force: true })
      }
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_launch',
    description: 'Launch a program on the isolated desktop, by executable path or by exact Start Menu app name (see desktop_list_apps). Windows opened by the program become the active target for desktop_type and desktop_keypress.',
    parameters: {
      path: { type: 'string' },
      name: { type: 'string' },
      arguments: { type: 'array', items: { type: 'string' } },
      waitMs: { type: 'integer', default: 1500 },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('desktop_launch')
      if (!args.path && !args.name) throw new Error('launch requires either path or name')
      const result = await desktopCall('launch', args, {
        path: args.path || '',
        name: args.name || '',
        arguments: Array.isArray(args.arguments) ? args.arguments : [],
        waitMs: args.waitMs === undefined ? 1500 : args.waitMs,
      })
      learnDesktopSize(result)
      learnActiveWindow(result.windows, true)
      return 'Launched ' + (args.name ? '"' + args.name + '"' : args.path) + ' (pid ' + result.pid + ') on the isolated desktop.\n'
        + describeWindows(result.windows, '(no new windows appeared yet)') + '\n' + desktopTargetNote()
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_focus',
    description: 'Select the window on the isolated desktop that desktop_type and desktop_keypress should talk to.',
    parameters: { hwnd: { type: 'integer', required: true } },
    output: textOutput(),
    async execute(args) {
      const result = await desktopCall('focus', args)
      activeWindow = result.hwnd
      return 'Target window is now hwnd=' + result.hwnd + '.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_close_window',
    description: 'Ask a window on the isolated desktop to close (sends WM_CLOSE).',
    parameters: { hwnd: { type: 'integer', required: true } },
    output: textOutput(),
    async execute(args) {
      assertAllowed('desktop_close_window')
      await desktopCall('close', args)
      if (activeWindow === args.hwnd) activeWindow = null
      return 'Asked hwnd=' + args.hwnd + ' to close.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_click',
    description: 'Click on the isolated desktop. Coordinates are desktop-level; the click is posted to the target window.',
    parameters: {
      x: { type: 'integer', required: true },
      y: { type: 'integer', required: true },
      button: { type: 'string', default: 'left' },
      clicks: { type: 'integer', default: 1 },
      hwnd: { type: 'integer' },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('desktop_click')
      const point = await desktopPixels(args.x, args.y)
      const result = await desktopCall('click', args, {
        x: point.x, y: point.y,
        button: buttonNumber(args.button),
        clicks: Math.min(3, Math.max(1, args.clicks || 1)),
      })
      if (result.hwnd !== undefined) activeWindow = result.hwnd
      await wait(actionDelay)
      return 'Clicked ' + (args.button || 'left') + ' at (' + point.x + ', ' + point.y + ') on the isolated desktop (hwnd=' + result.hwnd + ').'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_type',
    description: 'Type Unicode text into the focused control of the active window on the isolated desktop. Input is posted, not injected, because an inactive desktop refuses SendInput.',
    parameters: {
      text: { type: 'string', required: true },
      hwnd: { type: 'integer' },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('desktop_type')
      assertText(args.text, 'text')
      await desktopCall('type', args, { text: args.text })
      await wait(actionDelay)
      return 'Typed ' + args.text.length + ' character(s) into hwnd=' + (args.hwnd === undefined ? activeWindow : args.hwnd) + ' on the isolated desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_keypress',
    description: 'Press a key or shortcut such as ENTER, TAB, ESC or CTRL+S on the active window of the isolated desktop.',
    parameters: {
      keys: { type: 'array', items: { type: 'string' }, required: true },
      hwnd: { type: 'integer' },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('desktop_keypress')
      const keys = normalizeKeys(args.keys)
      await desktopCall('key', args, { keys })
      await wait(actionDelay)
      return 'Pressed ' + keys.join('+') + ' on the isolated desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_scroll',
    description: 'Scroll on the isolated desktop. Positive amounts scroll up, negative scroll down.',
    parameters: {
      x: { type: 'integer', required: true },
      y: { type: 'integer', required: true },
      amount: { type: 'integer', required: true },
      hwnd: { type: 'integer' },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('desktop_scroll')
      const point = await desktopPixels(args.x, args.y)
      await desktopCall('scroll', args, { x: point.x, y: point.y, amount: args.amount })
      return 'Scrolled ' + args.amount + ' notch(es) on the isolated desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_drag',
    description: 'Drag on the isolated desktop.',
    parameters: {
      fromX: { type: 'integer', required: true },
      fromY: { type: 'integer', required: true },
      toX: { type: 'integer', required: true },
      toY: { type: 'integer', required: true },
      durationMs: { type: 'integer', default: 400 },
      hwnd: { type: 'integer' },
    },
    output: textOutput(),
    async execute(args) {
      assertAllowed('desktop_drag')
      const from = await desktopPixels(args.fromX, args.fromY)
      const to = await desktopPixels(args.toX, args.toY)
      await desktopCall('drag', args, {
        fromX: from.x, fromY: from.y, toX: to.x, toY: to.y,
        durationMs: args.durationMs === undefined ? 400 : args.durationMs,
      })
      return 'Dragged (' + from.x + ', ' + from.y + ') -> (' + to.x + ', ' + to.y + ') on the isolated desktop.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_wait',
    description: 'Wait for an application on the isolated desktop to finish updating, then take another screenshot.',
    parameters: { durationMs: { type: 'integer', default: 500 } },
    output: textOutput(),
    async execute(args) {
      const duration = args.durationMs === undefined ? 500 : args.durationMs
      assertDuration(duration, 'durationMs')
      await wait(duration)
      return 'Waited ' + duration + ' ms.'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_list_apps',
    description: 'List the applications in the Start Menu so desktop_launch can start one by exact name.',
    parameters: {},
    output: textOutput(),
    async execute() {
      const result = await desktopCall('listApps', null)
      const apps = Array.isArray(result.apps) ? result.apps : []
      if (apps.length === 0) return '(no Start Menu entries found)'
      return apps.map(app => '- ' + app.name).join('\n') + '\n(' + apps.length + ' entries)'
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_clipboard_read',
    description: 'Read the current clipboard text. The clipboard is shared with the real desktop.',
    parameters: {},
    output: textOutput(),
    async execute() {
      const result = await desktopCall('clipboardRead', null)
      const text = typeof result.text === 'string' ? result.text : ''
      if (text.length === 0) return '(the clipboard is empty)'
      if (text.length > 20000) return text.slice(0, 20000) + '\n[truncated, ' + text.length + ' characters total]'
      return text
    },
  }))

  ctx.tools.register(defineTool({
    name: 'desktop_clipboard_write',
    description: 'Replace the clipboard text. The clipboard is shared with the real desktop.',
    parameters: { text: { type: 'string', required: true } },
    output: textOutput(),
    async execute(args) {
      assertText(args.text, 'text')
      await desktopCall('clipboardWrite', null, { text: args.text })
      return 'Wrote ' + args.text.length + ' character(s) to the clipboard.'
    },
  }))
}
