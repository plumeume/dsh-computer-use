# dsh-computer-use

DeepSeek Harness **0.1.7-native** computer use. `computer_*` drives the real Windows desktop;
`desktop_*` drives an **isolated desktop object** that never touches the real mouse, keyboard or focus.

This is a clean reimplementation of the idea behind `@crazy_th/dsh-computer-use`, not a repackage of it.

## 为什么重写 / Why a rewrite

The 0.1.x-era plugin broke on 0.1.7 in two independent ways, and both are removed here:

| old failure | cause | what this version does |
|---|---|---|
| `ctx.settings.register is not a function` | 0.1.7 deleted the settings service | injects **no** settings service; reads the loader's own `config` object and the `Config` schema defaults |
| every tool call threw | the isolated row installed a global `tools/pre-execute` gate that called the missing settings API | **no global hook at all**; `requireApproval` is enforced per tool |

Both tool families live in one entry, so a single bundle row enables everything.

## 架构 / Architecture

```
lib/index.js            cordis plugin: name / inject / Config / apply, registers 28 tools
lib/shell.js            resolves pwsh (falls back to powershell.exe) and runs one driver per call
lib/keys.js + keymap.json  key validation shared with both drivers
lib/coords.js          0-1000 normalized <-> desktop pixels
lib/windows.js          one window-list format for both desktops
scripts/host-driver.ps1       real desktop: SendInput mouse/keyboard, BitBlt screenshot, windows,
                              Start Menu launch, Win32 clipboard
scripts/isolated-desktop.ps1  isolated desktop: CreateDesktop + keeper/worker + PostMessage input
                              + PrintWindow compositing
scripts/runtime.ps1           cached interop assembly, interpreter choice, key codes
```

One PowerShell process per tool call keeps native state out of the host event loop. The compiled
Win32 interop class is cached in `%TEMP%\dsh-computer-use` and reused, so a warm call is ~0.9 s.

### 隔离桌面的两个 Windows 事实

* **`SendInput` is refused** on a desktop that is not the active input desktop (`ERROR_ACCESS_DENIED`),
  so every keystroke and click is delivered with `PostMessage` (`WM_KEYDOWN/UP`, `WM_CHAR`,
  `WM_LBUTTON*`, `WM_MOUSEWHEEL`) to an explicitly tracked target window.
* **DWM does not composite an inactive desktop**, so there is no desktop DC to `BitBlt` from. The
  picture is rebuilt from per-window `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)` captures composited
  onto a dark canvas.

`invoke` (real desktop) creates/opens the desktop and launches a `keeper` that holds it alive, then
launches one `worker` **on** the desktop per action and waits for its JSON result file.

## 随包分发的 CAD MCP server / Bundled CAD MCP server

`mcp/` 里带了整套 CAD 桥。装这个包就有，不需要在机器上另建一套 cadmcp 目录：

| 文件 | 作用 |
|---|---|
| `mcp/cadmcp2.cjs` | 宿主侧 MCP server（stdio → TCP 8773），零依赖 |
| `mcp/bridge_server2.ps1` | 隔离桌面里的 TCP 监听（worker runspace 隔离，卡住也能答 PING） |
| `mcp/bridge_worker2.ps1` | 真正调 AutoCAD COM 的 worker |

宿主侧入口由 profile 补丁用**包名**定位，不写机器路径——DSH 自带的 profile 就是这么定位包内文件的：

```yaml
- insert:
    - id: mcp-cad
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        transport: stdio
        serverName: cad
        command: !!js 'process.execPath'          # 跑 DSH 的那个 node，不依赖 PATH
        args:
          - !!js >-
            process.getBuiltinModule('node:module').createRequire(baseUrl).resolve('@plumeume/dsh-computer-use/mcp/cadmcp2.cjs')
        failOnStartupError: false
```

两个必须记住的点：

* 文件必须是 **`.cjs`**。本包是 `"type": "module"`，包内 `.js` 一律按 ESM 解析，而 cadmcp2 是 CommonJS，叫 `.js` 会直接 `require is not defined in ES module scope`。
* `exports` 映射里要显式列出该子路径，否则 `require.resolve` 会被 exports 挡掉。

桥的运行时临时目录默认是 **`mcp/cad_fig/`**（跟着桥走，不再依赖机器特定文件夹）：日志 `bridge2.txt`、快照 `_snap*.png`、`_eval.txt`。
两侧都用 `CADMCP2_SNAP_DIR` 覆盖；桥另可传 `-SnapDir` / `-LogPath`。打包 tgz 时该目录被显式排除（`files` 逐项枚举 mcp 文件），日志和快照不会进发行包。

## 工具 / Tools

Real desktop (SendInput, takes the real mouse and focus):
`computer_screenshot` `computer_windows` `computer_click` `computer_type` `computer_keypress`
`computer_scroll` `computer_drag` `computer_launch` `computer_list_apps` `computer_clipboard_read`
`computer_clipboard_write` `computer_wait`

Isolated desktop (posted input, invisible to the real desktop):
`desktop_start` `desktop_stop` `desktop_windows` `desktop_screenshot` `desktop_launch` `desktop_focus`
`desktop_close_window` `desktop_click` `desktop_type` `desktop_keypress` `desktop_scroll` `desktop_drag`
`desktop_wait` `desktop_list_apps` `desktop_clipboard_read` `desktop_clipboard_write`

Not implemented: `computer_observe` / `desktop_observe`. They need a vision LLM provider, which on
0.1.7 is exactly the settings surface that broke the old plugin. Use a screenshot instead.

## 安装 / Install

| 你的 DSH 是怎么装的 | 怎么装这个插件 |
|---|---|
| **桌面端**（DeepSeek Harness.exe） | **设置 → 插件 → 添加插件**，填 `@plumeume/dsh-computer-use`（桌面端 profile 由 Electron 独占，CLI 会拒绝 `--profile desktop`） |
| 全局 CLI（`npm i -g @deepseek-ai/dsh`） | `dsh plugin --profile <profile> add @plumeume/dsh-computer-use` |
| **没有全局 CLI、用 npx 跑 dsh** | `npx -y @deepseek-ai/dsh@alpha plugin --profile <profile> add @plumeume/dsh-computer-use` |
| 从源码开发（link 安装） | 见下面「开发安装」 |

> 只 `npm i -g @plumeume/dsh-computer-use` 不会让插件生效 —— 还必须把它加进 profile 的 `dsh.profile.bundles`
> （上面的命令或 App 界面会做这一步）。

### 开发安装 / Development (link:) install

```powershell
# 1) 让 profile 依赖源码目录
#    <profile>/package.json
#    "dependencies": { "@plumeume/dsh-computer-use": "link:<你的源码目录>" }
# 2) 启用：包名要进 bundles，只写 dependencies 不会加载
#    "dsh": { "profile": { "bundles": [ ..., "@plumeume/dsh-computer-use" ] } }
# 3) 装依赖
pnpm install
```

`link:` 装法下 `node_modules/@plumeume/dsh-computer-use` 是指向源码树的软链，改代码下次 reload 即生效。
但 **`link:` 的裸导入解析不到 DSH 的共享包**（`@deepseek-ai/dsh-tools` 等），需要先跑一次
`scripts/sync-host-deps-desktop.cmd` 把依赖闭包从桌面端内核抽到插件自己的 `node_modules`。
从 npm/市场安装没有这个问题 —— 平台会给装在 profile 里的插件解析共享包。

## 配置 / Config

`lib/index.js` declares every knob; override any of them from the profile patch layer:

```yaml
- id: computer-use
  config:
    requireApproval: false
    actionDelayMs: 80
    callTimeoutMs: 60000
    maxScreenshotWidth: 1600
    maxScreenshotHeight: 1200
    normalizedCoordinates: true
    desktopName: DSHIsolated
```

And the bundle patch itself is deliberately a **plain insert** (no `config:`), because the plugin
market hot-mounts only plain inserts — that way enabling this plugin never needs a restart.

## 安全 / Security

`requireApproval` defaults to **false**, because this harness denies an approval ask outright instead
of prompting, so `true` would make every tool unusable. Set it to `true` on a harness whose approval
prompts a human can actually answer.

`computer_*` injects input into the **real** desktop: it takes the real cursor and can act on whatever
has focus. Prefer `desktop_*` for anything unattended.

The drivers use only documented Win32 APIs through a generated interop assembly, and read/write files
only under `%TEMP%\dsh-computer-use` (interop cache) and `%LOCALAPPDATA%\dsh-computer-use` (keeper pid).

## 排错 / Troubleshooting

* `DSH_CU_TRACE=1` makes the isolated driver print its whole handshake (desktop, keeper, worker,
  wait) on stderr — the fastest way to see where a stuck call is.
* If `desktop_*` hangs, check for an orphan keeper: `Get-Process pwsh` and the pid in
  `%LOCALAPPDATA%\dsh-computer-use\DSHIsolated.keeper.pid`; `desktop_stop` clears both.
* Windows 11 `notepad.exe` and friends are app-execution aliases that hand off to a packaged app, so
  `pid` matching finds nothing; `desktop_launch` therefore diffs the window list before/after.
* A worker that is slow to start shows up as `The isolated desktop worker did not answer within N ms`;
  raise `callTimeoutMs`.

## 验证 / Verification

```powershell
dsh --profile web --dump-config > dump.txt 2> err.txt   # err.txt empty
Select-String -Path dump.txt -Pattern 'dsh-computer-use'
```

Then through the harness: `desktop_start` -> `desktop_launch notepad` -> `desktop_windows` ->
`desktop_screenshot` -> `desktop_stop`, and `computer_screenshot` for the real desktop.

MIT.
