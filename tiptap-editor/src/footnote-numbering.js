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

/**
 * What a label may be: any run of characters with no space in it and no closing
 * bracket — which is what the Mac accepts. A writing shared from there may
 * label a footnote `[^pinker-48]`, and it must be read here as it is read
 * there, or the marker would show as typed and its note would stay in the
 * prose. Everything that looks for a footnote, here and in the editor, takes
 * its pattern from this one so the two cannot drift apart again.
 */
const LABEL = String.raw`[^\]\s]+`

/** A fresh pattern for the markers in a body: `$1` is the label. */
export function markerPattern() {
  return new RegExp(String.raw`\[\^(${LABEL})\]`, 'g')
}

/** A definition line as the Markdown has it: `$1` the label, `$2` the content. */
const DEFINITION = new RegExp(String.raw`^\s{0,3}\[\^(${LABEL})\]:[ \t]*(.*)$`)

/**
 * A definition line as the editor shows it — `[1] content`, numbered and
 * without the caret: `$1` what it is shown as, `$2` the content.
 */
export function shownDefinitionPattern() {
  return new RegExp(String.raw`^\[(${LABEL})\]\s*(.*)$`)
}

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
  for (const match of content.matchAll(markerPattern())) {
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
    // The label is percent-encoded: it may hold a comma or a colon of its own,
    // which would otherwise read as this attribute's own punctuation.
    .map(d => `${d.shown}:${encodeURIComponent(d.id)}`)
    .join(',')
}

export function decodeLabels(value) {
  const labels = new Map()
  for (const pair of (value || '').split(',')) {
    const separator = pair.indexOf(':')
    if (separator > 0) {
      labels.set(pair.slice(0, separator), decodeLabel(pair.slice(separator + 1)))
    }
  }
  return labels
}

/** A mangled attribute is better read as it stands than thrown away. */
function decodeLabel(value) {
  try {
    return decodeURIComponent(value)
  } catch {
    return value
  }
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
