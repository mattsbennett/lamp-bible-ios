import assert from 'node:assert/strict'
import { tidyKeeping } from './review-trace.js'
import { tidyMarkdown as oldTidy } from './tidy-old.test-only.mjs'
import { fencedLines } from './code-fence.js'

const cases = [
  '> Line 1\\\n> Line 2', '> Line 1  \n> Line 2', '> Line 1\n>\n> Line 2', '> a\n>  \n>\n> b',
  '- a\n\n- b\n\n- c\n\nAfter', '1. one\n\n2. two\n\n\nText', '- a\n    \n  - b',
  '```\n- a\n\n- b\n```', 'Plain\n\nText  \nwith break\\\nand more', '> quote\\\n>\n> more  \n> end',
  '', '\n\n', '- \n\n- x', '>\n>\n>', '> x\n>   \n\n> y',
]
// And random documents of those pieces.
const pieces = ['> q', '>', '> q\\', '> q  ', '- i', '  - j', '1. n', '', '   ', 'p', 'p  ', 'p\\', '```', '~~~', '> ```']
let seed = 7
const random = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648
for (let n = 0; n < 4000; n++) {
  const lines = Array.from({ length: 1 + Math.floor(random() * 12) }, () => pieces[Math.floor(random() * pieces.length)])
  cases.push(lines.join('\n'))
}
let withCode = 0
for (const input of cases) {
  const { text, kept } = tidyKeeping(input)
  // Where nothing is fenced, what the old tidying wrote, byte for byte; in
  // fenced code, every character kept, its line ending too.
  const lines = input.split('\n')
  const fenced = fencedLines(lines, { nested: true })
  if (!fenced.includes(true)) {
    assert.equal(text, oldTidy(input), JSON.stringify(input))
  } else {
    withCode++
    const keptAt = new Set(kept)
    let at = 0
    lines.forEach((line, i) => {
      if (fenced[i]) {
        for (let k = at; k < at + line.length; k++) assert.ok(keptAt.has(k), `code kept at ${k} in ${JSON.stringify(input)}`)
        if (i > 0) assert.ok(keptAt.has(at - 1), `code's line kept at ${at} in ${JSON.stringify(input)}`)
      }
      at += line.length + 1
    })
  }
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
// Code that looks like a quote or a list is the writer's, inside a fence of
// any length, in a list item or a quote (Codex's cases, which lost a
// backslash, a blank line, or a quote's empty line and trailing spaces).
for (const input of ['```\n> x\\\n```', '````\n> x\\\n```\n````', '````\n- a\n\n- b\n```\n````', '- item\n\n    ```\n    - a\n\n    - b\n    ```',
  '> ```\n> x\\\n> ```', '> ```\n> a  \n>\n> b\n> ```']) {
  assert.equal(tidyKeeping(input).text, input, JSON.stringify(input))
}
assert.ok(withCode > 1000, `inputs with code: ${withCode}`)
console.log('tidy-keeping: ok,', cases.length, 'inputs,', withCode, 'with code')
