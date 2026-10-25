/**
 * Run with: node src/footnote-numbering.test.mjs
 *
 * The numbering is what a reader sees; the labels are what the writing says.
 * These hold the two apart — above all that opening a document and saving it
 * untouched gives back the labels it came with, because a read that renumbered
 * someone's draft would be far worse than labels shown out of order.
 */
import assert from 'node:assert/strict'
import { Schema } from '@tiptap/pm/model'
import { writtenDefinitions, CONTINUATION_INDENT } from './extensions/footnote.js'
import {
  readFootnotes,
  shownLabel,
  orderedDefinitions,
  encodeLabels,
  encodeSources,
  decodeLabels,
  writtenLabel,
  unindented,
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
  return ordered
    .map(d => `[^${writtenLabel(labels, d.shown)}]:${d.content ? ` ${d.content}` : ''}`)
    .join('\n')
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

test('a label the Mac accepts is read here too', () => {
  // The Mac takes any label with no space and no closing bracket, so a writing
  // shared from there may hold any of these. Read as \\w+, the marker showed as
  // typed and the definition stayed in the prose.
  const read = readFootnotes(
    'Vocabulary[^pinker-48], capacity[^lewis.26], and both[^a-b].\n' +
    '[^pinker-48]: Pinker, The Language Instinct, p. 48.\n' +
    '[^lewis.26]: Lewis, The Weight of Glory, p. 26.\n' +
    '[^a-b]: Both of them.'
  )
  assert.equal(read.content, 'Vocabulary[^pinker-48], capacity[^lewis.26], and both[^a-b].')
  assert.deepEqual(
    ['pinker-48', 'lewis.26', 'a-b'].map(id => shownLabel(read.numbers, id)),
    ['1', '2', '3']
  )
  assert.equal(writeBack(orderedDefinitions(read)).split('\n')[0], '[^pinker-48]: Pinker, The Language Instinct, p. 48.')
})

test('a definition indented as Markdown allows is still a definition', () => {
  const read = readFootnotes('A claim[^a].\n   [^a]: Indented three spaces.')
  assert.equal(read.content, 'A claim[^a].')
  assert.deepEqual(orderedDefinitions(read).map(d => d.content), ['Indented three spaces.'])
})

test('a definition left empty keeps its label rather than its number', () => {
  const read = readFootnotes('A claim[^lewis].\n[^lewis]:')
  assert.equal(shownLabel(read.numbers, 'lewis'), '1')
  assert.equal(writeBack(orderedDefinitions(read)), '[^lewis]:')
})

test('a label holding the mapping\'s own punctuation survives it', () => {
  const read = readFootnotes('A claim[^lewis,p26].\n[^lewis,p26]: Lewis, p. 26.')
  const ordered = orderedDefinitions(read)
  assert.equal(ordered[0].shown, '1')
  assert.equal(writeBack(ordered), '[^lewis,p26]: Lewis, p. 26.')
})

test('a label cannot carry a quotation mark into an attribute unescaped', () => {
  // Only the editor writes the HTML, but it builds the attribute from this
  // mapping, so the mapping must come back with the quotation mark still in it.
  const read = readFootnotes('A claim[^say"so"].\n[^say"so"]: Said so.')
  const labels = decodeLabels(encodeLabels(orderedDefinitions(read)))
  assert.equal(writtenLabel(labels, '1'), 'say"so"')
  assert.ok(!encodeLabels(orderedDefinitions(read)).includes('"'))
})

// ---- Through the editor's own serializer ----
//
// The definition block reads its lines back out of what is displayed, which is
// where numbering could quietly rewrite a writing's labels. This runs the
// block's real reading of its lines — it needs no DOM — over a block built as
// the editor builds it, with each line's text taken as it stands.

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    text: { group: 'inline' },
    hardBreak: { inline: true, group: 'inline' },
    footnoteRef: { inline: true, group: 'inline', atom: true, attrs: { id: {} } },
    footnoteDefinition: { group: 'block', content: 'inline*', attrs: { labels: { default: '' }, sources: { default: '' } } },
  },
  marks: { bold: {} },
})

function block(shownLines, labels, sources = '') {
  const content = []
  shownLines.forEach((line, index) => {
    if (index > 0) content.push(schema.nodes.hardBreak.create())
    if (line) content.push(schema.text(line))
  })
  return schema.nodes.footnoteDefinition.create({ labels, sources }, content)
}

const asText = content => content.textBetween(0, content.size, '', '\uFFFC')
const linesAsText = lines => lines.map(asText).join('\n')

function serialized(shownLines, labels) {
  return writtenDefinitions(block(shownLines, labels), linesAsText).join('\n')
}

test('the definition block writes back the labels it was given', () => {
  const read = readFootnotes(
    'Vocabulary[^pinker-48], capacity[^lewis.26], and both[^a,b].\n' +
    '[^pinker-48]: Pinker, p. 48.\n' +
    '[^lewis.26]: Lewis, p. 26.\n' +
    '[^a,b]: Both of them.'
  )
  const ordered = orderedDefinitions(read)
  assert.deepEqual(ordered.map(d => d.shown), ['1', '2', '3'])
  assert.equal(
    serialized(ordered.map(d => `[${d.shown}] ${d.content}`), encodeLabels(ordered)),
    '[^pinker-48]: Pinker, p. 48.\n[^lewis.26]: Lewis, p. 26.\n[^a,b]: Both of them.'
  )
})

test('a definition typed into the block is written as it reads', () => {
  const read = readFootnotes('A claim[^lewis].\n[^lewis]: Lewis, p. 26.')
  const ordered = orderedDefinitions(read)
  assert.equal(
    serialized(['[1] Lewis, p. 26.', '[sontag] Added since.'], encodeLabels(ordered)),
    '[^lewis]: Lewis, p. 26.\n[^sontag]: Added since.'
  )
})

test('each definition is turned into Markdown after its number, with what it was read from', () => {
  const read = readFootnotes('A[^lewis] b[^2a].\n[^lewis]: Lewis, **p. 26**.\n[^2a]: Second.')
  const ordered = orderedDefinitions(read)
  const seen = []
  const node = block(['[1] Lewis, p. 26.', '[2]   Second.', '[3] Added since.'], encodeLabels(ordered), encodeSources(ordered))
  const written = writtenDefinitions(node, (lines, source) => {
    seen.push([linesAsText(lines), source])
    return linesAsText(lines)
  })
  assert.deepEqual(seen, [
    ['Lewis, p. 26.', 'Lewis, **p. 26**.'],
    ['Second.', 'Second.'],
    ['Added since.', undefined],
  ])
  assert.deepEqual(written, ['[^lewis]: Lewis, p. 26.', '[^2a]: Second.', '[^3]: Added since.'])
})

test('a line that begins no definition carries on the one above it', () => {
  const lines = []
  const node = block(['before anything', '[1] first', `${CONTINUATION_INDENT}[sic] second`, '', 'typed on', '[2] next'], '')
  writtenDefinitions(node, given => { lines.push(given.map(asText)); return '' })
  assert.deepEqual(lines, [
    ['first', `${CONTINUATION_INDENT}[sic] second`, '', 'typed on'],
    ['next'],
  ])
})

test('a line keeps what is marked in it, and a reference in it', () => {
  const bold = schema.marks.bold.create()
  const node = schema.nodes.footnoteDefinition.create({}, [
    schema.text('[1] See '), schema.text('this', [bold]), schema.nodes.footnoteRef.create({ id: 'x' }), schema.text('.'),
  ])
  let content = null
  writtenDefinitions(node, lines => { content = lines[0]; return '' })
  assert.equal(content.childCount, 4)
  assert.equal(content.child(0).text, 'See ')
  assert.ok(bold.isInSet(content.child(1).marks))
  assert.equal(content.child(2).type.name, 'footnoteRef')
})

test('an empty definition is written with nothing after its colon', () => {
  assert.deepEqual(writtenDefinitions(block(['[1]'], ''), () => ''), ['[^1]:'])
})

// ---- Footnotes over more than one line ----
//
// As the apps' own writer writes them (LampPersonalMarkdownWriter): later
// lines set in four spaces, an empty one as four spaces, and a blank line
// between definitions.

const written = '[^1]: first line\n    second **bold** line\n    \n    fourth line\n\n[^2]: single'

test('a definition takes the lines set in beneath it', () => {
  const read = readFootnotes('Grace[^1] and faith[^2].\n\n' + written)
  assert.deepEqual(read.definitions, [
    { id: '1', content: 'first line\n    second **bold** line\n    \n    fourth line' },
    { id: '2', content: 'single' },
  ])
  assert.equal(read.content.trim(), 'Grace[^1] and faith[^2].')
  assert.equal(read.spaced, true)
})

test('a tab sets a line in as four spaces do', () => {
  assert.deepEqual(readFootnotes('[^1]: a\n\tb').definitions, [{ id: '1', content: 'a\n\tb' }])
})

test('blank lines are the footnote\'s own when it carries on below them', () => {
  const read = readFootnotes('Body[^1].\n\n[^1]: para one\n\n    para two\n\nAfter.')
  assert.deepEqual(read.definitions, [{ id: '1', content: 'para one\n\n    para two' }])
  assert.equal(read.content, 'Body[^1].\n\n\nAfter.')
})

test('what comes after the footnotes, not set in, is the body\'s', () => {
  const read = readFootnotes('Body[^1].\n\n[^1]: note\n    more\n\nAfter the footnotes.\nNext[^2].\n[^2]: two\nNot set in.')
  assert.deepEqual(read.definitions.map(d => d.content), ['note\n    more', 'two'])
  assert.ok(read.content.includes('After the footnotes.\nNext[^2].'))
  assert.ok(read.content.endsWith('Not set in.'))
})

test('blank lines between definitions are remembered', () => {
  assert.equal(readFootnotes('A[^1].\n[^1]: a\n[^2]: b').spaced, false)
  assert.equal(readFootnotes('A[^1].\n[^1]: a\n\n[^2]: b').spaced, true)
  assert.equal(readFootnotes('A[^1].\n[^1]: a').spaced, true)
  assert.equal(readFootnotes('A[^1].\n[^1]: a\n[^2]: b\n\n[^3]: c').spaced, true)
  // Definitions apart, with prose between, say nothing either way.
  assert.equal(readFootnotes('[^1]: a\nProse.\n[^2]: b').spaced, true)
})

test('a later line loses the indent that made it one', () => {
  assert.equal(unindented('    x'), 'x')
  assert.equal(unindented('\tx'), 'x')
  assert.equal(unindented('      x'), '  x')
  assert.equal(unindented('    '), '')
  assert.equal(unindented('  '), '')
})

test('what a definition was read from survives any text', () => {
  const ordered = [
    { shown: '1', id: 'a', content: 'See **this**, _that_ and [John 3:16](lampbible://verse/43003016).' },
    { shown: '2', id: 'b', content: 'commas, colons: 100% \\ and ünïcode 😀' },
    { shown: '3', id: 'c', content: '' },
  ]
  const sources = decodeLabels(encodeSources(ordered))
  for (const d of ordered) assert.equal(sources.get(d.shown), d.content)
})

test('text that cannot be encoded is left out, not thrown on', () => {
  const sources = decodeLabels(encodeSources([{ shown: '1', id: 'a', content: 'lone \ud800' }, { shown: '2', id: 'b', content: 'fine' }]))
  assert.equal(sources.get('1'), undefined)
  assert.equal(sources.get('2'), 'fine')
})

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`)
process.exit(failures === 0 ? 0 : 1)
