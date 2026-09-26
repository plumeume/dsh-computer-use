# bridge_worker2.ps1 - cadmcp v2 COM worker (ASCII only: PowerShell 5.1 reads BOM-less .ps1 as ANSI).
# Runs inside a runspace created by bridge_server2.ps1, so the TCP listener stays
# responsive while a long AutoCAD/COM call is in flight.
# Output contract: exactly one JSON string, either
#   {"ok":true,"data":{...}}  or  {"ok":false,"code":"X","message":"..."}
param([string]$Op, [string]$ArgsJson)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$A = @{}
if (-not [string]::IsNullOrWhiteSpace($ArgsJson)) { $A = $ArgsJson | ConvertFrom-Json }

function Arg([string]$name, $fallback) {
  if ($null -eq $A) { return $fallback }
  $p = $A.PSObject.Properties[$name]
  if ($null -eq $p) { return $fallback }
  if ($null -eq $p.Value) { return $fallback }
  if (($p.Value -is [string]) -and ([string]$p.Value).Trim().Length -eq 0) { return $fallback }
  return $p.Value
}
# Runtime scratch dir. This script is run via AddScript in a runspace, so it has
# no $PSScriptRoot: the bridge passes the dir as the snapDir arg and/or through
# CADMCP2_SNAP_DIR. TEMP is the last resort.
$SnapDir = [string](Arg 'snapDir' $env:CADMCP2_SNAP_DIR)
if ([string]::IsNullOrWhiteSpace($SnapDir)) { $SnapDir = Join-Path $env:TEMP 'dsh-cad_fig' }
if (-not (Test-Path -LiteralPath $SnapDir)) { New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null }
$SnapDirFwd = $SnapDir.Replace([string][char]92, '/')
function Ok($data) {
  return '{"ok":true,"data":' + (ConvertTo-Json -InputObject $data -Compress -Depth 6) + '}'
}
function Fail([string]$code, [string]$message) {
  return '{"ok":false,"code":' + (ConvertTo-Json -InputObject ([string]$code) -Compress) + ',"message":' + (ConvertTo-Json -InputObject ([string]$message) -Compress) + '}'
}
function HrChain($err) {
  $out = New-Object System.Collections.ArrayList
  $e = $err.Exception
  for ($i = 0; $i -lt 6 -and $null -ne $e; $i++) {
    [void]$out.Add($e.HResult)
    $e = $e.InnerException
  }
  return $out
}
# AutoCAD busy with another call / dialog: worth retrying.
function Test-Retryable($err) {
  foreach ($h in (HrChain $err)) {
    if ($h -eq -2147418111 -or $h -eq -2147417846 -or $h -eq -2147417850) { return $true }
  }
  return $false
}
# AutoCAD process gone (RPC server unavailable / call failed).
function Test-DeadAcad($err) {
  foreach ($h in (HrChain $err)) {
    if ($h -eq -2147023174 -or $h -eq -2147023170 -or $h -eq -2147417848) { return $true }
  }
  return $false
}
function Invoke-Com([scriptblock]$sb, [int]$tries = 5, [int]$baseMs = 250) {
  for ($i = 1; $i -le $tries; $i++) {
    try { return (& $sb) }
    catch {
      if (Test-DeadAcad $_) { throw }
      if (-not (Test-Retryable $_) -or $i -eq $tries) { throw }
      Start-Sleep -Milliseconds ($baseMs * $i)
    }
  }
}
function Get-Session {
  $s = Invoke-Com {
    $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
    $doc = $acad.ActiveDocument
    [pscustomobject]@{ acad = $acad; doc = $doc; ver = [string]$acad.Version }
  }
  if ($null -eq $s) { throw 'AutoCAD COM session not available (GetActiveObject returned nothing)' }
  if ($null -eq $s.doc) { throw 'AutoCAD has no active document' }
  return $s
}
# Reads the state WITHOUT ever inventing a fake "0 entities" answer.
function Get-DocState($s) {
  $cmdactive = -1; $cmdnames = ''; $lastprompt = ''; $ents = -1; $name = ''; $full = ''
  try { $cmdactive = [int]$s.doc.GetVariable('CMDACTIVE') } catch { $cmdactive = -1 }
  try { $cmdnames = [string]$s.doc.GetVariable('CMDNAMES') } catch { $cmdnames = '' }
  try { $lastprompt = [string]$s.doc.GetVariable('LASTPROMPT') } catch { $lastprompt = '' }
  try { $ents = [int]$s.doc.ModelSpace.Count } catch { $ents = -1 }
  try { $name = [string]$s.doc.Name } catch { $name = '' }
  try { $full = [string]$s.doc.FullName } catch { $full = '' }
  return [pscustomobject]@{ doc = $name; docPath = $full; ents = $ents; cmdactive = $cmdactive; cmdnames = $cmdnames; lastprompt = $lastprompt; acadVersion = $s.ver }
}
function Send-Text($s, [string]$text) {
  $payload = ($text -replace '\|', [string][char]10) + [char]10
  Invoke-Com { $s.doc.SendCommand($payload) } | Out-Null
}
# Raw send: no "| means Enter" translation (used for LISP source, which may contain | itself).
function Send-Raw($s, [string]$text) {
  Invoke-Com { $s.doc.SendCommand($text + [char]10) } | Out-Null
}
function Wait-Idle($s, [int]$waitMs, [int]$pollMs = 150) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $ca = 1
  Start-Sleep -Milliseconds ([Math]::Min(250, $pollMs))
  while ($sw.ElapsedMilliseconds -lt $waitMs) {
    try { $ca = [int]$s.doc.GetVariable('CMDACTIVE') } catch { $ca = 1 }
    if ($ca -eq 0) { break }
    Start-Sleep -Milliseconds $pollMs
  }
  return [pscustomobject]@{ cmdactive = $ca; waitedMs = $sw.ElapsedMilliseconds }
}
function Export-Snap($s, [string]$base, [int]$keep) {
  $base = $base -replace '\\', '/'
  $bmp = $base + '.bmp'
  $png = $base + '.png'
  foreach ($f in @($bmp, $png)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
  $lisp = '(if (setq ss (ssget "_X")) (progn (setq d (vla-get-ActiveDocument (vlax-get-acad-object))) (vla-Export d "' + $base + '" "bmp" (vla-get-ActiveSelectionSet d)) (princ "EXPORT-OK")) (princ "EXPORT-EMPTY"))'
  Send-Text $s $lisp
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $bmp) -and $sw.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 200 }
  if (-not (Test-Path -LiteralPath $bmp)) { return $null }
  Add-Type -AssemblyName System.Drawing
  $bytes = [IO.File]::ReadAllBytes($bmp)
  $stream = New-Object System.IO.MemoryStream (,$bytes)
  $img = [System.Drawing.Image]::FromStream($stream)
  $w = $img.Width; $h = $img.Height
  $img.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $img.Dispose(); $stream.Dispose()
  # the BMP is a 6.7MB intermediate: drop it, keep only PNGs
  Remove-Item -LiteralPath $bmp -Force -ErrorAction SilentlyContinue
  if ($keep -gt 0) {
    $dir = Split-Path -Parent ($base -replace '/', [string][char]92)
    foreach ($pat in @('_snap_*.png', '_snap_*.bmp')) {
      $old = @(Get-ChildItem -LiteralPath $dir -Filter $pat -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep)
      foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
  }
  return [pscustomobject]@{ png = $png; bmp = $bmp; bytes = (Get-Item -LiteralPath $png).Length; width = $w; height = $h }
}
function Dump-Model($s, [int]$limit) {
  $ms = $s.doc.ModelSpace
  $count = [int]$ms.Count
  $n = $count
  if ($limit -gt 0 -and $limit -lt $n) { $n = $limit }
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $n; $i++) {
    $e = $ms.Item($i)
    $nm = '?'; $ly = ''; $extra = ''
    try { $nm = [string]$e.ObjectName } catch { $nm = '?' }
    try { $ly = [string]$e.Layer } catch { }
    if ($nm -match 'Text') { try { $extra = ' text=' + [string]$e.TextString } catch { } }
    elseif ($nm -match 'Dimension') { try { $extra = ' meas=' + [string]$e.Measurement } catch { } }
    [void]$sb.AppendLine(('{0} {1} layer={2}{3}' -f $i, ($nm -replace '^AcDb', ''), $ly, $extra))
  }
  return [pscustomobject]@{ count = $count; listed = $n; truncated = ($count -gt $n); text = $sb.ToString() }
}
function Close-AcadDialogs([int]$targetPid) {
  if (-not ('CadDialogs' -as [type])) {
    $src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class CadDialogs {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  delegate bool EnumProc(IntPtr h, IntPtr p);
  public static int Close(int targetPid) {
    List<IntPtr> hits = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == (uint)targetPid && IsWindowVisible(h)) {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        if (sb.ToString() == "#32770") hits.Add(h);
      }
      return true;
    }, IntPtr.Zero);
    foreach (IntPtr h in hits) PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero);
    return hits.Count;
  }
}
'@
    Add-Type -TypeDefinition $src -Language CSharp | Out-Null
  }
  return [CadDialogs]::Close($targetPid)
}
function Get-AcadPid {
  $p = @(Get-Process acad -ErrorAction SilentlyContinue)
  if ($p.Count -eq 0) { return 0 }
  return [int]$p[0].Id
}
function Wait-AcadReady([int]$timeoutMs) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = ''
  while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
    Start-Sleep -Milliseconds 1000
    try {
      $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
      $doc = $acad.ActiveDocument
      $n = [int]$doc.ModelSpace.Count
      $nm = [string]$doc.Name
      $dialogs = 0
      $acadPid = Get-AcadPid
      if ($acadPid -gt 0) { try { $dialogs = Close-AcadDialogs $acadPid } catch { } }
      return [pscustomobject]@{ ok = $true; doc = $nm; ents = $n; acadVersion = [string]$acad.Version; acadPid = $acadPid; dialogsClosed = $dialogs; waitedMs = $sw.ElapsedMilliseconds }
    } catch { $last = $_.Exception.Message }
  }
  return [pscustomobject]@{ ok = $false; message = $last; waitedMs = $sw.ElapsedMilliseconds }
}

try {
  $opName = ([string]$Op).ToUpper()
  switch ($opName) {
    'PING' { return (Ok (@{ pong = $true; workerPid = $PID })) }

    'ECHO' {
      $t = [string](Arg 'text' '')
      $sha = [System.Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t))
      $hex = -join ($sha | ForEach-Object { $_.ToString('x2') })
      return (Ok (@{ bytes = $t.Length; sha1 = $hex; text = $t }))
    }

    'INFO' {
      $s = Get-Session
      $st = Get-DocState $s
      return (Ok (@{ doc = $st.doc; docPath = $st.docPath; ents = $st.ents; cmdactive = $st.cmdactive; cmdnames = $st.cmdnames; lastprompt = $st.lastprompt; acadVersion = $st.acadVersion; acadPid = (Get-AcadPid) }))
    }

    'EXEC' {
      $s = Get-Session
      $pre = Get-DocState $s
      if ($pre.cmdactive -ne 0) {
        return (Ok (@{ status = 'busy'; cmdactive = $pre.cmdactive; cmdnames = $pre.cmdnames; lastprompt = $pre.lastprompt; ents = $pre.ents; doc = $pre.doc }))
      }
      $text = [string](Arg 'commands' '')
      if ($text.Trim().Length -eq 0) { return (Fail 'BAD_ARGS' 'commands is required') }
      $waitMs = [int](Arg 'waitMs' 8000)
      if ($waitMs -lt 1000) { $waitMs = 1000 }
      if ($waitMs -gt 120000) { $waitMs = 120000 }
      $sw = [Diagnostics.Stopwatch]::StartNew()
      Send-Text $s $text
      $idle = Wait-Idle $s $waitMs 150
      $st = Get-DocState $s
      $status = 'done'
      if ($idle.cmdactive -ne 0) { $status = 'timeout' }
      return (Ok (@{ status = $status; ents = $st.ents; doc = $st.doc; cmdactive = $st.cmdactive; cmdnames = $st.cmdnames; lastprompt = $st.lastprompt; ms = $sw.ElapsedMilliseconds }))
    }

    'EVAL' {
      $s = Get-Session
      $pre = Get-DocState $s
      if ($pre.cmdactive -ne 0) {
        return (Ok (@{ status = 'busy'; cmdactive = $pre.cmdactive; cmdnames = $pre.cmdnames; lastprompt = $pre.lastprompt; ents = $pre.ents; doc = $pre.doc }))
      }
      $code = [string](Arg 'code' '')
      if ($code.Trim().Length -eq 0) { return (Fail 'BAD_ARGS' 'code is required') }
      $waitMs = [int](Arg 'waitMs' 15000)
      if ($waitMs -lt 1000) { $waitMs = 1000 }
      if ($waitMs -gt 120000) { $waitMs = 120000 }
      $outFile = $SnapDirFwd + '/_eval.txt'
      if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
      $body = $code
      $nl = [string][char]10
      $lisp = '(setq __cdr (vl-catch-all-apply (function (lambda () (progn ' + $body + ')))))' + $nl + '(setq __f (open "' + $outFile + '" "w"))' + $nl + '(if (vl-catch-all-error-p __cdr) (write-line (strcat "ERR|" (vl-catch-all-error-message __cdr)) __f) (write-line (strcat "OK|" (vl-prin1-to-string __cdr)) __f))' + $nl + '(close __f)'
      $sw = [Diagnostics.Stopwatch]::StartNew()
      Send-Raw $s $lisp
      $idle = Wait-Idle $s $waitMs 150
      $st = Get-DocState $s
      $fileSw = [Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath $outFile) -and $fileSw.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 100 }
      $status = 'done'
      if ($idle.cmdactive -ne 0) { $status = 'timeout' }
      $raw = ''
      $value = $null
      $lispErr = $null
      if (Test-Path -LiteralPath $outFile) {
        $enc = [Text.Encoding]::GetEncoding(936)
        $raw = $enc.GetString([IO.File]::ReadAllBytes($outFile)).Trim()
        if ($raw.StartsWith('OK|')) { $value = $raw.Substring(3) }
        elseif ($raw.StartsWith('ERR|')) { $lispErr = $raw.Substring(4) }
      }
      if ($raw.Length -gt 60000) { $raw = $raw.Substring(0, 60000) }
      return (Ok (@{ status = $status; value = $value; error = $lispErr; raw = $raw; ents = $st.ents; cmdactive = $st.cmdactive; lastprompt = $st.lastprompt; ms = $sw.ElapsedMilliseconds }))
    }

    'SNAP' {
      $s = Get-Session
      $base = [string](Arg 'base' '')
      if ($base.Trim().Length -eq 0) { $base = $SnapDirFwd + '/_snap_' + (Get-Date).ToString('HHmmss_fff') }
      $keep = [int](Arg 'keep' 3)
      $r = Export-Snap $s $base $keep
      if ($null -eq $r) {
        $st = Get-DocState $s
        return (Fail 'SNAP_FAILED' ('no BMP produced (empty drawing, all layers frozen, or export error); lastprompt=' + $st.lastprompt))
      }
      return (Ok (@{ png = $r.png; bmp = $r.bmp; bytes = $r.bytes; width = $r.width; height = $r.height }))
    }

    'DUMP' {
      $s = Get-Session
      $limit = [int](Arg 'limit' 1500)
      $d = Dump-Model $s $limit
      return (Ok (@{ count = $d.count; listed = $d.listed; truncated = $d.truncated; text = $d.text }))
    }

    'REATTACH' {
      $s = Get-Session
      $st = Get-DocState $s
      return (Ok (@{ doc = $st.doc; docPath = $st.docPath; ents = $st.ents; cmdactive = $st.cmdactive; acadVersion = $st.acadVersion; acadPid = (Get-AcadPid) }))
    }

    'ATTACHWAIT' {
      $timeoutMs = [int](Arg 'timeoutMs' 120000)
      $r = Wait-AcadReady $timeoutMs
      if (-not $r.ok) { return (Fail 'ACAD_NOT_READY' ([string]$r.message)) }
      return (Ok (@{ doc = $r.doc; ents = $r.ents; acadVersion = $r.acadVersion; acadPid = $r.acadPid; dialogsClosed = $r.dialogsClosed; waitedMs = $r.waitedMs }))
    }

    'KILLACAD' {
      $procs = @(Get-Process acad -ErrorAction SilentlyContinue)
      $n = $procs.Count
      if ($n -gt 0) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 1200 }
      return (Ok (@{ killed = $n }))
    }

    'STARTACAD' {
      $exe = [string](Arg 'exe' 'C:\Program Files\Autodesk\AutoCAD 2021\acad.exe')
      $dwg = [string](Arg 'dwg' '')
      if (-not (Test-Path -LiteralPath $exe)) { return (Fail 'NO_ACAD_EXE' $exe) }
      if ($dwg.Length -gt 0 -and (Test-Path -LiteralPath $dwg)) {
        Start-Process -FilePath $exe -ArgumentList @('/nologo', $dwg) | Out-Null
      } else {
        Start-Process -FilePath $exe -ArgumentList @('/nologo') | Out-Null
      }
      $r = Wait-AcadReady ([int](Arg 'timeoutMs' 120000))
      if (-not $r.ok) { return (Fail 'ACAD_NOT_READY' ([string]$r.message)) }
      return (Ok (@{ doc = $r.doc; ents = $r.ents; acadVersion = $r.acadVersion; acadPid = $r.acadPid; dialogsClosed = $r.dialogsClosed; waitedMs = $r.waitedMs }))
    }

    default { return (Fail 'UNKNOWN_OP' ('unknown op: ' + $opName)) }
  }
  return (Fail 'NO_RESULT' ('op produced no result: ' + $opName))
}
catch {
  $msg = [string]$_.Exception.Message
  if (Test-DeadAcad $_) { return (Fail 'ACAD_GONE' $msg) }
  return (Fail 'COM_ERROR' $msg)
}
