import assert from 'node:assert/strict'
import { tidyKeeping } from './review-trace.js'
import { tidyMarkdown as oldTidy } from './tidy-old.test-only.mjs'

const cases = [
  '> Line 1\\\n> Line 2', '> Line 1  \n> Line 2', '> Line 1\n>\n> Line 2', '> a\n>  \n>\n> b',
  '- a\n\n- b\n\n- c\n\nAfter', '1. one\n\n2. two\n\n\nText', '- a\n    \n  - b',
  '```\n- a\n\n- b\n```', 'Plain\n\nText  \nwith break\\\nand more', '> quote\\\n>\n> more  \n> end',
  '', '\n\n', '- \n\n- x', '>\n>\n>', '> x\n>   \n\n> y',
]
// And random documents of those pieces.
const pieces = ['> q', '>', '> q\\', '> q  ', '- i', '  - j', '1. n', '', '   ', 'p', 'p  ', 'p\\', '```', '~~~']
let seed = 7
const random = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648
for (let n = 0; n < 4000; n++) {
  const lines = Array.from({ length: 1 + Math.floor(random() * 12) }, () => pieces[Math.floor(random() * pieces.length)])
  cases.push(lines.join('\n'))
}
for (const input of cases) {
  const { text, kept } = tidyKeeping(input)
  assert.equal(text, oldTidy(input), JSON.stringify(input))
  assert.equal(kept.length, text.length)
  for (let t = 0; t < text.length; t++) {
    assert.equal(input[kept[t]], text[t], `kept ${t} in ${JSON.stringify(input)}`)
    if (t > 0) assert.ok(kept[t] > kept[t - 1], `kept in order in ${JSON.stringify(input)}`)
  }
}
// Codex's case: the indentation that stays is the indentation of its own line.
{
  const input = '```\n- a\n    \n  - b\n```'
  const { text, kept } = tidyKeeping(input)
  const at = text.indexOf('  - b')
  assert.equal(kept[at], input.indexOf('  - b'))
}
console.log('tidy-keeping: ok,', cases.length, 'inputs')
