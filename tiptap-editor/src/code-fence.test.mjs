import assert from 'node:assert/strict'
import { codeFence, fencedLines, codeLines } from './code-fence.js'

assert.equal(codeFence(''), '```')
assert.equal(codeFence('plain code'), '```')
assert.equal(codeFence('a `tick` and ``two``'), '```')
assert.equal(codeFence('```\nfenced inside\n```'), '````')
assert.equal(codeFence('````` five'), '``````')
assert.equal(codeFence('~~~\ntildes do not count'), '```')

const lines = text => text.split('\n')
assert.deepEqual(fencedLines(lines('a\n```\ncode\n```\nb')), [false, true, true, true, false])
// A shorter run inside is code; a longer or equal one of the same kind closes.
assert.deepEqual(fencedLines(lines('````\n```\n~~~~\n`````\nb')), [true, true, true, true, false])
// A backtick fence whose info string holds a backtick opens nothing.
assert.deepEqual(fencedLines(lines('``` a`b\nc')), [false, false])
// Text after a closing run keeps the fence open; an unclosed one runs on.
assert.deepEqual(fencedLines(lines('```\n``` x\nc')), [true, true, true])
// Four spaces in, at the top level: no fence.
assert.deepEqual(fencedLines(lines('    ```\ncode')), [false, false])

// Code anywhere, as markdown-it reads it: in a list item, in a quote at any
// depth, and ending with its quote when it is not closed.
assert.deepEqual(codeLines('- a\n\n    ```\n    x\n    ```\nb'), [false, false, true, true, true, false])
assert.deepEqual(codeLines('> ```\n> x\n> ```\nb'), [true, true, true, false])
assert.deepEqual(codeLines('> > ~~~\n> > x\n> > ~~~'), [true, true, true])
assert.deepEqual(codeLines('> ```\n> code\n\nOutside\n\n> first\n> second'), [true, true, false, false, false, false, false])
// Codex's case: a line indented in a quote's paragraph is the paragraph's.
assert.deepEqual(codeLines('> before\n>     ~~~\n> after\n> last'), [false, false, false, false])
// A lone \r ends a line for markdown-it, and moves none here: a fence
// after one is found, on the line it is part of (Codex's case).
assert.deepEqual(codeLines('a\rb\n```\nx\n```'), [false, true, true, true])
assert.deepEqual(codeLines('> before\r> ```\n> one\n> two\n> ```'), [true, true, true, true])
// HTML is read as HTML, as the page reads it: a fence in a comment is the
// comment's (Codex's case).
assert.deepEqual(codeLines('<!--\n```\n-->\n\n> first\n> second'), [false, false, false, false, false, false])
assert.deepEqual(codeLines('```\r\nx\r\n```\r\nb'), [true, true, true, false])
assert.deepEqual(codeLines('no fence here'), [false])

// A line ending of \r\n is not text after the fence.
assert.deepEqual(fencedLines(lines('```\r\ncode\r\n```\r\nb')), [true, true, true, false])

console.log('code-fence: all passed')
