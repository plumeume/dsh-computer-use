# bridge_server2.ps1 - cadmcp v2 bridge (ASCII only: PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#
# What is different from v1 (bridge_server.ps1):
#   1. framed protocol:  "CADMCP2 <bytes>\n" + UTF-8 JSON  (no 32KB single-Read truncation)
#   2. every AutoCAD/COM call runs in a worker runspace, so this listener always answers
#      PING / HEALTH / INFO(cached) even while a long or stuck command is in flight
#   3. explicit timeouts + BUSY / STUCK / TIMEOUT / ACAD_GONE error codes instead of a
#      silent hang, plus KILLACAD / STARTACAD / REATTACH recovery ops
#   4. retry on RPC_E_CALL_REJECTED / SERVERCALL_RETRYLATER, re-attach after a crash,
#      no invented "doc= ents=0" answer for a dead session
#   5. UTF-8 log (v1 wrote the log in the console ANSI codepage and every Chinese
#      document name / error message came out as mojibake)
param(
  [int]$Port = 8773,
  # Empty = <this file's folder>\cad_fig; the runtime dir travels with the bridge.
  [string]$LogPath = '',
  [string]$SnapDir = '',
  # Empty = resolve next to this file, so a bundled copy stays self-contained.
  [string]$WorkerPath = '',
  [int]$DefaultTimeoutMs = 25000,
  [int]$LongTimeoutMs = 180000,
  [int]$KeepSnaps = 3,
  [string]$AcadExe = 'C:\Program Files\Autodesk\AutoCAD 2021\acad.exe'
)

$ErrorActionPreference = 'Continue'
# Runtime scratch dir (logs, snapshots, _eval.txt). Derived from this file's own
# folder so the bridge and its output travel together; -SnapDir or the
# CADMCP2_SNAP_DIR environment variable override it.
if ([string]::IsNullOrWhiteSpace($SnapDir)) {
  $SnapDir = if ([string]::IsNullOrWhiteSpace($env:CADMCP2_SNAP_DIR)) { Join-Path $PSScriptRoot 'cad_fig' } else { $env:CADMCP2_SNAP_DIR }
}
if (-not (Test-Path -LiteralPath $SnapDir)) { New-Item -ItemType Directory -Force -Path $SnapDir | Out-Null }
# The worker runs through AddScript in a runspace, where $PSScriptRoot does not
# exist, so it learns the runtime dir from this process environment variable.
$env:CADMCP2_SNAP_DIR = $SnapDir
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $SnapDir 'bridge2.txt' }
# Sibling resolution by default: a hardcoded absolute path would make the bundled
# copy of this bridge spawn the worker from whatever folder it was authored in.
if ([string]::IsNullOrWhiteSpace($WorkerPath)) { $WorkerPath = Join-Path $PSScriptRoot 'bridge_worker2.ps1' }
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Ascii = [System.Text.Encoding]::ASCII
$Started = Get-Date
$State = @{ tainted = $false; taintedReason = ''; calls = 0; errors = 0; lastErr = ''; lastInfo = $null; lastOp = '' }

function Write-Log([string]$msg) {
  $line = '[' + (Get-Date).ToString('HH:mm:ss.fff') + '] ' + $msg
  try { [IO.File]::AppendAllText($LogPath, $line + [string][char]13 + [string][char]10, $Utf8) } catch { }
}
function Read-Frame($stream, [int]$timeoutMs) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  $sb = New-Object System.Text.StringBuilder
  $one = New-Object byte[] 1
  $got = $false
  while (-not $got) {
    if ($stream.DataAvailable) {
      $n = $stream.Read($one, 0, 1)
      if ($n -le 0) { throw 'peer closed' }
      $c = [char]$one[0]
      if ($c -eq [char]10) { $got = $true } elseif ($c -ne [char]13) { [void]$sb.Append($c) }
      if ($sb.Length -gt 96) { throw 'frame header too long' }
    } else {
      if ([DateTime]::UtcNow -gt $deadline) { throw 'frame header timeout' }
      Start-Sleep -Milliseconds 5
    }
  }
  $head = $sb.ToString().Trim()
  if (-not $head.StartsWith('CADMCP2 ')) { throw ('bad frame magic: ' + $head) }
  $len = 0
  if (-not [int]::TryParse($head.Substring(8), [ref]$len)) { throw ('bad frame length: ' + $head) }
  if ($len -lt 0 -or $len -gt 16777216) { throw 'frame length out of range' }
  $buf = New-Object byte[] $len
  $read = 0
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while ($read -lt $len) {
    if ($stream.DataAvailable) {
      $n = $stream.Read($buf, $read, $len - $read)
      if ($n -le 0) { throw 'peer closed mid-frame' }
      $read += $n
    } else {
      if ([DateTime]::UtcNow -gt $deadline) { throw 'frame body timeout' }
      Start-Sleep -Milliseconds 5
    }
  }
  return $Utf8.GetString($buf)
}
function Write-Frame($stream, [string]$json) {
  $body = $Utf8.GetBytes($json)
  $head = $Ascii.GetBytes('CADMCP2 ' + $body.Length + [string][char]10)
  $stream.Write($head, 0, $head.Length)
  $stream.Write($body, 0, $body.Length)
  $stream.Flush()
}
function New-Ok($id, $data) {
  $h = @{ id = $id; ok = $true }
  if ($null -ne $data) { $h['data'] = $data }
  return (ConvertTo-Json -InputObject $h -Compress -Depth 8)
}
function New-Err($id, [string]$code, [string]$message, $extra) {
  $h = @{ id = $id; ok = $false; code = $code; message = $message }
  if ($null -ne $extra) { $h['data'] = $extra }
  return (ConvertTo-Json -InputObject $h -Compress -Depth 8)
}
function New-WorkerRunspace {
  $rs = [runspacefactory]::CreateRunspace()
  try { $rs.ApartmentState = 'STA' } catch { }
  try { $rs.ThreadOptions = 'ReuseThread' } catch { }
  $rs.Open()
  return $rs
}
function Submit-Job([string]$op, $argsObj, $id, $client, $stream, [int]$timeoutMs, $extra) {
  if ($null -eq $script:Rs) { $script:Rs = New-WorkerRunspace }
  $ps = [powershell]::Create()
  $ps.Runspace = $script:Rs
  [void]$ps.AddScript($script:WorkerText)
  [void]$ps.AddArgument([string]$op)
  [void]$ps.AddArgument((ConvertTo-Json -InputObject $argsObj -Compress -Depth 6))
  $async = $ps.BeginInvoke()
  $script:Pending = @{ ps = $ps; async = $async; id = $id; client = $client; stream = $stream; op = [string]$op;
                       deadline = (Get-Date).AddMilliseconds($timeoutMs); started = (Get-Date); extra = $extra }
}
function Complete-Job($job) {
  $out = $null
  $errText = ''
  try { $out = $job.ps.EndInvoke($job.async) } catch { $errText = [string]$_.Exception.Message }
  $streamErr = ''
  foreach ($e in @($job.ps.Streams.Error)) { if ($null -ne $e) { $streamErr += ($e.ToString() + ' | ') } }
  if ($errText.Length -gt 0) { return @{ json = (New-Err $job.id 'WORKER_FAILED' ($errText + ' ' + $streamErr)); ok = $false; code = 'WORKER_FAILED'; data = $null } }
  $json = $null
  foreach ($o in @($out)) { if ($o -is [string]) { $json = $o } }
  if ($null -eq $json) { return @{ json = (New-Err $job.id 'EMPTY_WORKER_OUTPUT' $streamErr); ok = $false; code = 'EMPTY_WORKER_OUTPUT'; data = $null } }
  $w = $null
  try { $w = $json | ConvertFrom-Json } catch { }
  if ($null -eq $w) { return @{ json = (New-Err $job.id 'BAD_WORKER_JSON' ([string]$json)); ok = $false; code = 'BAD_WORKER_JSON'; data = $null } }
  $data = @{}
  if ($w.PSObject.Properties['data'] -and $null -ne $w.data) {
    foreach ($p in $w.data.PSObject.Properties) { $data[$p.Name] = $p.Value }
  }
  if ($null -ne $job.extra) { foreach ($k in $job.extra.Keys) { $data[$k] = $job.extra[$k] } }
  $code = ''
  if ($null -ne $w.code) { $code = [string]$w.code }
  $okFlag = [bool]$w.ok
  $h = @{ id = $job.id; ok = $okFlag }
  if ($data.Count -gt 0) { $h['data'] = $data }
  if (-not $okFlag) {
    $h['code'] = $code
    $h['message'] = if ($null -ne $w.message) { [string]$w.message } else { '' }
  }
  return @{ json = (ConvertTo-Json -InputObject $h -Compress -Depth 8); ok = $okFlag; code = $code; data = $data }
}
function Update-State([string]$op, $result) {
  $State.lastOp = $op
  if (-not $result.ok) {
    $State.errors = $State.errors + 1
    $State.lastErr = ($op + ': ' + $result.code)
    if ($result.code -eq 'ACAD_GONE') { $State.tainted = $false; $State.taintedReason = '' }
    return
  }
  if ($null -eq $result.data) { return }
  if ($result.data.ContainsKey('cmdactive')) {
    $State.lastInfo = $result.data
    if ([int]$result.data['cmdactive'] -eq 0 -and $State.tainted) {
      $State.tainted = $false
      $State.taintedReason = ''
      Write-Log 'taint cleared (CMDACTIVE=0)'
    }
  }
  if ($op -eq 'EXEC' -and $result.data.ContainsKey('status') -and ([string]$result.data['status']) -eq 'timeout') {
    $State.tainted = $true
    $State.taintedReason = 'EXEC wait expired; the command may still be running'
  }
}
function Abort-Pending([string]$code, [string]$message) {
  if ($null -eq $script:Pending) { return }
  try { Write-Frame $script:Pending.stream (New-Err $script:Pending.id $code $message) } catch { }
  try { $script:Pending.stream.Close(); $script:Pending.client.Close() } catch { }
  Write-Log ('abort pending ' + $script:Pending.op + ' -> ' + $code)
  $script:Pending = $null
  $script:Rs = $null
}
function Health-Data {
  $busy = $null -ne $script:Pending
  $h = @{
    bridge = 'cadmcp2'; port = $Port; pid = $PID; uptimeSec = [int]((Get-Date) - $Started).TotalSeconds
    busy = $busy; pendingOp = ''; tainted = $State.tainted; taintedReason = $State.taintedReason
    calls = $State.calls; errors = $State.errors; lastErr = $State.lastErr; lastOp = $State.lastOp
    logPath = $LogPath; workerPath = $WorkerPath; snapDir = $SnapDir
  }
  if ($busy) { $h['pendingOp'] = [string]$script:Pending.op }
  if ($null -ne $State.lastInfo) { $h['lastInfo'] = $State.lastInfo }
  $acad = @(Get-Process acad -ErrorAction SilentlyContinue)
  if ($acad.Count -gt 0) { $h['acadPid'] = [int]$acad[0].Id; $h['acadResponding'] = [bool]$acad[0].Responding } else { $h['acadPid'] = 0 }
  return $h
}

$script:WorkerText = [IO.File]::ReadAllText($WorkerPath)
$script:Rs = $null
$script:Pending = $null

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Log ('==== start pid=' + $PID + ' port=' + $Port + ' worker=' + $WorkerPath)

while ($true) {
  # 1) a worker job finished
  if ($null -ne $script:Pending -and $script:Pending.async.IsCompleted) {
    $job = $script:Pending
    $script:Pending = $null
    $r = Complete-Job $job
    Update-State $job.op $r
    try { Write-Frame $job.stream $r.json } catch { }
    $ms = [int]((Get-Date) - $job.started).TotalMilliseconds
    Write-Log ($job.op + ' -> ' + $r.json.Substring(0, [Math]::Min(200, $r.json.Length)) + '  (' + $ms + 'ms)')
    try { $job.stream.Close(); $job.client.Close() } catch { }
    try { $job.ps.Dispose() } catch { }
    continue
  }
  # 2) a worker job exceeded its deadline: report, mark tainted, abandon the runspace
  if ($null -ne $script:Pending -and ((Get-Date) -gt $script:Pending.deadline)) {
    $job = $script:Pending
    $script:Pending = $null
    $ms = [int]((Get-Date) - $job.started).TotalMilliseconds
    $msg = $job.op + ' did not finish within ' + $ms + 'ms; the command may be stuck on a prompt or a modal dialog. Bridge is still alive: use cad_health, then cad_restart_acad (or desktop_preview) to recover.'
    $State.tainted = $true
    $State.taintedReason = 'timeout on ' + $job.op
    $State.errors = $State.errors + 1
    $State.lastErr = $job.op + ': TIMEOUT'
    try { Write-Frame $job.stream (New-Err $job.id 'TIMEOUT' $msg) } catch { }
    Write-Log ($job.op + ' -> TIMEOUT after ' + $ms + 'ms (tainted)')
    try { $job.stream.Close(); $job.client.Close() } catch { }
    $script:Rs = $null
    continue
  }
  # 3) serve one connection
  if ($listener.Pending()) {
    $client = $listener.AcceptTcpClient()
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $id = $null
    $keepOpen = $false
    try {
      $raw = Read-Frame $stream 5000
      $req = $raw | ConvertFrom-Json
      $id = $req.id
      $op = ([string]$req.op).ToUpper()
      $State.calls = $State.calls + 1
      $argObj = @{}
      if ($null -ne $req.args) { $argObj = $req.args }
      $timeoutMs = $DefaultTimeoutMs
      if ($req.PSObject.Properties['timeoutMs'] -and $null -ne $req.timeoutMs) {
        $timeoutMs = [int]$req.timeoutMs
        if ($timeoutMs -lt 1000) { $timeoutMs = 1000 }
        if ($timeoutMs -gt $LongTimeoutMs) { $timeoutMs = $LongTimeoutMs }
      }
      switch ($op) {
        'PING' {
          Write-Frame $stream (New-Ok $id (@{ pong = $true; bridge = 'cadmcp2'; pid = $PID; busy = ($null -ne $script:Pending) }))
        }
        'HEALTH' {
          Write-Frame $stream (New-Ok $id (Health-Data))
        }
        'ECHO' {
          # pure framing round-trip: no AutoCAD involvement
          $t = ''
          if ($null -ne $argObj.text) { $t = [string]$argObj.text }
          $sha = [System.Security.Cryptography.SHA1]::Create().ComputeHash($Utf8.GetBytes($t))
          $hex = -join ($sha | ForEach-Object { $_.ToString('x2') })
          Write-Frame $stream (New-Ok $id (@{ bytes = $t.Length; sha1 = $hex; text = $t }))
        }
        'QUIT' {
          Write-Frame $stream (New-Ok $id (@{ bye = $true }))
          $listener.Stop()
          Write-Log 'stopped (QUIT)'
          return
        }
        'INFO' {
          if ($null -ne $script:Pending) {
            $data = @{ stale = $true; busy = $true; pendingOp = [string]$script:Pending.op; tainted = $State.tainted; taintedReason = $State.taintedReason }
            if ($null -ne $State.lastInfo) { foreach ($k in $State.lastInfo.Keys) { $data[$k] = $State.lastInfo[$k] } }
            Write-Frame $stream (New-Ok $id $data)
          } else {
            Submit-Job 'INFO' $argObj $id $client $stream $DefaultTimeoutMs $null
            $keepOpen = $true
            Write-Log ('INFO submitted id=' + $id)
          }
        }
        'REATTACH' {
          if ($null -ne $script:Pending) { Write-Frame $stream (New-Err $id 'BUSY' ('bridge busy with ' + $script:Pending.op)) }
          else { Submit-Job 'REATTACH' $argObj $id $client $stream $DefaultTimeoutMs $null; $keepOpen = $true }
        }
        'EXEC' {
          if ($null -ne $script:Pending) {
            Write-Frame $stream (New-Err $id 'BUSY' ('another command is in flight: ' + $script:Pending.op + ' (opened ' + [int]((Get-Date) - $script:Pending.started).TotalSeconds + 's ago)'))
          } else {
            Submit-Job 'EXEC' $argObj $id $client $stream $timeoutMs (@{ tainted = $State.tainted })
            $keepOpen = $true
          }
        }
        'EVAL' {
          if ($null -ne $script:Pending) {
            Write-Frame $stream (New-Err $id 'BUSY' ('another command is in flight: ' + $script:Pending.op))
          } else {
            Submit-Job 'EVAL' $argObj $id $client $stream $timeoutMs (@{ tainted = $State.tainted })
            $keepOpen = $true
          }
        }
        'SNAP' {
          if ($null -ne $script:Pending) {
            Write-Frame $stream (New-Err $id 'BUSY' ('another command is in flight: ' + $script:Pending.op))
          } else {
            $a = @{}
            foreach ($k in @('base')) { if ($null -ne $argObj.$k) { $a[$k] = $argObj.$k } }
            $a['keep'] = $KeepSnaps
            Submit-Job 'SNAP' $a $id $client $stream ([Math]::Max($timeoutMs, 60000)) $null
            $keepOpen = $true
          }
        }
        'DUMP' {
          if ($null -ne $script:Pending) { Write-Frame $stream (New-Err $id 'BUSY' ('another command is in flight: ' + $script:Pending.op)) }
          else { Submit-Job 'DUMP' $argObj $id $client $stream ([Math]::Max($timeoutMs, 60000)) $null; $keepOpen = $true }
        }
        'KILLACAD' {
          Abort-Pending 'ABORTED_BY_KILL' 'acad is being killed'
          $procs = @(Get-Process acad -ErrorAction SilentlyContinue)
          $n = $procs.Count
          if ($n -gt 0) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 1200 }
          $State.tainted = $false
          $State.taintedReason = ''
          $State.lastInfo = $null
          Write-Frame $stream (New-Ok $id (@{ killed = $n }))
          Write-Log ('KILLACAD -> ' + $n)
        }
        'STARTACAD' {
          Abort-Pending 'ABORTED_BY_START' 'acad is being (re)started'
          if ($null -eq $argObj.exe) { $argObj | Add-Member -NotePropertyName exe -NotePropertyValue $AcadExe -Force -ErrorAction SilentlyContinue }
          Submit-Job 'STARTACAD' $argObj $id $client $stream $LongTimeoutMs $null
          $keepOpen = $true
          Write-Log 'STARTACAD submitted'
        }
        'RESTARTACAD' {
          Abort-Pending 'ABORTED_BY_RESTART' 'acad is being restarted'
          $force = $true
          if ($null -ne $argObj.force) { $force = [bool]$argObj.force }
          $n = 0
          if ($force) {
            $procs = @(Get-Process acad -ErrorAction SilentlyContinue)
            $n = $procs.Count
            if ($n -gt 0) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 1500 }
          }
          $State.tainted = $false
          $State.taintedReason = ''
          $State.lastInfo = $null
          if ($null -eq $argObj.exe) { $argObj | Add-Member -NotePropertyName exe -NotePropertyValue $AcadExe -Force -ErrorAction SilentlyContinue }
          Submit-Job 'STARTACAD' $argObj $id $client $stream $LongTimeoutMs (@{ killed = $n; restarted = $true })
          $keepOpen = $true
          Write-Log ('RESTARTACAD submitted (killed=' + $n + ')')
        }
        default {
          Write-Frame $stream (New-Err $id 'UNKNOWN_OP' ('unknown op: ' + $op))
          Write-Log ('UNKNOWN_OP ' + $op)
        }
      }
    } catch {
      try { Write-Frame $stream (New-Err $id 'BAD_REQUEST' ([string]$_.Exception.Message)) } catch { }
      Write-Log ('BAD_REQUEST: ' + [string]$_.Exception.Message)
    } finally {
      if (-not $keepOpen) {
        try { $stream.Close(); $client.Close() } catch { }
      }
    }
  } else {
    Start-Sleep -Milliseconds 20
  }
}
