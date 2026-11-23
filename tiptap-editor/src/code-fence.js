// Code fences: the fence a code block is written between, and which lines
// of Markdown are fenced code.
//
// Pure: text in, fences out.

// The fence a code block is written between: one backtick longer than the
// longest run of backticks in its text, and never fewer than three. A fence
// closes only on a run at least as long as the one that opened it, so a
// block that holds ``` is read back whole, not cut off at that line.
export function codeFence(text) {
  let longest = 0
  for (const run of text.match(/`+/g) ?? []) longest = Math.max(longest, run.length)
  return '`'.repeat(Math.max(3, longest + 1))
}

// For each line, whether it is a fence or code inside one. A fence opens on
// a run of three or more backticks or tildes (a backtick fence whose info
// string holds a backtick opens nothing), and closes on a run of its own
// character at least as long, with nothing after it but spaces: a shorter
// run inside it is code. An unclosed fence runs to the end.
//
// `nested` takes a fence inside a list item or a quote too: at any
// indentation, where the page writes a list item's four spaces in, and after
// any `>`. Without it, at three spaces in at most, as CommonMark has it at
// the top level.
export function fencedLines(lines, { nested = false } = {}) {
  const pattern = nested ? /^(?:[ \t]*>)*[ \t]*(`{3,}|~{3,})([^\n]*)$/ : /^ {0,3}(`{3,}|~{3,})([^\n]*)$/
  const fenced = new Array(lines.length).fill(false)
  let fence = null
  for (let i = 0; i < lines.length; i++) {
    // Its info string to the line's end, a \r of \r\n included.
    const marker = lines[i].match(pattern)
    if (fence === null) {
      if (marker && !(marker[1][0] === '`' && marker[2].includes('`'))) {
        fence = marker[1]
        fenced[i] = true
      }
      continue
    }
    fenced[i] = true
    if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && marker[2].trim() === '') fence = null
  }
  return fenced
}
