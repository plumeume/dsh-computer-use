import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const libDirectory = dirname(fileURLToPath(import.meta.url))

/**
 * Absolute driver paths.
 *
 * Drivers live outside lib/ so a driver call can be audited on its own and the
 * algorithm can be inspected without running anything.
 */
export const DRIVER_PATHS = {
  host: join(libDirectory, '..', 'scripts', 'host-driver.ps1'),
  isolated: join(libDirectory, '..', 'scripts', 'isolated-desktop.ps1'),
}

let cachedInterpreter = null

/**
 * Interpreter used to run the PowerShell drivers.
 *
 * A driver call is a fresh process, so interpreter startup dominates. PowerShell
 * 7 (pwsh) starts in roughly a third of the time Windows PowerShell 5.1 needs,
 * so it is preferred and 5.1 is the fallback every supported Windows has.
 */
export function powershellExecutable() {
  if (cachedInterpreter !== null) return cachedInterpreter
  const extensions = (process.env.PATHEXT || '.EXE;.CMD;.BAT').split(';').filter(Boolean)
  const directories = (process.env.PATH || '').split(';').filter(Boolean)
  for (const directory of directories) {
    for (const extension of extensions) {
      const candidate = join(directory, 'pwsh' + extension.toLowerCase())
      if (existsSync(candidate)) {
        cachedInterpreter = candidate
        return cachedInterpreter
      }
    }
  }
  const candidates = []
  if (process.env.LOCALAPPDATA) candidates.push(join(process.env.LOCALAPPDATA, 'Microsoft', 'WindowsApps', 'pwsh.exe'))
  if (process.env.ProgramFiles) candidates.push(join(process.env.ProgramFiles, 'PowerShell', '7', 'pwsh.exe'))
  for (const candidate of candidates) {
    if (existsSync(candidate)) {
      cachedInterpreter = candidate
      return cachedInterpreter
    }
  }
  cachedInterpreter = 'powershell.exe'
  return cachedInterpreter
}

/** Encode a driver request as base64 so quoting can never mangle it. */
export function encodePayload(value) {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64')
}

/**
 * Run one driver invocation and parse the single JSON object it prints.
 *
 * A driver that fails writes nothing parseable; the thrown message keeps the
 * driver's own stderr so a Win32 error is visible instead of a bare JSON error.
 */
export async function runPowerShell(scriptPath, args, timeoutMs) {
  if (process.platform !== 'win32') throw new Error('dsh-computer-use supports Windows only')
  let stdout = ''
  let stderr = ''
  try {
    const result = await execFileAsync(powershellExecutable(), [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args,
    ], { windowsHide: true, maxBuffer: 64 * 1024 * 1024, timeout: timeoutMs, killSignal: 'SIGKILL' })
    stdout = String(result.stdout || '')
    stderr = String(result.stderr || '')
  } catch (error) {
    const partial = String((error && error.stdout) || '').trim()
    const detail = String((error && error.stderr) || '').trim() || String((error && error.message) || error)
    if (partial !== '') {
      try { return JSON.parse(partial) } catch { /* fall through to the error below */ }
    }
    throw new Error('computer-use driver failed: ' + detail.slice(0, 900))
  }
  const text = stdout.trim()
  if (text === '') {
    throw new Error('computer-use driver returned no output' + (stderr.trim() ? ': ' + stderr.trim().slice(0, 500) : ''))
  }
  try {
    return JSON.parse(text)
  } catch {
    throw new Error('computer-use driver returned invalid JSON: ' + text.slice(0, 300)
      + (stderr.trim() ? ' / stderr: ' + stderr.trim().slice(0, 300) : ''))
  }
}

/** Real-desktop driver call. */
export async function invokeHost(action, payload, timeoutMs) {
  const body = Object.assign({ action: action }, payload || {})
  return runPowerShell(DRIVER_PATHS.host, ['-PayloadBase64', encodePayload(body)], timeoutMs || 60000)
}

/**
 * Isolated-desktop driver call.
 *
 * The outer budget exceeds the driver's own because the invoke role additionally
 * creates the desktop and waits for a worker process to finish.
 */
export async function invokeIsolated(action, payload, timeoutMs, desktopName) {
  const budget = timeoutMs || 60000
  return runPowerShell(DRIVER_PATHS.isolated, [
    '-Role', 'invoke',
    '-DesktopName', desktopName || 'DSHIsolated',
    '-Action', action,
    '-PayloadBase64', encodePayload(payload || {}),
    '-TimeoutMs', String(budget),
  ], budget + 20000)
}
