import { readFileSync } from 'node:fs'

// One keymap for the whole package: the JS tools validate against it and the
// PowerShell drivers resolve virtual-key codes from the same file, so adding a
// key means editing exactly one place.
const keymap = JSON.parse(readFileSync(new URL('./keymap.json', import.meta.url), 'utf8'))

/** Named keys (everything that is not a single A-Z/0-9 character). */
export const namedKeys = new Set(Object.keys(keymap.named))

/** Shortcuts that must never be injected, as uppercase name lists. */
export const blockedCombos = keymap.blockedCombos.map(combo => combo.map(name => name.toUpperCase()))

const singleChar = /^[A-Z0-9]$/

/** Normalize one key name to its canonical uppercase form, or throw. */
export function normalizeKey(key) {
  const normalized = String(key).toUpperCase()
  if (normalized.length === 1 && singleChar.test(normalized)) return normalized
  if (!namedKeys.has(normalized)) throw new Error('Unsupported key: ' + key)
  return normalized
}

/** Virtual-key code for a name already accepted by normalizeKey. */
export function virtualKey(normalized) {
  if (normalized.length === 1 && singleChar.test(normalized)) return normalized.charCodeAt(0)
  const code = keymap.named[normalized]
  if (code === undefined) throw new Error('Unsupported key: ' + normalized)
  return code
}

/** Normalize a 1..4 key combination and reject blocked shortcuts. */
export function normalizeKeys(keys) {
  if (!Array.isArray(keys) || keys.length < 1 || keys.length > 4) {
    throw new Error('keys must contain 1 to 4 entries')
  }
  const normalized = keys.map(normalizeKey)
  for (const combo of blockedCombos) {
    if (combo.every(name => normalized.includes(name))) {
      throw new Error(combo.join('+') + ' cannot be sent')
    }
  }
  return normalized
}
