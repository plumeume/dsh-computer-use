<#
  dsh-computer-use - real desktop driver (Windows).

  One call performs exactly one action. The request arrives as base64 JSON so no
  quoting layer can mangle it; the single stdout line is the JSON reply and every
  diagnostic goes to stderr.

  Actions: screen, screenshot, windows, foreground, move, click, drag, scroll,
  key, type, launch, listApps, clipboardRead, clipboardWrite.
#>
param([Parameter(Mandatory = $true)][string]$PayloadBase64)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'runtime.ps1')

$payload = Read-DshPayload -PayloadBase64 $PayloadBase64
$action = [string]$payload.action

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace DshHost {
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
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    // The union must carry its LARGEST member (MOUSEINPUT): on x64 a KEYBDINPUT-only
    // union gives Marshal.SizeOf(INPUT) == 32, SendInput then rejects the call and
    // silently does nothing. With MOUSEINPUT included it is 40, which is correct.
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public int type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    public struct InputUnion {
      [FieldOffset(0)] public MOUSEINPUT mi;
      [FieldOffset(0)] public KEYBDINPUT ki;
      [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public int mouseData; public int dwFlags; public int time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public short wVk; public short wScan; public int dwFlags; public int time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public int uMsg; public short wParamL; public short wParamH; }

    const int INPUT_MOUSE = 0;
    const int INPUT_KEYBOARD = 1;
    const int MOUSEEVENTF_MOVE = 0x0001;
    const int MOUSEEVENTF_LEFTDOWN = 0x0002;
    const int MOUSEEVENTF_LEFTUP = 0x0004;
    const int MOUSEEVENTF_RIGHTDOWN = 0x0008;
    const int MOUSEEVENTF_RIGHTUP = 0x0010;
    const int MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    const int MOUSEEVENTF_MIDDLEUP = 0x0040;
    const int MOUSEEVENTF_WHEEL = 0x0800;
    const int MOUSEEVENTF_ABSOLUTE = 0x8000;
    const int MOUSEEVENTF_VIRTUALDESK = 0x4000;
    const int KEYEVENTF_EXTENDEDKEY = 0x0001;
    const int KEYEVENTF_KEYUP = 0x0002;
    const int KEYEVENTF_UNICODE = 0x0004;

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int x, int y, int w, int h, IntPtr src, int sx, int sy, int rop);

    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLengthW(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr handle);

    delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr param);

    static readonly int[] VirtualScreenMetrics = { 76, 77, 78, 79 };

    /// Virtual screen (all monitors) as left, top, width, height.
    public static int[] Screen() {
      int[] metrics = VirtualScreenMetrics;
      return new int[] {
        GetSystemMetrics(metrics[0]), GetSystemMetrics(metrics[1]),
        GetSystemMetrics(metrics[2]), GetSystemMetrics(metrics[3])
      };
    }

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

    public static List<WinInfo> Windows() {
      List<WinInfo> list = new List<WinInfo>();
      EnumWindows(delegate(IntPtr hwnd, IntPtr param) {
        WinInfo info = Describe(hwnd);
        if (info.visible || (info.title != null && info.title.Length > 0)) list.Add(info);
        return true;
      }, IntPtr.Zero);
      return list;
    }

    public static WinInfo Foreground() {
      IntPtr hwnd = GetForegroundWindow();
      if (hwnd == IntPtr.Zero) return null;
      return Describe(hwnd);
    }

    static void Send(INPUT input) {
      INPUT[] array = new INPUT[1];
      array[0] = input;
      uint sent = SendInput(1, array, Marshal.SizeOf(typeof(INPUT)));
      if (sent == 0) throw new InvalidOperationException("SendInput failed with error " + Marshal.GetLastWin32Error());
    }

    static void MouseEvent(int flags, int dx, int dy, int data) {
      INPUT input = new INPUT();
      input.type = INPUT_MOUSE;
      input.U.mi = new MOUSEINPUT();
      input.U.mi.dx = dx;
      input.U.mi.dy = dy;
      input.U.mi.mouseData = data;
      input.U.mi.dwFlags = flags;
      Send(input);
    }

    static int[] Normalize(int x, int y) {
      int[] screen = Screen();
      int width = screen[2];
      int height = screen[3];
      int nx = width <= 1 ? 0 : (int)Math.Round(((x - screen[0]) * 65535.0) / (width - 1));
      int ny = height <= 1 ? 0 : (int)Math.Round(((y - screen[1]) * 65535.0) / (height - 1));
      return new int[] { nx, ny };
    }

    public static void Move(int x, int y) {
      int[] point = Normalize(x, y);
      MouseEvent(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, point[0], point[1], 0);
    }

    public static void Button(int button, bool down) {
      int flag;
      if (button == 2) flag = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
      else if (button == 3) flag = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
      else flag = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
      MouseEvent(flag, 0, 0, 0);
    }

    public static void Wheel(int notches) {
      MouseEvent(MOUSEEVENTF_WHEEL, 0, 0, notches * 120);
    }

    public static void Key(int vk, bool up, bool extended) {
      INPUT input = new INPUT();
      input.type = INPUT_KEYBOARD;
      input.U.ki = new KEYBDINPUT();
      input.U.ki.wVk = (short)vk;
      input.U.ki.wScan = 0;
      int flags = up ? KEYEVENTF_KEYUP : 0;
      if (extended) flags |= KEYEVENTF_EXTENDEDKEY;
      input.U.ki.dwFlags = flags;
      Send(input);
    }

    static void Unicode(int code, bool up) {
      INPUT input = new INPUT();
      input.type = INPUT_KEYBOARD;
      input.U.ki = new KEYBDINPUT();
      input.U.ki.wVk = 0;
      input.U.ki.wScan = (short)code;
      input.U.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
      Send(input);
    }

    /// Literal text. Newline and tab are sent as their real keys because not
    /// every edit control accepts them as a unicode character.
    public static void TypeText(string text) {
      for (int i = 0; i < text.Length; i++) {
        char ch = text[i];
        if (ch == '\r') continue;
        if (ch == '\n') { Key(13, false, false); Key(13, true, false); continue; }
        if (ch == '\t') { Key(9, false, false); Key(9, true, false); continue; }
        Unicode(ch, false);
        Unicode(ch, true);
      }
    }

    public static string GetClipboard() {
      if (!OpenClipboard(IntPtr.Zero)) return null;
      try {
        IntPtr handle = GetClipboardData(13);
        if (handle == IntPtr.Zero) return null;
        IntPtr pointer = GlobalLock(handle);
        if (pointer == IntPtr.Zero) return null;
        try { return Marshal.PtrToStringUni(pointer); } finally { GlobalUnlock(handle); }
      } finally { CloseClipboard(); }
    }

    public static bool SetClipboard(string text) {
      if (!OpenClipboard(IntPtr.Zero)) return false;
      try {
        EmptyClipboard();
        byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
        IntPtr handle = GlobalAlloc(0x0002, (UIntPtr)bytes.Length);
        if (handle == IntPtr.Zero) return false;
        IntPtr target = GlobalLock(handle);
        if (target == IntPtr.Zero) { GlobalFree(handle); return false; }
        Marshal.Copy(bytes, 0, target, bytes.Length);
        GlobalUnlock(handle);
        if (SetClipboardData(13, handle) == IntPtr.Zero) { GlobalFree(handle); return false; }
        return true;
      } finally { CloseClipboard(); }
    }
  }
}
'@
Import-DshNativeType -Source $nativeSource

function Get-DshStartMenuRoots {
  $roots = @()
  if ($env:ProgramData) { $roots += (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') }
  if ($env:APPDATA) { $roots += (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') }
  return $roots | Where-Object { Test-Path $_ }
}

function Resolve-DshStartMenuPath {
  param([Parameter(Mandatory = $true)][string]$Name)
  foreach ($root in Get-DshStartMenuRoots) {
    $hit = Get-ChildItem -Path $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
      Where-Object { $_.BaseName -eq $Name } | Select-Object -First 1
    if ($null -ne $hit) { return $hit.FullName }
  }
  throw "No Start Menu entry named '$Name'. Call listApps for the exact names, or pass an executable path."
}

function Get-DshExtendedKey {
  param([int]$VirtualKey)
  # Arrows, navigation and insert/delete live in the extended scan-code set.
  return ($VirtualKey -in 33, 34, 35, 36, 37, 38, 39, 40, 45, 46)
}

function Invoke-DshKeyCombo {
  param([string[]]$Keys)
  $codes = @()
  foreach ($key in $Keys) { $codes += (Get-DshKeyCode -Key $key) }
  for ($i = 0; $i -lt $codes.Count - 1; $i++) {
    [DshHost.Native]::Key($codes[$i], $false, (Get-DshExtendedKey -VirtualKey $codes[$i]))
  }
  $last = $codes[$codes.Count - 1]
  $extended = Get-DshExtendedKey -VirtualKey $last
  [DshHost.Native]::Key($last, $false, $extended)
  [DshHost.Native]::Key($last, $true, $extended)
  for ($i = $codes.Count - 2; $i -ge 0; $i--) {
    [DshHost.Native]::Key($codes[$i], $true, (Get-DshExtendedKey -VirtualKey $codes[$i]))
  }
}

switch ($action) {
  'screen' {
    $screen = [DshHost.Native]::Screen()
    Emit @{ left = $screen[0]; top = $screen[1]; width = $screen[2]; height = $screen[3] }
  }
  'screenshot' {
    Initialize-DshDrawing
    $screen = [DshHost.Native]::Screen()
    $left = $screen[0]; $top = $screen[1]; $desktopWidth = $screen[2]; $desktopHeight = $screen[3]
    $full = New-Object System.Drawing.Bitmap($desktopWidth, $desktopHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($full)
    $target = $graphics.GetHdc()
    $source = [DshHost.Native]::GetDC([IntPtr]::Zero)
    try {
      # SRCCOPY: the real desktop is the input desktop, so its DC is composited.
      [void][DshHost.Native]::BitBlt($target, 0, 0, $desktopWidth, $desktopHeight, $source, $left, $top, 0x00CC0020)
    } finally {
      [void][DshHost.Native]::ReleaseDC([IntPtr]::Zero, $source)
      $graphics.ReleaseHdc($target)
      $graphics.Dispose()
    }
    $maxWidth = [int](Property-Or $payload 'maxWidth' 1600)
    $maxHeight = [int](Property-Or $payload 'maxHeight' 1200)
    $scale = [Math]::Min(1.0, [Math]::Min($maxWidth / $desktopWidth, $maxHeight / $desktopHeight))
    $imageWidth = [int][Math]::Max(1, [Math]::Round($desktopWidth * $scale))
    $imageHeight = [int][Math]::Max(1, [Math]::Round($desktopHeight * $scale))
    $scaled = New-Object System.Drawing.Bitmap($imageWidth, $imageHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $scaler = [System.Drawing.Graphics]::FromImage($scaled)
    $scaler.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $scaler.DrawImage($full, 0, 0, $imageWidth, $imageHeight)
    $scaler.Dispose()
    $full.Dispose()
    $stream = New-Object System.IO.MemoryStream
    $scaled.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $scaled.Dispose()
    Emit @{
      pngBase64 = [Convert]::ToBase64String($stream.ToArray())
      width = $imageWidth; height = $imageHeight
      desktopWidth = $desktopWidth; desktopHeight = $desktopHeight
      left = $left; top = $top
    }
  }
  'windows' {
    $windows = [DshHost.Native]::Windows()
    Emit @{ count = $windows.Count; windows = @($windows) }
  }
  'foreground' {
    $info = [DshHost.Native]::Foreground()
    if ($null -eq $info) { Emit @{ window = $null } } else { Emit @{ window = $info } }
  }
  'move' {
    [DshHost.Native]::Move([int]$payload.x, [int]$payload.y)
    Emit @{ ok = $true; x = [int]$payload.x; y = [int]$payload.y }
  }
  'click' {
    $x = [int]$payload.x; $y = [int]$payload.y
    $button = [int](Property-Or $payload 'button' 1)
    $clicks = [int](Property-Or $payload 'clicks' 1)
    [DshHost.Native]::Move($x, $y)
    Start-Sleep -Milliseconds 20
    for ($i = 0; $i -lt $clicks; $i++) {
      [DshHost.Native]::Button($button, $false)
      [DshHost.Native]::Button($button, $true)
    }
    Emit @{ ok = $true; x = $x; y = $y; button = $button; clicks = $clicks }
  }
  'drag' {
    $fromX = [int]$payload.fromX; $fromY = [int]$payload.fromY
    $toX = [int]$payload.toX; $toY = [int]$payload.toY
    $duration = [int](Property-Or $payload 'durationMs' 400)
    [DshHost.Native]::Move($fromX, $fromY)
    Start-Sleep -Milliseconds 30
    [DshHost.Native]::Button(1, $false)
    $steps = [Math]::Max(4, [int]($duration / 25))
    for ($i = 1; $i -le $steps; $i++) {
      $t = $i / $steps
      [DshHost.Native]::Move([int][Math]::Round($fromX + ($toX - $fromX) * $t), [int][Math]::Round($fromY + ($toY - $fromY) * $t))
      Start-Sleep -Milliseconds 25
    }
    [DshHost.Native]::Button(1, $true)
    Emit @{ ok = $true }
  }
  'scroll' {
    $amount = [int]$payload.amount
    if ($null -ne $payload.x -and $null -ne $payload.y) {
      [DshHost.Native]::Move([int]$payload.x, [int]$payload.y)
      Start-Sleep -Milliseconds 20
    }
    [DshHost.Native]::Wheel($amount)
    Emit @{ ok = $true; amount = $amount }
  }
  'key' {
    $keys = @($payload.keys)
    Invoke-DshKeyCombo -Keys $keys
    Emit @{ ok = $true; keys = $keys }
  }
  'type' {
    $text = [string]$payload.text
    [DshHost.Native]::TypeText($text)
    Emit @{ ok = $true; length = $text.Length }
  }
  'launch' {
    $path = [string](Property-Or $payload 'path' '')
    $name = [string](Property-Or $payload 'name' '')
    $arguments = @(Property-Or $payload 'arguments' @())
    if ($path -eq '' -and $name -ne '') { $path = Resolve-DshStartMenuPath -Name $name }
    if ($path -eq '') { throw 'launch requires either path or name' }
    $started = if ($arguments.Count -gt 0) {
      Start-Process -FilePath $path -ArgumentList $arguments -PassThru
    } else {
      Start-Process -FilePath $path -PassThru
    }
    $waitMs = [int](Property-Or $payload 'waitMs' 1500)
    Start-Sleep -Milliseconds $waitMs
    $owned = @([DshHost.Native]::Windows() | Where-Object { $_.pid -eq $started.Id })
    Emit @{ ok = $true; pid = $started.Id; path = $path; windows = $owned }
  }
  'listApps' {
    $entries = New-Object System.Collections.ArrayList
    foreach ($root in Get-DshStartMenuRoots) {
      foreach ($item in (Get-ChildItem -Path $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
        [void]$entries.Add(@{ name = $item.BaseName; path = $item.FullName })
      }
    }
    $sorted = @($entries | Sort-Object { $_.name })
    Emit @{ count = $sorted.Count; apps = $sorted }
  }
  'clipboardRead' {
    $text = [DshHost.Native]::GetClipboard()
    if ($null -eq $text) { $text = '' }
    Emit @{ text = $text }
  }
  'clipboardWrite' {
    $text = [string]$payload.text
    $ok = [DshHost.Native]::SetClipboard($text)
    Emit @{ ok = $ok; length = $text.Length }
  }
  default { throw "Unsupported host action: $action" }
}
