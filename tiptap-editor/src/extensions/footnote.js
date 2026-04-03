import { Node, mergeAttributes } from '@tiptap/core'

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
      id: { default: null },
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
      getAttrs: el => ({ id: el.getAttribute('data-id') }),
    }]
  },

  renderHTML({ HTMLAttributes }) {
    return ['sup', mergeAttributes(HTMLAttributes, { class: 'footnote-ref' }), `[${HTMLAttributes.id}]`]
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
    }
  },

  addStorage() {
    return {
      markdown: {
        serialize(state, node) {
          // Use textBetween so hardBreak nodes produce '\n' (textContent doesn't)
          const text = node.textBetween(0, node.content.size, '', '\n') || ''
          const lines = text.split('\n').filter(l => l.trim())
          const defs = []
          for (const line of lines) {
            const match = line.match(/^\[(\w+)\]\s*(.+)$/)
            if (match) {
              defs.push(`[^${match[1]}]: ${match[2]}`)
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
    return [{ tag: 'div.footnote-definition' }]
  },

  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, { class: 'footnote-definition' }), 0]
  },
})
