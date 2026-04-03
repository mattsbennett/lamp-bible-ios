import { Node, mergeAttributes } from '@tiptap/core'

/**
 * Custom image node with figure/figcaption support.
 * Markdown format: ![caption](media/mediaId)
 * Renders as <figure><img/><figcaption/></figure>
 */
export const ImageBlock = Node.create({
  name: 'imageBlock',
  group: 'block',
  atom: true,
  draggable: true,

  addAttributes() {
    return {
      src: { default: null },
      alt: { default: null },
      caption: { default: '' },
      mediaId: { default: null },
    }
  },

  addStorage() {
    return {
      markdown: {
        serialize(state, node) {
          const caption = node.attrs.caption || node.attrs.alt || ''
          const mediaId = node.attrs.mediaId
          if (mediaId) {
            state.write(`![${caption}](media/${mediaId})`)
          } else {
            state.write(`![${caption}](${node.attrs.src || ''})`)
          }
          state.closeBlock(node)
        },
        parse: {
          // Parsing handled by pre-processing in editor.js
        },
      },
    }
  },

  parseHTML() {
    return [
      {
        tag: 'figure.image-block',
        getAttrs(dom) {
          const img = dom.querySelector('img')
          return {
            src: img?.getAttribute('src') || null,
            alt: img?.getAttribute('alt') || null,
            caption: dom.querySelector('figcaption')?.textContent || '',
            mediaId: dom.getAttribute('data-media-id') || null,
          }
        },
      },
    ]
  },

  renderHTML({ HTMLAttributes }) {
    return ['figure', mergeAttributes({ class: 'image-block', 'data-media-id': HTMLAttributes.mediaId }),
      ['img', { src: HTMLAttributes.src, alt: HTMLAttributes.alt || HTMLAttributes.caption }],
      ['figcaption', {}, HTMLAttributes.caption || ''],
    ]
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement('figure')
      dom.classList.add('image-block')
      dom.setAttribute('data-media-id', node.attrs.mediaId || '')
      dom.contentEditable = 'false'

      const img = document.createElement('img')
      img.src = node.attrs.src || ''
      img.alt = node.attrs.alt || node.attrs.caption || ''
      img.addEventListener('click', () => {
        if (window.swiftBridge) {
          window.swiftBridge('imageTapped', { mediaId: node.attrs.mediaId })
        }
      })

      const figcaption = document.createElement('figcaption')
      figcaption.textContent = node.attrs.caption || ''

      dom.appendChild(img)
      dom.appendChild(figcaption)

      return { dom }
    }
  },
})
