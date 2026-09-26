/**
 * Window-list formatting shared by computer_windows and desktop_windows so both
 * desktops describe their windows the same way.
 */
export function describeWindows(windows, emptyLabel = '(no windows)') {
  if (!Array.isArray(windows) || windows.length === 0) return emptyLabel
  return windows.map(entry => {
    const title = entry.title ? JSON.stringify(entry.title) : '(untitled)'
    const hidden = entry.visible ? '' : ' [hidden]'
    return '- hwnd=' + entry.hwnd + ' pid=' + entry.pid + ' class=' + entry.className + hidden
      + ' rect=' + entry.x + ',' + entry.y + ' ' + entry.width + 'x' + entry.height
      + ' title=' + title
  }).join('\n')
}
