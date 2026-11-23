import assert from 'node:assert/strict'
import { codeFence, fencedLines } from './code-fence.js'

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
// Four spaces in: a fence only where indentation is allowed, as in a list.
assert.deepEqual(fencedLines(lines('    ```\ncode')), [false, false])
assert.deepEqual(fencedLines(lines('    ```\ncode\n    ```\nb'), { indented: true }), [true, true, true, false])
// A line ending of \r\n is not text after the fence.
assert.deepEqual(fencedLines(lines('```\r\ncode\r\n```\r\nb')), [true, true, true, false])

console.log('code-fence: all passed')
