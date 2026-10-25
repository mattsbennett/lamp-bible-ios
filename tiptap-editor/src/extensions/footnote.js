import { Node, mergeAttributes, elementFromString } from '@tiptap/core'
import { DOMParser } from '@tiptap/pm/model'
import { decodeLabels, shownDefinitionPattern, writtenLabel } from '../footnote-numbering.js'

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
    }
  },

  addStorage() {
    return {
      markdown: {
        serialize(state, node) {
          const { editor } = this
          const defs = writtenDefinitions(node, (content, source) => definitionMarkdown(editor, content, source))
          if (defs.length > 0) {
            state.write('\n' + defs.join('\n'))
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
      }),
    }]
  },

  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, { class: 'footnote-definition' }), 0]
  },
})

/**
 * The definitions in a block as they are written back, `[^label]: text`: one
 * for each line shown as `[n] text`, the text after the number turned into
 * Markdown by `toMarkdown(content, source)`, with what that definition was
 * read from, if it was.
 */
export function writtenDefinitions(node, toMarkdown) {
  const labels = decodeLabels(node.attrs.labels)
  const sources = decodeLabels(node.attrs.sources)
  const shownDefinition = shownDefinitionPattern()
  const defs = []
  for (const line of definitionLines(node)) {
    // A footnote reference stands for one place, so an offset in this text
    // is a place in the line.
    const match = line.textBetween(0, line.size, '', '\uFFFC').match(shownDefinition)
    if (!match) continue
    const content = line.cut(match[0].length - match[2].length)
    const markdown = toMarkdown(content, sources.get(match[1]))
    defs.push(`[^${writtenLabel(labels, match[1])}]:${markdown ? ` ${markdown}` : ''}`)
  }
  return defs
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

/** A definition's Markdown as the editor shows it: its emphasis, code and links. */
export function definitionHTML(editor, markdown) {
  return editor.storage.markdown.parser.md.renderInline(markdown)
}

// A definition's text as Markdown. One that still reads as it was read is
// written as it was read: the serializer has its own style, and a footnote
// merely opened would come back restyled.
function definitionMarkdown(editor, content, source) {
  const { schema } = editor
  if (source !== undefined) {
    const read = DOMParser.fromSchema(schema).parse(
      elementFromString(definitionHTML(editor, source)),
      { topNode: schema.nodes.footnoteDefinition.create() },
    )
    if (read.content.eq(content)) return source
  }
  const doc = schema.topNodeType.create(null, schema.nodes.paragraph.create(null, content))
  return editor.storage.markdown.serializer.serialize(doc)
}
