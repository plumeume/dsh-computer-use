/**
 * Coordinate conversion shared by the computer_* and desktop_* tools.
 *
 * The model works in 0-1000 normalized pointers (resolution independent) while
 * both drivers inject literal desktop pixels.
 */
export function toPixelPoint(x, y, size, normalized) {
  if (!Number.isInteger(x) || !Number.isInteger(y)) throw new Error('x and y must be integers')
  if (!normalized) return { x, y }
  if (x < 0 || x > 1000 || y < 0 || y > 1000) {
    throw new Error('normalized coordinates must be within 0-1000')
  }
  const width = Number(size && size.width) || 0
  const height = Number(size && size.height) || 0
  if (width <= 0 || height <= 0) throw new Error('the desktop size is unknown; take a screenshot first')
  return {
    x: Math.min(width - 1, Math.max(0, Math.round((x / 1000) * (width - 1)))),
    y: Math.min(height - 1, Math.max(0, Math.round((y / 1000) * (height - 1)))),
  }
}

/** Human-readable reminder of the active pointer space. */
export function describeCoordinateSpace(normalized, size) {
  if (!normalized) return 'Pointer coordinates are literal desktop pixels.'
  return 'Pointer coordinates are 0-1000 normalized over the ' + size.width + 'x' + size.height + ' desktop.'
}
