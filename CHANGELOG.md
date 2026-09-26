# Changelog

## 1.0.0 - 2026-09-26

首个公开发布（npm: `@plumeume/dsh-computer-use`）。

- `computer_*` 12 个工具：真实桌面（SendInput 鼠标/键盘、BitBlt 截图、Win32 剪贴板、开始菜单启动）。
- `desktop_*` 16 个工具：隔离桌面对象（CreateDesktop + keeper/worker + PostMessage 输入 + PrintWindow 合成截图），不碰真实鼠标/键盘/焦点。

- 修掉 0.1.7 上旧版插件的两个致命问题：不再依赖被删除的 settings 服务、不再装全局 `tools/pre-execute` 钩子。
