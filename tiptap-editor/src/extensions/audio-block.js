import { Node, mergeAttributes } from '@tiptap/core'

/**
 * Custom TipTap node for audio block placeholders.
 * Markdown format: [caption](media/mediaId)
 * Renders as a tappable placeholder with audio icon.
 */
export const AudioBlock = Node.create({
  name: 'audioBlock',
  group: 'block',
  atom: true,
  draggable: true,

  addAttributes() {
    return {
      mediaId: { default: null },
      caption: { default: 'Audio' },
    }
  },

  addStorage() {
    return {
      markdown: {
        serialize(state, node) {
          const caption = node.attrs.caption || 'Audio'
          const mediaId = node.attrs.mediaId || ''
          state.write(`[${caption}](media/${mediaId})`)
          state.closeBlock(node)
        },
        parse: {
          // Parsing handled by pre-processing in editor.js
        },
      },
    }
  },

  parseHTML() {
    return [{ tag: 'div.audio-block' }]
  },

  renderHTML({ HTMLAttributes }) {
    const div = ['div', mergeAttributes(HTMLAttributes, {
      class: 'audio-block',
      'data-media-id': HTMLAttributes.mediaId,
      'data-caption': HTMLAttributes.caption,
    }),
      ['span', { class: 'audio-icon' }, '\u{1F3B5}'],
      ['span', { class: 'audio-caption' }, HTMLAttributes.caption || 'Audio'],
    ]
    return div
  },

  addNodeView() {
    return ({ node, HTMLAttributes }) => {
      const dom = document.createElement('div')
      dom.classList.add('audio-block')
      dom.setAttribute('data-media-id', node.attrs.mediaId || '')
      dom.setAttribute('data-caption', node.attrs.caption || 'Audio')

      const icon = document.createElement('span')
      icon.classList.add('audio-icon')
      icon.textContent = '\u{1F3B5}'

      const caption = document.createElement('span')
      caption.classList.add('audio-caption')
      caption.textContent = node.attrs.caption || 'Audio'

      dom.appendChild(icon)
      dom.appendChild(caption)

      dom.addEventListener('click', () => {
        if (window.swiftBridge) {
          window.swiftBridge('audioBlockTapped', { mediaId: node.attrs.mediaId })
        }
      })

      return { dom }
    }
  },
})
