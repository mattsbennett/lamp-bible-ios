// The page's bare-address finder, held to the same cases as core's
// LampBareLinks, so the native readers and the page link the same words.
import assert from 'node:assert/strict'
import { findBareAddresses } from './bare-links.js'

const found = text => findBareAddresses(text).map(address => address.href)
const written = text => findBareAddresses(text).map(address => text.slice(address.start, address.end))

// Written out: found, and what each opens.
assert.deepEqual(found('See https://example.com/news for more.'), ['https://example.com/news'])
assert.deepEqual(found('Or http://example.com.'), ['http://example.com'])
assert.deepEqual(found('Try www.example.com today'), ['http://www.example.com'])
assert.deepEqual(found('Write to alice@example.com.'), ['mailto:alice@example.com'])
assert.deepEqual(written('(see https://example.com/x)'), ['https://example.com/x'])

// What it opens is what it says.
assert.deepEqual(found('See www.youtube.com/@jane.doe now'), ['http://www.youtube.com/@jane.doe'])
assert.deepEqual(found('Email +support@example.com'), ['mailto:+support@example.com'])
assert.deepEqual(written('See (https://en.wikipedia.org/wiki/Bible_(disambiguation))'), ['https://en.wikipedia.org/wiki/Bible_(disambiguation)'])
assert.deepEqual(found('Write www.alice@example.com'), ['mailto:www.alice@example.com'])
assert.deepEqual(found('Write www.first.last@example.com'), ['mailto:www.first.last@example.com'])
assert.deepEqual(found('Write _support@example.com'), ['mailto:_support@example.com'])
assert.deepEqual(found('See ‘https://example.com/page’ today'), ['https://example.com/page'])
assert.deepEqual(found("Contact 'alice@example.com'."), ['mailto:alice@example.com'])
assert.deepEqual(found('www.example.com?x=1 here'), ['http://www.example.com?x=1'])
assert.deepEqual(found('www.example.com?email=alice@example.org'), ['http://www.example.com?email=alice@example.org'])
assert.deepEqual(found('参照：https://example.com/help。'), ['https://example.com/help'])
assert.deepEqual(found('参照：https://example.com/help。を見る'), ['https://example.com/help'])
assert.deepEqual(found('詳細(https://example.com/help)を参照'), ['https://example.com/help'])
assert.deepEqual(found("'https://example.com/O'Reilly'"), ["https://example.com/O'Reilly"])
assert.deepEqual(found('"https://example.com/a"—"details"'), ['https://example.com/a'])
assert.deepEqual(found('https://example.com./guide'), ['https://example.com./guide'])
assert.deepEqual(found('<https://example.com/help> and {https://example.com}'), ['https://example.com/help', 'https://example.com'])
assert.deepEqual(found('https://example.com/search?q=commonmark&hl;'), ['https://example.com/search?q=commonmark'])
const long = 'https://example.com/download?token=' + 'a1'.repeat(600)
assert.deepEqual(found(`Get ${long} now`), [long])

// What isn't plainly an address is words.
for (const text of [
  'Ask a?b@example.com', 'Ask a/b@example.com', 'Or mailto:alice@example.com', 'Not alice@example.com_',
  "Write o'connor@example.com", 'Write alice@example.cóm', 'https://example.com_extra/',
  'a!www.alice@example.com', 'https://example.com/help<next', 'alice@example.com-',
  'ftp://files.example.org/archive(https://example.com)', 'mailto:alice@example.com?body=Try%20(https://example.org)',
  'https://www.example.com。au/guide', "''support@example.com'", 'https://www.example.com。例/guide',
  '//files.example.org/archive(https://example.com)', 'Write ~support@example.com',
  'Read outline.md first.', 'John 3.16 and v1.2', 'example.com', 'ftp://example.com/file',
]) {
  assert.deepEqual(found(text), [], text)
}

// A part hidden (a link, code, a footnote's reference) the address runs into:
// left as words, never linked to part of itself.
assert.deepEqual(found('See https://example.com/report￼ now'), [])
assert.deepEqual(found('See ￼https://example.com now'), [])
assert.deepEqual(found('See https://example.com/￼￼￼ and https://plain.example.'), ['https://plain.example'])

// More of what isn't plainly an address.
for (const text of [
  '(https://example.com)\uFFFC', 'https://example.com。𠀀.org/guide', 'https:///example.org/', 'https://2130706433/page',
]) {
  assert.deepEqual(found(text), [], text)
}
assert.deepEqual(found('https://example.com/docs\u200BNext'), ['https://example.com/docs'])
assert.deepEqual(found('https://bücher.de/'), ['https://bücher.de/'])
assert.deepEqual(found('https://example.com/O’Reilly/details'), [], 'never cut short in its path')
assert.deepEqual(found('https://bu\u0308cher.de/'), ['https://bu\u0308cher.de/'])
assert.deepEqual(found('https://उदाहरण.भारत'), ['https://उदाहरण.भारत'])
assert.deepEqual(found('cafe\u0301https://example.com'), [])
assert.deepEqual(found('https://example.com\u0085Next'), ['https://example.com'])
const semicolons = Date.now()
findBareAddresses('https://example.com' + ';'.repeat(50_000))
assert.ok(Date.now() - semicolons < 1000)

// Text around an address no character of which breaks the reading.
assert.deepEqual(found('https://example.com\ńNext line'), ['https://example.com'])
assert.deepEqual(found('😀 https://example.com'), ['https://example.com'])

// A long run with no address in it is read quickly.
const began = Date.now()
assert.deepEqual(findBareAddresses('a.b-c_d+'.repeat(10_000) + ' ' + ')'.repeat(20_000) + ' ' + ';'.repeat(20_000)), [])
assert.ok(Date.now() - began < 1000)

console.log('bare-links: ok')
