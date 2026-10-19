import { Node, mergeAttributes } from '@tiptap/core'
import { decodeLabels, writtenLabel } from '../footnote-numbering.js'

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
    }
  },

  addStorage() {
    return {
      markdown: {
        serialize(state, node) {
          // Use textBetween so hardBreak nodes produce '\n' (textContent doesn't)
          const text = node.textBetween(0, node.content.size, '', '\n') || ''
          const lines = text.split('\n').filter(l => l.trim())
          const labels = decodeLabels(node.attrs.labels)
          const defs = []
          for (const line of lines) {
            const match = line.match(/^\[(\w+)\]\s*(.+)$/)
            if (match) {
              defs.push(`[^${writtenLabel(labels, match[1])}]: ${match[2]}`)
            }
          }
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
      getAttrs: el => ({ labels: el.getAttribute('data-labels') || '' }),
    }]
  },

  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, { class: 'footnote-definition' }), 0]
  },
})
