// The fence a code block is written between: one backtick longer than the
// longest run of backticks in its text, and never fewer than three. A fence
// closes only on a run at least as long as the one that opened it, so a
// block that holds ``` is read back whole, not cut off at that line.
//
// Pure: text in, fence out.
export function codeFence(text) {
  let longest = 0
  for (const run of text.match(/`+/g) ?? []) longest = Math.max(longest, run.length)
  return '`'.repeat(Math.max(3, longest + 1))
}
