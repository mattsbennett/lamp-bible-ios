/**
 * Run with: node src/footnote-numbering.test.mjs
 *
 * The numbering is what a reader sees; the labels are what the writing says.
 * These hold the two apart — above all that opening a document and saving it
 * untouched gives back the labels it came with, because a read that renumbered
 * someone's draft would be far worse than labels shown out of order.
 */
import assert from 'node:assert/strict'
import {
  readFootnotes,
  shownLabel,
  orderedDefinitions,
  encodeLabels,
  decodeLabels,
  writtenLabel,
} from './footnote-numbering.js'

let failures = 0
function test(name, body) {
  try {
    body()
    console.log(`  ok  ${name}`)
  } catch (error) {
    failures += 1
    console.log(`FAIL  ${name}\n      ${error.message}`)
  }
}

/** What the definition block would serialize back to Markdown. */
function writeBack(ordered) {
  const labels = decodeLabels(encodeLabels(ordered))
  return ordered.map(d => `[^${writtenLabel(labels, d.shown)}]: ${d.content}`).join('\n')
}

test('numbers by the order of the first reference', () => {
  const read = readFootnotes(
    'Capacity[^lewis] has not changed[^2a], whatever is said[^lewis].\n' +
    '[^2a]: Mentioned second, defined first.\n' +
    '[^lewis]: Lewis, The Weight of Glory, p. 26.'
  )
  assert.equal(shownLabel(read.numbers, 'lewis'), '1')
  assert.equal(shownLabel(read.numbers, '2a'), '2')
  assert.deepEqual(orderedDefinitions(read).map(d => d.shown), ['1', '2'])
  assert.deepEqual(
    orderedDefinitions(read).map(d => d.content),
    ['Lewis, The Weight of Glory, p. 26.', 'Mentioned second, defined first.']
  )
})

test('a footnote added at the front renumbers the rest', () => {
  const defs = '\n[^a]: The first.\n[^b]: The second.\n[^c]: Added later, at the front.'
  const before = readFootnotes('One[^a] and two[^b].' + defs)
  assert.deepEqual(
    ['a', 'b', 'c'].map(id => shownLabel(before.numbers, id)),
    ['1', '2', '3']
  )
  const after = readFootnotes('Nought[^c], one[^a] and two[^b].' + defs)
  assert.deepEqual(
    ['c', 'a', 'b'].map(id => shownLabel(after.numbers, id)),
    ['1', '2', '3']
  )
})

test('a definition nothing refers to keeps its place at the end', () => {
  const read = readFootnotes('Only this one[^b].\n[^a]: Never cited.\n[^b]: Cited.')
  assert.deepEqual(orderedDefinitions(read).map(d => d.content), ['Cited.', 'Never cited.'])
})

test('a marker nothing defines keeps its label', () => {
  const read = readFootnotes('Defined[^a], and not[^missing].\n[^a]: Here.')
  assert.equal(shownLabel(read.numbers, 'a'), '1')
  assert.equal(shownLabel(read.numbers, 'missing'), 'missing')
})

test('loading and saving an untouched document gives back its own labels', () => {
  const read = readFootnotes(
    'Capacity[^lewis] has not changed[^2a].\n' +
    '[^2a]: Defined first.\n' +
    '[^lewis]: Lewis, p. 26.'
  )
  // Shown as 1 and 2, in reading order...
  assert.deepEqual(orderedDefinitions(read).map(d => d.shown), ['1', '2'])
  // ...and written back exactly as the writing had them.
  assert.equal(
    writeBack(orderedDefinitions(read)),
    '[^lewis]: Lewis, p. 26.\n[^2a]: Defined first.'
  )
})

test('a definition typed since loading is written exactly as it reads', () => {
  const read = readFootnotes('A claim[^lewis].\n[^lewis]: Lewis, p. 26.')
  const labels = decodeLabels(encodeLabels(orderedDefinitions(read)))
  assert.equal(writtenLabel(labels, '1'), 'lewis')
  // Nothing knows this one, so it stands for itself.
  assert.equal(writtenLabel(labels, 'newnote'), 'newnote')
  assert.equal(writtenLabel(labels, '9'), '9')
})

test('footnotes already labelled in reading order carry no mapping', () => {
  const read = readFootnotes('One[^1] and two[^2].\n[^1]: First.\n[^2]: Second.')
  // Nothing is renamed, so there is nothing to remember.
  assert.equal(encodeLabels(orderedDefinitions(read)), '')
  assert.equal(
    writeBack(orderedDefinitions(read)),
    '[^1]: First.\n[^2]: Second.'
  )
})

test('writing with no footnotes is left alone', () => {
  const read = readFootnotes('Plain prose, with nothing to note.')
  assert.equal(read.content, 'Plain prose, with nothing to note.')
  assert.deepEqual(read.definitions, [])
  assert.equal(encodeLabels(orderedDefinitions(read)), '')
})

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
