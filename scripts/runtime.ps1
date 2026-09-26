<#
  Shared runtime helpers for both drivers (dot-source this file).

  Two avoidable costs dominate a driver call:
    * Windows PowerShell 5.1 needs ~570ms just to start, PowerShell 7 ~185ms.
    * Add-Type compiles the interop class from source on every call (~280ms).
  Resolve-DshInterpreter prefers the fast interpreter (children are launched with
  it too), Import-DshNativeType compiles the interop class once into a cached
  assembly that later calls load instead of rebuilding, and the System.Drawing
  load is deferred to Initialize-DshDrawing so only drawing actions pay for it.
#>

function Resolve-DshInterpreter {
  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($null -ne $pwsh) { return $pwsh.Source }
  return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Import-DshNativeType {
  <#
    Compile the Win32 interop class once and cache the assembly by source hash.

    The C# must stay Win32-only: under PowerShell 7 the -ReferencedAssemblies
    parameter REPLACES the compiler's default reference set, so referencing
    System.Drawing here would drop System.Private.CoreLib and the compile would
    fail. All drawing therefore happens in PowerShell, never in the C# class.
  #>
  param([Parameter(Mandatory = $true)][string]$Source)
  $cacheDir = Join-Path $env:TEMP 'dsh-computer-use'
  if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source)))).Replace('-', '').Substring(0, 16)
  $sha.Dispose()
  $dll = Join-Path $cacheDir ('native-' + $hash + '.dll')
  if (Test-Path $dll) {
    try { Add-Type -Path $dll; return } catch { Remove-Item $dll -Force -ErrorAction SilentlyContinue }
  }
  Add-Type -TypeDefinition $Source -OutputAssembly $dll -ErrorAction Stop
  Add-Type -Path $dll
}

function Initialize-DshDrawing {
  if ($script:DshDrawingReady) { return }
  Add-Type -AssemblyName System.Drawing
  $script:DshDrawingReady = $true
}

function Read-DshPayload {
  param([Parameter(Mandatory = $true)][string]$PayloadBase64)
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($PayloadBase64))
  if ([string]::IsNullOrWhiteSpace($json)) { return @{} }
  return ($json | ConvertFrom-Json)
}

function Emit {
  <#
    Print exactly one compact JSON object on stdout. Depth is generous because
    window lists nest; -Compress keeps it on one line so the Node side can parse
    stdout directly.
  #>
  param([Parameter(Mandatory = $true)]$Value)
  Write-Output ($Value | ConvertTo-Json -Depth 12 -Compress)
}

function Get-DshKeyCode {
  <#
    Virtual-key code for one key name, read from lib/keymap.json - the same file
    the JS tools validate against, so both sides resolve keys identically.
  #>
  param([Parameter(Mandatory = $true)][string]$Key)
  if ($null -eq $script:DshNamedKeys) {
    $script:DshNamedKeys = (Get-Content (Join-Path $PSScriptRoot '../lib/keymap.json') -Raw | ConvertFrom-Json).named
  }
  $k = $Key.ToUpperInvariant()
  if ($k.Length -eq 1 -and $k -match '^[A-Z0-9]$') { return [int][char]$k }
  $prop = $script:DshNamedKeys.PSObject.Properties[$k]
  if ($null -ne $prop) { return [int]$prop.Value }
  throw "Unsupported key: $Key"
}

function Property-Or {
  param($Object, [string]$Name, $Default)
  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
  return $prop.Value
}
