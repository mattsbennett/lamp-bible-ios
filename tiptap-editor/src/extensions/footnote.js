import { Node, mergeAttributes, elementFromString } from '@tiptap/core'
import { DOMParser, Fragment } from '@tiptap/pm/model'
import { decodeLabels, shownDefinitionPattern, unindented, writtenLabel } from '../footnote-numbering.js'

/**
 * Inline footnote reference: renders as superscript [^1]
 */
export const FootnoteRef = Node.create({
  name: 'footnoteRef',
  group: 'inline',
  inline: true,
  atom: true,

  addAttributes() {
    return {
      // The label the writing used. Rendered as `data-id` because that is what
      // a tap reads and what re-parsing this node's own HTML expects; it is
      // also what the Markdown serializer below writes, so the writing itself
      // is never renumbered.
      id: {
        default: null,
        parseHTML: el => el.getAttribute('data-id'),
        renderHTML: attrs => (attrs.id === null ? {} : { 'data-id': attrs.id }),
      },
      // What the reader sees in its place: its position in reading order,
      // worked out when the Markdown was loaded. A footnote inserted since
      // then has none yet and shows its label until the document is reopened.
      number: {
        default: null,
        parseHTML: el => el.getAttribute('data-number'),
        renderHTML: attrs => (attrs.number === null ? {} : { 'data-number': attrs.number }),
      },
    }
  },

  addStorage() {
    return {
      markdown: {
        serialize(state, node) {
          state.write(`[^${node.attrs.id}]`)
        },
        parse: {
          // Parsing handled by pre-processing in editor.js
        },
      },
    }
  },

  parseHTML() {
    return [{
      tag: 'sup.footnote-ref',
      getAttrs: el => ({
        id: el.getAttribute('data-id'),
        number: el.getAttribute('data-number'),
      }),
    }]
  },

  renderHTML({ HTMLAttributes, node }) {
    const shown = node.attrs.number ?? node.attrs.id
    return ['sup', mergeAttributes(HTMLAttributes, { class: 'footnote-ref' }), `[${shown}]`]
  },
})

/**
 * Block-level footnote definition section.
 * Renders the [^id]: content lines at the bottom of the document.
 * Stored as a single block containing all definitions as text.
 */
export const FootnoteDefinition = Node.create({
  name: 'footnoteDefinition',
  group: 'block',
  content: 'inline*',
  defining: true,

  addAttributes() {
    return {
      definitions: { default: '' }, // raw text: "[^1]: content\n[^2]: content"
      // Which label each shown number stands for — `1:lewis,2:2a`. The block
      // is shown numbered in reading order, so without this, saving a document
      // would write the numbers back as the labels and cut every reference
      // loose from its note.
      labels: {
        default: '',
        parseHTML: el => el.getAttribute('data-labels') || '',
        renderHTML: attrs => (attrs.labels ? { 'data-labels': attrs.labels } : {}),
      },
      // The Markdown each definition was read from, by the number it is shown
      // as (encodeSources): written back as it was while it reads the same.
      sources: {
        default: '',
        parseHTML: el => el.getAttribute('data-sources') || '',
        renderHTML: attrs => (attrs.sources ? { 'data-sources': attrs.sources } : {}),
      },
      // Whether the definitions are written apart, a blank line between each,
      // as they were found (readFootnotes) and as the apps' own writer writes.
      spaced: {
        default: true,
        parseHTML: el => el.getAttribute('data-spaced') !== 'false',
        renderHTML: attrs => (attrs.spaced ? {} : { 'data-spaced': 'false' }),
      },
    }
  },

  addStorage() {
    return {
      markdown: {
        serialize(state, node) {
          const { editor } = this
          const defs = writtenDefinitions(node, (lines, source) => definitionMarkdown(editor, lines, source))
          if (defs.length > 0) {
            // After the blank line that closes the block before, as the
            // Markdown had it, and no further one.
            state.write(defs.join(node.attrs.spaced ? '\n\n' : '\n'))
            state.closeBlock(node)
          }
        },
        parse: {
          // Parsing handled by pre-processing in editor.js
        },
      },
    }
  },

  parseHTML() {
    return [{
      tag: 'div.footnote-definition',
      getAttrs: el => ({
        labels: el.getAttribute('data-labels') || '',
        sources: el.getAttribute('data-sources') || '',
        spaced: el.getAttribute('data-spaced') !== 'false',
      }),
    }]
  },

  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, { class: 'footnote-definition' }), 0]
  },
})

/**
 * The definitions in a block as they are written back, `[^label]: text`. A
 * line shown as `[n] text` begins one; any other line carries on the one
 * above it, as a footnote's later lines are shown, indented
 * (CONTINUATION_INDENT). Each definition's lines are turned into Markdown by
 * `toMarkdown(lines, source)`, with what it was read from, if it was: the
 * first line from after its number.
 */
export function writtenDefinitions(node, toMarkdown) {
  const labels = decodeLabels(node.attrs.labels)
  const sources = decodeLabels(node.attrs.sources)
  const shownDefinition = shownDefinitionPattern()
  const definitions = []
  for (const line of definitionLines(node)) {
    // A footnote reference stands for one place, so an offset in this text
    // is a place in the line.
    const text = line.textBetween(0, line.size, '', '\uFFFC')
    const match = text.match(shownDefinition)
    if (match) {
      definitions.push({ shown: match[1], lines: [line.cut(match[0].length - match[2].length)] })
    } else if (definitions.length > 0) {
      definitions[definitions.length - 1].lines.push(line)
    }
  }
  return definitions.map(({ shown, lines }) => {
    const markdown = toMarkdown(lines, sources.get(shown))
    return `[^${writtenLabel(labels, shown)}]:${markdown ? ` ${markdown}` : ''}`
  })
}

// The block's lines: what lies between its line breaks.
function definitionLines(node) {
  const lines = []
  let start = 0
  node.content.forEach((child, offset) => {
    if (child.type.name !== 'hardBreak') return
    lines.push(node.content.cut(start, offset))
    start = offset + child.nodeSize
  })
  lines.push(node.content.cut(start))
  return lines
}

/**
 * How a footnote's later lines are set in, under its first: by no-break
 * spaces, which the page keeps, so a later line cannot read as a definition
 * of its own, whatever it begins with.
 */
export const CONTINUATION_INDENT = '\u00A0'.repeat(4)

/**
 * A definition's Markdown as the editor shows it: its emphasis, code and
 * links, and each later line on a line of its own, set in.
 */
export function definitionHTML(editor, markdown) {
  const { md } = editor.storage.markdown.parser
  return markdown.split('\n')
    .map((line, index) => index === 0 ? md.renderInline(line) : CONTINUATION_INDENT + md.renderInline(unindented(line)))
    .join('<br>')
}

// A definition as Markdown. One that still reads as it was read is written
// as it was read: the serializer has its own style, and a footnote merely
// opened would come back restyled. One that does not is written as the apps'
// own writer writes one, its later lines set in four spaces.
function definitionMarkdown(editor, lines, source) {
  const { schema } = editor
  if (source !== undefined) {
    const shown = []
    lines.forEach((line, index) => {
      if (index > 0) shown.push(schema.nodes.hardBreak.create())
      line.forEach(node => shown.push(node))
    })
    const read = DOMParser.fromSchema(schema).parse(
      elementFromString(definitionHTML(editor, source)),
      { topNode: schema.nodes.footnoteDefinition.create() },
    )
    if (read.content.eq(Fragment.from(shown))) return source
  }
  const written = lines.map((line, index) => inlineMarkdown(editor, index === 0 ? line : withoutIndent(line)))
  while (written.length > 1 && written[written.length - 1] === '') written.pop()
  return written.map((line, index) => (index === 0 ? line : `    ${line}`)).join('\n')
}

function withoutIndent(line) {
  const text = line.textBetween(0, line.size, '', '\uFFFC')
  return line.cut(text.match(/^\s*/)[0].length)
}

function inlineMarkdown(editor, content) {
  const { schema } = editor
  const doc = schema.topNodeType.create(null, schema.nodes.paragraph.create(null, content))
  return editor.storage.markdown.serializer.serialize(doc)
}

/**
 * Each line of a block of notes, as offsets into its content: where it
 * starts and ends, the number it shows if it begins a note, and where that
 * note's text begins, after the number.
 */
export function noteLines(block) {
  const pattern = shownDefinitionPattern()
  const lines = []
  let start = 0
  const add = end => {
    const match = block.textBetween(start, end, '', '￼').match(pattern)
    lines.push({
      start,
      end,
      shown: match ? match[1] : null,
      text: match ? start + match[0].length - match[2].length : null,
    })
  }
  block.content.forEach((child, offset) => {
    if (child.type.name !== 'hardBreak') return
    add(offset)
    start = offset + child.nodeSize
  })
  add(block.content.size)
  return lines
}

/**
 * The note shown as `shown` in a block of notes: the offsets its lines run
 * between, from its number to the end of its last line, and those lines as
 * they are written, the first from after its number. Null if the block
 * doesn't hold it.
 */
export function noteSpan(block, shown) {
  const lines = noteLines(block)
  const first = lines.findIndex(line => line.shown === shown)
  if (first < 0) return null
  let last = first
  while (last + 1 < lines.length && lines[last + 1].shown === null) last += 1
  return {
    from: lines[first].start,
    to: lines[last].end,
    lines: lines.slice(first, last + 1).map((line, index) =>
      block.content.cut(index === 0 ? line.text : line.start, line.end)),
  }
}

/**
 * A note's Markdown as a writer edits it: later lines on lines of their own,
 * without the indent they're written with.
 */
export function noteMarkdown(editor, block, shown) {
  const span = noteSpan(block, shown)
  if (!span) return null
  const markdown = definitionMarkdown(editor, span.lines, decodeLabels(block.attrs.sources).get(shown))
  return markdown.split('\n').map((line, index) => (index === 0 ? line : unindented(line))).join('\n')
}

/** A note as the block shows it, number and all, from its Markdown. */
export function noteContent(editor, shown, markdown) {
  const { schema } = editor
  const number = String(shown).replace(/&/g, '&amp;').replace(/</g, '&lt;')
  return DOMParser.fromSchema(schema).parse(
    elementFromString(`[${number}] ${definitionHTML(editor, markdown)}`),
    { topNode: schema.nodes.footnoteDefinition.create() },
  ).content
}
