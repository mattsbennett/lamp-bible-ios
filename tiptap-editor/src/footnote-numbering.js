/**
 * Numbering a writing's footnotes by the order they are first referred to.
 *
 * The labels in the Markdown are the writer's shorthand — `[^lewis]`, `[^2a]`,
 * or numbers written out of order — and were shown exactly as typed, so adding
 * a footnote near the front of a long piece meant renumbering every later one
 * by hand. A reader is now shown 1, 2, 3 in reading order instead.
 *
 * Only the display is numbered. Every original label is carried alongside it so
 * that what is written back to Markdown is what the writing already said: a
 * document opened and saved untouched must come back byte for byte, or a mere
 * read would renumber someone's draft under them.
 *
 * Kept free of the editor and the browser so it can be exercised on its own.
 */

const REF = /\[\^(\w+)\]/g
const DEFINITION = /^\[\^(\w+)\]:\s*(.+)$/

/**
 * Splits Markdown into its body and its footnote definitions, and works out
 * what number each footnote is shown as.
 *
 * A definition nothing refers to keeps its place after the ones that are
 * referred to, in the order it was written: it is still the writer's note.
 * A marker nothing defines keeps its label — numbering it as though it had a
 * note, or dropping it, would hide the mistake.
 */
export function readFootnotes(markdown) {
  const body = []
  const definitions = []
  for (const line of markdown.split('\n')) {
    const match = line.match(DEFINITION)
    if (match) {
      definitions.push({ id: match[1], content: match[2] })
    } else {
      body.push(line)
    }
  }

  const content = body.join('\n')
  const defined = new Set(definitions.map(d => d.id))
  const numbers = new Map()
  for (const match of content.matchAll(REF)) {
    const id = match[1]
    if (defined.has(id) && !numbers.has(id)) numbers.set(id, numbers.size + 1)
  }
  for (const definition of definitions) {
    if (!numbers.has(definition.id)) numbers.set(definition.id, numbers.size + 1)
  }

  return { content, definitions, numbers }
}

/** What a footnote is shown as: its number, or its label when it has none. */
export function shownLabel(numbers, id) {
  return numbers.has(id) ? String(numbers.get(id)) : id
}

/**
 * The definitions in reading order, each with the number it is shown as and
 * the label it must be written back as.
 */
export function orderedDefinitions({ definitions, numbers }) {
  return [...definitions]
    .sort((a, b) => (numbers.get(a.id) ?? 0) - (numbers.get(b.id) ?? 0))
    .map(d => ({ ...d, shown: shownLabel(numbers, d.id) }))
}

/**
 * How a definition block remembers which label each shown number stands for,
 * as one attribute value: `1:lewis,2:2a`.
 *
 * By number rather than by position, so that editing the block — adding a
 * definition, removing one, moving one — cannot quietly attach a note to the
 * wrong label.
 */
export function encodeLabels(ordered) {
  return ordered
    .filter(d => d.shown !== d.id)
    .map(d => `${d.shown}:${d.id}`)
    .join(',')
}

export function decodeLabels(value) {
  const labels = new Map()
  for (const pair of (value || '').split(',')) {
    const separator = pair.indexOf(':')
    if (separator > 0) {
      labels.set(pair.slice(0, separator), pair.slice(separator + 1))
    }
  }
  return labels
}

/**
 * The label to write back to Markdown for a definition shown as `shown`.
 *
 * Anything this block has no record of — a definition the writer typed since
 * it was loaded — is written exactly as it reads.
 */
export function writtenLabel(labels, shown) {
  return labels.get(shown) ?? shown
}
