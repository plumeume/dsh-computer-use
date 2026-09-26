<#
  dsh-computer-use - isolated desktop driver.

  The script re-invokes itself in three roles:

    invoke  runs on the real desktop. It creates/opens the isolated desktop,
            makes sure a keeper process holds it, launches one worker on it,
            waits for the worker's JSON result file and prints that JSON.
    keeper  a trivial process that lives on the isolated desktop so the desktop
            object survives between tool calls.
    worker  runs on the isolated desktop and performs exactly one action.

  Two Windows facts shape the whole design:

    * SendInput is refused (ERROR_ACCESS_DENIED) for threads that are not
      attached to the active input desktop, so every keystroke and click is
      delivered with PostMessage instead.
    * DWM does not composite an inactive desktop, so there is no desktop DC to
      BitBlt from. The picture is composed from per-window PrintWindow captures.
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('invoke', 'keeper', 'worker')][string]$Role,
  [string]$DesktopName = 'DSHIsolated',
  [string]$Action = '',
  [string]$PayloadBase64 = '',
  [string]$OutFile = '',
  [int]$TimeoutMs = 30000
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime.ps1')
$psExe = Resolve-DshInterpreter
$scriptPath = $PSCommandPath

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DshIso {
  public class WinInfo {
    public long hwnd { get; set; }
    public int pid { get; set; }
    public string className { get; set; }
    public string title { get; set; }
    public bool visible { get; set; }
    public int x { get; set; }
    public int y { get; set; }
    public int width { get; set; }
    public int height { get; set; }
  }

  public static class Native {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
      public int cb;
      public string lpReserved;
      public string lpDesktop;
      public string lpTitle;
      public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
      public short wShowWindow, cbReserved2;
      public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr param);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateDesktop(string name, string device, IntPtr devmode, int flags, uint access, IntPtr attributes);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr OpenDesktop(string name, int flags, bool inherit, uint access);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr desktop);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcess(string application, string commandLine, IntPtr processAttributes, IntPtr threadAttributes,
      bool inheritHandles, uint flags, IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("user32.dll")] static extern bool EnumDesktopWindows(IntPtr desktop, EnumWindowsProc callback, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLengthW(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);

    public static WinInfo Describe(IntPtr hwnd) {
      WinInfo info = new WinInfo();
      info.hwnd = hwnd.ToInt64();
      uint pid = 0;
      GetWindowThreadProcessId(hwnd, out pid);
      info.pid = (int)pid;
      StringBuilder cls = new StringBuilder(256);
      GetClassNameW(hwnd, cls, cls.Capacity);
      info.className = cls.ToString();
      int length = GetWindowTextLengthW(hwnd);
      StringBuilder title = new StringBuilder(Math.Max(2, length + 2));
      GetWindowTextW(hwnd, title, title.Capacity);
      info.title = title.ToString();
      info.visible = IsWindowVisible(hwnd);
      RECT rect;
      if (GetWindowRect(hwnd, out rect)) {
        info.x = rect.Left; info.y = rect.Top;
        info.width = rect.Right - rect.Left; info.height = rect.Bottom - rect.Top;
      }
      return info;
    }

    public static List<WinInfo> DesktopWindows(IntPtr desktop) {
      List<WinInfo> list = new List<WinInfo>();
      EnumDesktopWindows(desktop, delegate(IntPtr hwnd, IntPtr param) {
        WinInfo info = Describe(hwnd);
        if (info.visible || (info.title != null && info.title.Length > 0)) list.Add(info);
        return true;
      }, IntPtr.Zero);
      return list;
    }

    public static IntPtr CreateDesktopHandle(string name) {
      // DESKTOP_ALL_ACCESS covers create-window, enumerate and write access.
      uint access = 0x000F01FF;
      IntPtr handle = CreateDesktop(name, null, IntPtr.Zero, 0, access, IntPtr.Zero);
      if (handle != IntPtr.Zero) return handle;
      handle = OpenDesktop(name, 0, false, access);
      if (handle != IntPtr.Zero) return handle;
      throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "cannot create or open desktop " + name);
    }

    const uint STARTF_USESTDHANDLES = 0x00000100;
    const uint CREATE_NO_WINDOW = 0x08000000;

    /// Start a process directly on the named desktop via STARTUPINFO.lpDesktop.
    public static int LaunchOnDesktop(string desktopName, string application, string commandLine) {
      STARTUPINFO startup = new STARTUPINFO();
      startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      startup.lpDesktop = desktopName;
      // Windows copies the caller's STANDARD handles into the child even when
      // bInheritHandles is FALSE, so a long-lived keeper would hold the caller's
      // stdout pipe open and every capture of this driver would hang after the
      // call actually succeeded. STARTF_USESTDHANDLES with NULL handles opts the
      // child out of that copy entirely; bInheritHandles stays FALSE so no other
      // inheritable handle leaks either.
      startup.dwFlags = (int)STARTF_USESTDHANDLES;
      startup.hStdInput = IntPtr.Zero;
      startup.hStdOutput = IntPtr.Zero;
      startup.hStdError = IntPtr.Zero;
      PROCESS_INFORMATION information;
      if (!CreateProcess(application, commandLine, IntPtr.Zero, IntPtr.Zero, false, CREATE_NO_WINDOW, IntPtr.Zero, null, ref startup, out information)) {
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess failed for " + application);
      }
      CloseHandle(information.hThread);
      CloseHandle(information.hProcess);
      return information.dwProcessId;
    }

    /// Scancode-aware lParam for a keyboard message.
    public static IntPtr KeyLParam(int virtualKey, bool up, bool extended) {
      uint scan = MapVirtualKey((uint)virtualKey, 0);
      long value = 1 | ((long)scan << 16);
      if (extended) value |= 1L << 24;
      if (up) value |= (1L << 30) | (1L << 31);
      return new IntPtr(value);
    }

    public static IntPtr MouseLParam(int x, int y) {
      return new IntPtr((y << 16) | (x & 0xFFFF));
    }

    /// Convert a point on the desktop to client coordinates of hwnd.
    public static int[] ToClient(IntPtr hwnd, int x, int y) {
      POINT point = new POINT();
      point.X = x; point.Y = y;
      ScreenToClient(hwnd, ref point);
      return new int[] { point.X, point.Y };
    }
  }
}
'@
Import-DshNativeType -Source $nativeSource

function Get-DshRuntimeDir {
  $dir = Join-Path $env:LOCALAPPDATA 'dsh-computer-use'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return $dir
}

function Write-DshTrace {
  <#
    Progress tracing for the invoke role. Set DSH_CU_TRACE=1 to see, on stderr,
    every step of the desktop / keeper / worker handshake. The handshake crosses
    process boundaries, so without this a stuck worker looks like a silent hang.
  #>
  param([string]$Message)
  if ($env:DSH_CU_TRACE) { [Console]::Error.WriteLine('TRACE ' + $Message) }
}

function Get-DshStartMenuRoots {
  $roots = @()
  if ($env:ProgramData) { $roots += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') }
  if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') }
  return $roots | Where-Object { Test-Path $_ }
}

function Resolve-DshLaunchTarget {
  <#
    Turn either an executable path or a Start Menu name into a real executable
    plus arguments. CreateProcess cannot start a .lnk, so a shortcut is resolved
    through WScript.Shell first.
  #>
  param([string]$Path, [string]$Name, [string[]]$Arguments)
  $target = $Path
  $targetArguments = @($Arguments)
  if ($target -eq '' -and $Name -ne '') {
    foreach ($root in Get-DshStartMenuRoots) {
      $hit = Get-ChildItem -Path $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $Name } | Select-Object -First 1
      if ($null -ne $hit) { $target = $hit.FullName; break }
    }
    if ($target -eq '') { throw "No Start Menu entry named '$Name'. Call desktop_list_apps for the exact names." }
  }
  if ($target -eq '') { throw 'launch requires either path or name' }
  if ($target.ToLowerInvariant().EndsWith('.lnk')) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($target)
    $resolved = $shortcut.TargetPath
    $fromShortcut = $shortcut.Arguments
    if ($targetArguments.Count -eq 0 -and $fromShortcut) { $targetArguments = @($fromShortcut) }
    $target = $resolved
  }
  return @{ path = $target; arguments = $targetArguments }
}

function Get-IsoTargetWindow {
  param($Payload, $State)
  if ($null -ne $Payload.hwnd) { return [IntPtr][long]$Payload.hwnd }
  if ($null -ne $State.activeWindow) { return [IntPtr][long]$State.activeWindow }
  throw 'No target window selected. Call desktop_launch or desktop_focus first, or pass an explicit hwnd.'
}

# ---------------------------------------------------------------- worker side

function Invoke-IsoWorkerAction {
  param([string]$Action, $Payload, [IntPtr]$Desktop)

  $windows = [DshIso.Native]::DesktopWindows($Desktop)

  switch ($Action) {
    'ping' {
      $width = [DshIso.Native]::GetSystemMetrics(0)
      $height = [DshIso.Native]::GetSystemMetrics(1)
      return @{ metrics = "$width,$height"; desktopWidth = $width; desktopHeight = $height }
    }
    'start' {
      # desktop_start has no work of its own: the invoke role already created the
      # desktop and made sure the keeper holds it, so this only reports metrics.
      $width = [DshIso.Native]::GetSystemMetrics(0)
      $height = [DshIso.Native]::GetSystemMetrics(1)
      return @{ metrics = "$width,$height"; desktopWidth = $width; desktopHeight = $height }
    }
    'windows' {
      return @{ count = $windows.Count; windows = @($windows) }
    }
    'launch' {
      # Match new windows by diffing the window list, not by pid: on Windows 11
      # notepad.exe and friends are app-execution aliases that hand off to a
      # packaged app, so the pid CreateProcess returns owns no window at all.
      $before = @{}
      foreach ($existing in $windows) { $before[[string]$existing.hwnd] = $true }
      $resolved = Resolve-DshLaunchTarget -Path ([string](Property-Or $Payload 'path' '')) -Name ([string](Property-Or $Payload 'name' '')) -Arguments @(Property-Or $Payload 'arguments' @())
      $commandLine = '"' + $resolved.path + '"'
      foreach ($argument in $resolved.arguments) {
        if ($argument -match '\s') { $commandLine += ' "' + $argument + '"' } else { $commandLine += ' ' + $argument }
      }
      $pid2 = [DshIso.Native]::LaunchOnDesktop($DesktopName, $resolved.path, $commandLine)
      $waitMs = [int](Property-Or $Payload 'waitMs' 1500)
      Start-Sleep -Milliseconds $waitMs
      $after = [DshIso.Native]::DesktopWindows($Desktop)
      $fresh = @($after | Where-Object { -not $before.ContainsKey([string]$_.hwnd) })
      if ($fresh.Count -eq 0) { $fresh = @($after | Where-Object { $_.pid -eq $pid2 }) }
      return @{ ok = $true; pid = $pid2; path = $resolved.path; windows = $fresh }
    }
    'focus' {
      $hwnd = [IntPtr][long]$Payload.hwnd
      $entry = $windows | Where-Object { $_.hwnd -eq $hwnd } | Select-Object -First 1
      if ($null -eq $entry) { throw "No window with hwnd $($Payload.hwnd) on the isolated desktop." }
      return @{ ok = $true; hwnd = $hwnd.ToInt64() }
    }
    'close' {
      $hwnd = [IntPtr][long]$Payload.hwnd
      [void][DshIso.Native]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
      Start-Sleep -Milliseconds 220
      return @{ ok = $true; hwnd = $hwnd.ToInt64() }
    }
    'screenshot' {
      Initialize-DshDrawing
      $desktopWidth = [DshIso.Native]::GetSystemMetrics(0)
      $desktopHeight = [DshIso.Native]::GetSystemMetrics(1)
      $canvas = New-Object System.Drawing.Bitmap($desktopWidth, $desktopHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $graphics = [System.Drawing.Graphics]::FromImage($canvas)
      $graphics.Clear([System.Drawing.Color]::FromArgb(255, 24, 24, 28))
      foreach ($entry in $windows) {
        if (-not $entry.visible) { continue }
        if ($entry.width -le 0 -or $entry.height -le 0) { continue }
        if ($entry.x + $entry.width -le 0 -or $entry.y + $entry.height -le 0) { continue }
        $bitmap = New-Object System.Drawing.Bitmap($entry.width, $entry.height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $bitmapGraphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $dc = $bitmapGraphics.GetHdc()
        try {
          # PW_RENDERFULLCONTENT (2) is what makes DWM/UWP surfaces draw.
          [void][DshIso.Native]::PrintWindow([IntPtr][long]$entry.hwnd, $dc, 2)
        } finally {
          $bitmapGraphics.ReleaseHdc($dc)
          $bitmapGraphics.Dispose()
        }
        $graphics.DrawImage($bitmap, $entry.x, $entry.y, $entry.width, $entry.height)
        $bitmap.Dispose()
      }
      $graphics.Dispose()
      $maxWidth = [int](Property-Or $Payload 'maxWidth' 1600)
      $maxHeight = [int](Property-Or $Payload 'maxHeight' 1200)
      $scale = [Math]::Min(1.0, [Math]::Min($maxWidth / $desktopWidth, $maxHeight / $desktopHeight))
      $imageWidth = [int][Math]::Max(1, [Math]::Round($desktopWidth * $scale))
      $imageHeight = [int][Math]::Max(1, [Math]::Round($desktopHeight * $scale))
      $scaled = New-Object System.Drawing.Bitmap($imageWidth, $imageHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $scaler = [System.Drawing.Graphics]::FromImage($scaled)
      $scaler.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $scaler.DrawImage($canvas, 0, 0, $imageWidth, $imageHeight)
      $scaler.Dispose()
      $canvas.Dispose()
      $outPath = [string](Property-Or $Payload 'pngPath' '')
      if ($outPath -eq '') { $outPath = Join-Path (Get-DshRuntimeDir) ('shot-' + [guid]::NewGuid().ToString('N') + '.png') }
      $scaled.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
      $scaled.Dispose()
      return @{ pngPath = $outPath; imageWidth = $imageWidth; imageHeight = $imageHeight; desktopWidth = $desktopWidth; desktopHeight = $desktopHeight }
    }
    'click' {
      $target = Get-IsoTargetWindow -Payload $Payload -State @{ activeWindow = (Property-Or $Payload 'activeWindow' $null) }
      $button = [int](Property-Or $Payload 'button' 1)
      $clicks = [int](Property-Or $Payload 'clicks' 1)
      $point = [DshIso.Native]::ToClient($target, [int]$Payload.x, [int]$Payload.y)
      $down = if ($button -eq 2) { 0x0204 } elseif ($button -eq 3) { 0x0207 } else { 0x0201 }
      $up = if ($button -eq 2) { 0x0205 } elseif ($button -eq 3) { 0x0208 } else { 0x0202 }
      $lParam = [DshIso.Native]::MouseLParam($point[0], $point[1])
      for ($i = 0; $i -lt $clicks; $i++) {
        [void][DshIso.Native]::PostMessage($target, 0x0200, [IntPtr]::Zero, $lParam)
        [void][DshIso.Native]::PostMessage($target, $down, [IntPtr]1, $lParam)
        [void][DshIso.Native]::PostMessage($target, $up, [IntPtr]::Zero, $lParam)
        Start-Sleep -Milliseconds 40
      }
      return @{ ok = $true; hwnd = $target.ToInt64(); x = $Payload.x; y = $Payload.y; clicks = $clicks }
    }
    'scroll' {
      $target = Get-IsoTargetWindow -Payload $Payload -State @{ activeWindow = (Property-Or $Payload 'activeWindow' $null) }
      $amount = [int]$Payload.amount
      $point = [DshIso.Native]::ToClient($target, [int]$Payload.x, [int]$Payload.y)
      $delta = $amount * 120
      $wParam = [IntPtr](([int]$delta -shl 16) -band 0xFFFF0000)
      $lParam = [DshIso.Native]::MouseLParam($point[0], $point[1])
      [void][DshIso.Native]::PostMessage($target, 0x020A, $wParam, $lParam)
      return @{ ok = $true; amount = $amount }
    }
    'drag' {
      $target = Get-IsoTargetWindow -Payload $Payload -State @{ activeWindow = (Property-Or $Payload 'activeWindow' $null) }
      $from = [DshIso.Native]::ToClient($target, [int]$Payload.fromX, [int]$Payload.fromY)
      $to = [DshIso.Native]::ToClient($target, [int]$Payload.toX, [int]$Payload.toY)
      $duration = [int](Property-Or $Payload 'durationMs' 400)
      [void][DshIso.Native]::PostMessage($target, 0x0200, [IntPtr]::Zero, [DshIso.Native]::MouseLParam($from[0], $from[1]))
      [void][DshIso.Native]::PostMessage($target, 0x0201, [IntPtr]1, [DshIso.Native]::MouseLParam($from[0], $from[1]))
      $steps = [Math]::Max(4, [int]($duration / 25))
      for ($i = 1; $i -le $steps; $i++) {
        $t = $i / $steps
        $x = [int][Math]::Round($from[0] + ($to[0] - $from[0]) * $t)
        $y = [int][Math]::Round($from[1] + ($to[1] - $from[1]) * $t)
        [void][DshIso.Native]::PostMessage($target, 0x0200, [IntPtr]1, [DshIso.Native]::MouseLParam($x, $y))
        Start-Sleep -Milliseconds 25
      }
      [void][DshIso.Native]::PostMessage($target, 0x0202, [IntPtr]::Zero, [DshIso.Native]::MouseLParam($to[0], $to[1]))
      return @{ ok = $true }
    }
    'key' {
      $target = Get-IsoTargetWindow -Payload $Payload -State @{ activeWindow = (Property-Or $Payload 'activeWindow' $null) }
      $codes = @()
      foreach ($key in @($Payload.keys)) { $codes += (Get-DshKeyCode -Key $key) }
      for ($i = 0; $i -lt $codes.Count - 1; $i++) {
        [void][DshIso.Native]::PostMessage($target, 0x0100, [IntPtr]$codes[$i], [DshIso.Native]::KeyLParam($codes[$i], $false, $false))
      }
      $last = $codes[$codes.Count - 1]
      [void][DshIso.Native]::PostMessage($target, 0x0100, [IntPtr]$last, [DshIso.Native]::KeyLParam($last, $false, $false))
      [void][DshIso.Native]::PostMessage($target, 0x0101, [IntPtr]$last, [DshIso.Native]::KeyLParam($last, $true, $false))
      for ($i = $codes.Count - 2; $i -ge 0; $i--) {
        [void][DshIso.Native]::PostMessage($target, 0x0101, [IntPtr]$codes[$i], [DshIso.Native]::KeyLParam($codes[$i], $true, $false))
      }
      return @{ ok = $true; keys = @($Payload.keys) }
    }
    'type' {
      $target = Get-IsoTargetWindow -Payload $Payload -State @{ activeWindow = (Property-Or $Payload 'activeWindow' $null) }
      $text = [string]$Payload.text
      foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq [char]13) { continue }
        if ($ch -eq [char]10) {
          [void][DshIso.Native]::PostMessage($target, 0x0100, [IntPtr]13, [DshIso.Native]::KeyLParam(13, $false, $false))
          [void][DshIso.Native]::PostMessage($target, 0x0101, [IntPtr]13, [DshIso.Native]::KeyLParam(13, $true, $false))
          continue
        }
        [void][DshIso.Native]::PostMessage($target, 0x0102, [IntPtr][int]$ch, [IntPtr]1)
      }
      return @{ ok = $true; length = $text.Length }
    }
    'stop' {
      foreach ($entry in $windows) {
        if ($entry.visible) { [void][DshIso.Native]::PostMessage([IntPtr][long]$entry.hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
      }
      Start-Sleep -Milliseconds 350
      return @{ ok = $true }
    }
    'listApps' {
      $entries = New-Object System.Collections.ArrayList
      foreach ($root in Get-DshStartMenuRoots) {
        foreach ($item in (Get-ChildItem -Path $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
          [void]$entries.Add(@{ name = $item.BaseName; path = $item.FullName })
        }
      }
      $sorted = @($entries | Sort-Object { $_.name })
      return @{ count = $sorted.Count; apps = $sorted }
    }
    'clipboardRead' {
      return @{ text = Get-Clipboard -Raw -ErrorAction SilentlyContinue }
    }
    'clipboardWrite' {
      Set-Clipboard -Value ([string]$Payload.text)
      return @{ ok = $true; length = ([string]$Payload.text).Length }
    }
    default { throw "Unsupported isolated action: $Action" }
  }
}

# ---------------------------------------------------------------- role switch

if ($Role -eq 'keeper') {
  # Hold the desktop object alive: while this process is attached to it the
  # desktop is not destroyed between tool calls.
  while ($true) { Start-Sleep -Seconds 300 }
  exit 0
}

if ($Role -eq 'worker') {
  $payload = Read-DshPayload -PayloadBase64 $PayloadBase64
  $desktop = [DshIso.Native]::CreateDesktopHandle($DesktopName)
  $result = $null
  $failure = $null
  try {
    $result = Invoke-IsoWorkerAction -Action $Action -Payload $payload -Desktop $desktop
  } catch {
    $failure = $_.Exception.Message
  } finally {
    [void][DshIso.Native]::CloseDesktop($desktop)
  }
  if ($null -ne $failure) { $result = @{ error = $failure } }
  $json = $result | ConvertTo-Json -Depth 12 -Compress
  if ($OutFile -ne '') {
    [IO.File]::WriteAllText($OutFile, $json, [Text.Encoding]::UTF8)
  } else {
    Write-Output $json
  }
  exit 0
}

# Role = invoke (the only role the DSH host calls)
$runtimeDir = Get-DshRuntimeDir
$keeperPidFile = Join-Path $runtimeDir ($DesktopName + '.keeper.pid')
$payload = Read-DshPayload -PayloadBase64 $PayloadBase64
$desktop = [DshIso.Native]::CreateDesktopHandle($DesktopName)

try {
  if ($Action -eq 'stop') {
    $stopFile = Join-Path $runtimeDir ($DesktopName + '.stop.json')
    $workerArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Role worker -DesktopName ' + $DesktopName + ' -Action stop -OutFile "' + $stopFile + '"'
    try { [void][DshIso.Native]::LaunchOnDesktop($DesktopName, $psExe, $workerArgs) } catch { }
    $deadline = (Get-Date).AddMilliseconds(6000)
    while (-not (Test-Path $stopFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 120 }
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $keeperPidFile) {
      $keeperPid = [int](Get-Content $keeperPidFile -Raw)
      Stop-Process -Id $keeperPid -Force -ErrorAction SilentlyContinue
      Remove-Item $keeperPidFile -Force -ErrorAction SilentlyContinue
    }
    Emit @{ ok = $true; stopped = $true; name = $DesktopName }
    exit 0
  }

  # Make sure a keeper holds the desktop.
  $keeperAlive = $false
  if (Test-Path $keeperPidFile) {
    $keeperPid = 0
    [void][int]::TryParse((Get-Content $keeperPidFile -Raw).Trim(), [ref]$keeperPid)
    if ($keeperPid -gt 0 -and $null -ne (Get-Process -Id $keeperPid -ErrorAction SilentlyContinue)) { $keeperAlive = $true }
  }
  Write-DshTrace ('interpreter=' + $psExe)
  Write-DshTrace ('scriptPath=' + $scriptPath)
  Write-DshTrace ('keeperAlive=' + $keeperAlive)
  $created = $false
  if (-not $keeperAlive) {
    $keeperArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Role keeper -DesktopName ' + $DesktopName
    Write-DshTrace ('launching keeper: ' + $psExe + ' ' + $keeperArgs)
    $keeperPid = [DshIso.Native]::LaunchOnDesktop($DesktopName, $psExe, $keeperArgs)
    Write-DshTrace ('keeper pid=' + $keeperPid)
    [IO.File]::WriteAllText($keeperPidFile, [string]$keeperPid, [Text.Encoding]::UTF8)
    $created = $true
  }

  $resultFile = Join-Path $runtimeDir ($DesktopName + '.' + [guid]::NewGuid().ToString('N') + '.json')
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 12 -Compress)))
  $workerArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Role worker -DesktopName ' + $DesktopName
  $workerArgs += ' -Action ' + $Action + ' -PayloadBase64 ' + $encoded + ' -OutFile "' + $resultFile + '"'
  Write-DshTrace ('launching worker: ' + $psExe + ' ' + $workerArgs)
  Write-DshTrace ('worker pid=' + ([DshIso.Native]::LaunchOnDesktop($DesktopName, $psExe, $workerArgs)))
  Write-DshTrace ('waiting for result file: ' + $resultFile)

  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  $ticks = 0
  while (-not (Test-Path $resultFile) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $ticks++
    if ($ticks % 50 -eq 0) { Write-DshTrace ('still waiting, ' + $ticks + '00 ms') }
  }
  if (-not (Test-Path $resultFile)) { throw "The isolated desktop worker did not answer within $TimeoutMs ms." }
  Write-DshTrace 'result file arrived'
  $json = Get-Content $resultFile -Raw
  Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
  $response = $json | ConvertFrom-Json
  if ($null -ne $response.error) { throw [string]$response.error }
  # The invoke role re-adds the desktop metrics so the Node side learns them once.
  $width = [DshIso.Native]::GetSystemMetrics(0)
  $height = [DshIso.Native]::GetSystemMetrics(1)
  $response | Add-Member -NotePropertyName desktopWidth -NotePropertyValue $width -Force
  $response | Add-Member -NotePropertyName desktopHeight -NotePropertyValue $height -Force
  $response | Add-Member -NotePropertyName created -NotePropertyValue $created -Force
  $response | Add-Member -NotePropertyName name -NotePropertyValue $DesktopName -Force
  Emit $response
} finally {
  if ($Action -ne 'stop') { [void][DshIso.Native]::CloseDesktop($desktop) }
}
