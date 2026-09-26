// sync-host-deps-desktop.mjs - rebuild this link:-installed plugin's own
// node_modules from the DESKTOP app's bundled dsh runtime (app.asar).
//
// WHY
// The profile depends on this plugin with a link: spec pointing at this source tree,
// so Node resolves the real path C:\dsh\computer-use\lib\index.js and then resolves the
// plugin's bare imports from THERE. A `link:` target gets no dependencies installed,
// so without this tree the boot dies with:
//     failed to import ... ERR_MODULE_NOT_FOUND: Cannot find package "@deepseek-ai/dsh-tools"
// and none of the computer_* / desktop_* tools ever register.
//
// The old arrangement junctioned those packages out of the GLOBAL npm dsh install
// (%APPDATA%\npm\node_modules\@deepseek-ai\dsh\node_modules\...). That install is gone
// (2026-09-25 npx cleanup), so the links went dangling and the plugin stopped loading.
//
// WHAT
// Copy the dependency closure of the plugin's runtime peers (deps + peers of
// @deepseek-ai/cordis, dsh-tools, dsh-attachment, schemastery) out of the desktop
// app's app.asar into <plugin>\node_modules. Versions are exactly the ones the
// running harness uses, because they come from the same asar.
//
// Run it through the Electron shell so app.asar is readable (see the .cmd next to
// this file). Idempotent; re-run after a dsh/desktop upgrade.
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, lstatSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';

const appRoot = join(process.env.LOCALAPPDATA ?? '', 'Programs', 'DeepSeek Harness', 'resources', 'app.asar', 'dsh', 'node_modules');
const pluginRoot = process.argv[2] ?? join(process.env.USERPROFILE ?? '', 'dsh', 'computer-use');
const dstRoot = join(pluginRoot, 'node_modules');
const SEEDS = ['@deepseek-ai/cordis', '@deepseek-ai/dsh-tools', '@deepseek-ai/dsh-attachment', '@deepseek-ai/schemastery'];

if (!existsSync(appRoot)) {
    console.error('cannot read the desktop runtime at ' + appRoot);
    process.exit(1);
}
const copied = new Set();
function copyDir(src, dst) {
    mkdirSync(dst, { recursive: true });
    for (const entry of readdirSync(src, { withFileTypes: true })) {
        const s = join(src, entry.name), d = join(dst, entry.name);
        if (entry.isDirectory()) copyDir(s, d);
        else copyFileSync(s, d);
    }
}
const queue = [...SEEDS];
let count = 0;
while (queue.length) {
    const name = queue.shift();
    if (copied.has(name)) continue;
    const src = join(appRoot, ...name.split('/'));
    if (!existsSync(join(src, 'package.json'))) continue;
    let manifest = {};
    try { manifest = JSON.parse(readFileSync(join(src, 'package.json'), 'utf8')); } catch { }
    // drop a dangling junction left by the older link-based setup
    const dst = join(dstRoot, ...name.split('/'));
    try { const st = lstatSync(dst); if (st.isSymbolicLink()) unlinkSync(dst); } catch { }
    copyDir(src, dst);
    copied.add(name);
    count += 1;
    for (const field of ['dependencies', 'peerDependencies', 'optionalDependencies'])
        for (const dep of Object.keys(manifest[field] ?? {})) if (!copied.has(dep)) queue.push(dep);
}
console.log('synced ' + count + ' packages into ' + dstRoot);
