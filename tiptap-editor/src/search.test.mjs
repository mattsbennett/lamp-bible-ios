// node src/search.test.mjs
import assert from 'node:assert/strict'
import { searchPattern, findMatches } from './search.js'

const found = (text, query, options) => findMatches(text, searchPattern(query, options)).map(m => text.slice(m.start, m.end))
const at = (text, query, options) => findMatches(text, searchPattern(query, options)).map(m => [m.start, m.end])
let passed = 0
function check(name, run) { run(); passed += 1; console.log(`  ok  ${name}`) }

check('every occurrence, in order', () => assert.deepEqual(at('grace upon grace', 'grace'), [[0, 5], [11, 16]]))
check('case is ignored unless asked', () => {
  assert.deepEqual(found('Grace and GRACE', 'grace'), ['Grace', 'GRACE'])
  assert.deepEqual(found('Grace and grace', 'grace', { caseSensitive: true }), ['grace'])
})
check('the query is literal text', () => {
  assert.deepEqual(found('a.b axb (c) [d] $5', 'a.b'), ['a.b'])
  assert.deepEqual(found('a.b axb (c) [d] $5', '(c)'), ['(c)'])
  assert.deepEqual(found('a.b axb (c) [d] $5', '[d]'), ['[d]'])
  assert.deepEqual(found('a.b axb (c) [d] $5', '$5'), ['$5'])
  assert.deepEqual(found('back\\slash', '\\'), ['\\'])
})
check('a whole word is not found inside a longer one', () => {
  assert.deepEqual(found('graceful grace disgrace', 'grace', { wholeWord: true }), ['grace'])
  assert.deepEqual(found('grace2 grace', 'grace', { wholeWord: true }), ['grace'])
})
check('a combining mark is part of the word', () => assert.deepEqual(found('gracéd grace', 'grace', { wholeWord: true }), ['grace']))
check('punctuation and a footnote reference end a word', () => assert.deepEqual(at('grace, grace￼', 'grace', { wholeWord: true }), [[0, 5], [7, 12]]))
check('a match does not run across a footnote reference or a line break', () => {
  assert.deepEqual(found('gra￼ce', 'grace'), [])
  assert.deepEqual(found('gra￼ce', 'gra ce'), [])
})
check('case folding keeps offsets', () => {
  const text = 'İstanbul and Istanbul'
  assert.deepEqual(at(text, 'istanbul').map(([s, e]) => text.slice(s, e)), ['Istanbul'])
  assert.deepEqual(at('ÉCOLE école', 'école'), [[0, 5], [6, 11]])
})
check('characters beyond the basic plane count as JavaScript counts them', () => assert.deepEqual(at('😀 grace', 'grace'), [[3, 8]]))
check('no query, no pattern', () => {
  assert.equal(searchPattern(''), null)
  assert.equal(searchPattern(null), null)
  assert.deepEqual(findMatches('text', null), [])
})
console.log(`\nall ${passed} passed`)
