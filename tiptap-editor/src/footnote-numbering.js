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
 * A line carrying on the definition above it: indented four spaces or a tab,
 * as Markdown indents a footnote's later lines, and as the apps' own writer
 * does (LampPersonalMarkdownWriter.footnoteDefinitions). Left in the body, it
 * would be read there as code.
 */
const CONTINUATION = /^(?: {4}|\t)/
const BLANK = /^[ \t]*$/

/** A definition's later line without the indent that made it one. */
export function unindented(line) {
  return BLANK.test(line) ? '' : line.replace(CONTINUATION, '')
}

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
 *
 * Definitions are read in runs, each one those written together, with only
 * blank lines between them: `runs` says where each was in the body, as the
 * line it came before, so it can be put back there, and the prose after it
 * stays after it.
 */
export function readFootnotes(markdown) {
  const body = []
  const definitions = []
  const lines = markdown.split('\n')
  const runs = []
  let run = null
  // The definition indented lines carry on, until something else comes.
  let open = null
  // The blank lines since the last definition, while only blank lines have
  // come since: the gap before the next one, if a definition comes next and
  // so carries its run on.
  let since = null
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    const match = line.match(DEFINITION)
    if (match) {
      if (since === null) {
        run = { at: body.length, definitions: [], gaps: [] }
        runs.push(run)
      } else {
        run.gaps.push(since)
      }
      open = { id: match[1], content: match[2] }
      definitions.push(open)
      run.definitions.push(open)
      since = 0
    } else if (open && CONTINUATION.test(line)) {
      // Kept as written, indent and all, so it can be written back so.
      open.content += '\n' + line
    } else if (BLANK.test(line)) {
      // Blank lines are the footnote's own when it carries on below them,
      // as a second paragraph does; otherwise they are the body's.
      let end = index
      while (end < lines.length && BLANK.test(lines[end]) && !(open && CONTINUATION.test(lines[end]))) end++
      const blanks = lines.slice(index, end)
      if (open && end < lines.length && CONTINUATION.test(lines[end])) {
        open.content += '\n' + blanks.join('\n')
      } else {
        body.push(...blanks)
        if (since !== null) since += blanks.length
      }
      index = end - 1
    } else {
      open = null
      since = null
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

  // Whether a run's definitions are set apart by blank lines, as the apps'
  // own writer sets them, or follow one another line by line, as the editor
  // did: written back as they were found, and set apart where nothing says.
  const placed = runs.map(({ at, definitions, gaps }) => ({
    at,
    definitions,
    spaced: !(gaps.length > 0 && gaps.every(gap => gap === 0)),
  }))

  return { content, definitions, numbers, runs: placed }
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

/**
 * How a definition block remembers the Markdown each definition was read from,
 * by the number it is shown as: `1:See%20**this**`. A definition still reading
 * as it did is written back as it was read, so opening a writing does not
 * rewrite its footnotes in the editor's own style, `_that_` as `*that*`.
 * Read back with decodeLabels.
 */
export function encodeSources(ordered) {
  return ordered
    .map(d => {
      try {
        return `${d.shown}:${encodeURIComponent(d.content)}`
      } catch {
        // Text that cannot be encoded (a lone surrogate) is written as the
        // editor reads it instead.
        return null
      }
    })
    .filter(Boolean)
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
