import assert from 'node:assert/strict'
import { codeFence } from './code-fence.js'

assert.equal(codeFence(''), '```')
assert.equal(codeFence('plain code'), '```')
assert.equal(codeFence('a `tick` and ``two``'), '```')
assert.equal(codeFence('```\nfenced inside\n```'), '````')
assert.equal(codeFence('````` five'), '``````')
assert.equal(codeFence('~~~\ntildes do not count'), '```')

console.log('code-fence: all passed')
