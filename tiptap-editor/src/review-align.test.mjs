import assert from 'node:assert/strict'
import { marksInMarkdown, tokens, characterMap, noteDefinitions } from './review-align.js'

const S = '', E = '', P = '', END = ''
const place = n => String(n).split('').map(d => String.fromCharCode(0xE010 + Number(d))).join('') + END

// Marks read out of the host's Markdown, with their places.
{
  const read = marksInMarkdown(`One ${S}${place(0)}two${E} three${P}${place(12)}.`)
  assert.equal(read.text, 'One two three.')
  assert.deepEqual(read.marks, [{ from: 4, to: 7, place: 0 }, { from: 13, to: 13, place: 12 }])
  assert.equal(marksInMarkdown(`One ${S}two`), null, 'an unclosed mark')
  assert.equal(marksInMarkdown(`One ${E}two`), null, 'an end with no start')
}

// Words and each other character are tokens; space is not.
assert.deepEqual(tokens('**Bold**, and élan 12.').map(t => t.text), ['*', '*', 'Bold', '*', '*', ',', 'and', 'élan', '12', '.'])

// The same words line up through syntax on either side, character by character.
{
  const map = characterMap('See **the** [dog](https://x.example) now.', 'See the dog now.')
  const source = 'See **the** [dog](https://x.example) now.'
  assert.equal(map[source.indexOf('the')], 4)
  assert.equal(map[source.indexOf('dog')], 8)
  assert.equal(map[source.indexOf('x.example')], -1, 'an address the shown text lacks')
  assert.equal(map[source.indexOf('now')], 12)
}

// A long text with words repeated throughout still lines up exactly.
{
  const words = Array.from({ length: 3000 }, (_, i) => (i % 7 === 0 ? `*the*` : `word${i % 50}`)).join(' ')
  const shown = words.replace(/\*/g, '')
  const map = characterMap(words, shown)
  const last = words.lastIndexOf('word')
  assert.equal(shown.slice(map[last], map[last] + 6), words.slice(last, last + 6))
}

// Footnote definitions by label, with their later lines.
{
  const notes = noteDefinitions('Body[^a].\n\n[^a]: First line\n    carried on.\n\n    and on.\n[^b]: Second.\n\nAfter.')
  const a = notes.get('a')
  const text = 'Body[^a].\n\n[^a]: First line\n    carried on.\n\n    and on.\n[^b]: Second.\n\nAfter.'
  assert.equal(text.slice(a.words, a.end), 'First line\n    carried on.\n\n    and on.')
  assert.equal(text.slice(notes.get('b').words, notes.get('b').end), 'Second.')
}

console.log('review-align: ok')
