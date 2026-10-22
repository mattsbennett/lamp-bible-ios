// node src/verse-references.test.mjs
import assert from 'node:assert/strict'
import { findVerseReferences, resolveBook } from './verse-references.js'

const catalog = {
  names: { 'genesis': 1, 'john': 43, 'joshua': 6, '1 john': 62, '1 corinthians': 46, '1 peter': 60 },
  abbreviations: { 'gen': 1, 'jn': 43, '1cor': 46, '1jn': 62 },
  verses: { '1': [31, 25], '6': [18], '43': [51, 25, 36], '46': [31, 16, 23, 21, 13, 20, 40, 13, 27, 33, 34, 31, 13, 40, 58, 24], '60': [25], '62': [10] },
}
const refs = text => findVerseReferences(text, catalog).map(r => text.slice(r.start, r.end))
let passed = 0
function check(name, run) { run(); passed += 1; console.log(`  ok  ${name}`) }

check('a book named in full', () => assert.deepEqual(refs('See John 3:16 here'), ['John 3:16']))
check('a numbered book and a verse range', () => assert.deepEqual(refs('1 Corinthians 13:4-7 is long'), ['1 Corinthians 13:4-7']))
check('an abbreviation, with or without a stop', () => assert.deepEqual(refs('Gen 1:1 and Jn. 3:16'), ['Gen 1:1', 'Jn. 3:16']))
check('the start of a name', () => assert.deepEqual(refs('cf. 1 Pet 1:23'), ['1 Pet 1:23']))
check('a bracketed reference keeps its brackets', () => assert.deepEqual(refs('as [John 3:16] says'), ['[John 3:16]']))
check('a verse the translation lacks is not one', () => assert.deepEqual(refs('John 3:99 and John 22:1'), []))
check('a word that is no book is not one', () => assert.deepEqual(refs('Chapter 3:16 and Version 2:10'), []))
check('not inside a longer word or number', () => assert.deepEqual(refs('xJohn 3:16 and John 3:160'), []))
check('an ambiguous start goes to the first book in order', () => assert.equal(resolveBook('jo', catalog), 6))
check('a space before the book is not part of it', () => assert.deepEqual(refs('again — John 3:3;'), ['John 3:3']))
check('no catalog, no references', () => assert.deepEqual(findVerseReferences('John 3:16', null), []))
console.log(`\nall ${passed} passed`)
