@echo off
rem Rebuild dsh-computer-use\node_modules from the desktop app's bundled dsh runtime.
rem Needs the Electron shell: only an Electron process can read inside app.asar.
setlocal
set ELECTRON_RUN_AS_NODE=1
set "EXE=%LOCALAPPDATA%\Programs\DeepSeek Harness\DeepSeek Harness.exe"
if not exist "%EXE%" ( echo DeepSeek Harness not found at "%EXE%" & pause & exit /b 1 )
"%EXE%" --expose-internals "%~dp0sync-host-deps-desktop.mjs"
if errorlevel 1 ( echo sync failed & pause & exit /b 1 )
echo done.
