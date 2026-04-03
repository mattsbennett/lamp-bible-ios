import './editor.css'
import { Editor } from '@tiptap/core'
import { StarterKit } from '@tiptap/starter-kit'
import { Link } from '@tiptap/extension-link'
import { Placeholder } from '@tiptap/extension-placeholder'
import { Table } from '@tiptap/extension-table'
import { TableRow } from '@tiptap/extension-table-row'
import { TableCell } from '@tiptap/extension-table-cell'
import { TableHeader } from '@tiptap/extension-table-header'
import { Markdown } from 'tiptap-markdown'
import { FootnoteRef, FootnoteDefinition } from './extensions/footnote.js'
import { AudioBlock } from './extensions/audio-block.js'
import { ImageBlock } from './extensions/image-caption.js'

// Media map for resolving media/id to file URLs
let mediaMap = {}

// Resolve media/id references to HTML figure elements that ImageBlock can parse
function resolveMediaPaths(md) {
  // Images: ![caption](media/id) -> <figure class="image-block">...</figure>
  return md.replace(/!\[([^\]]*)\]\(media\/([^)]+)\)/g, (match, caption, id) => {
    const url = mediaMap[id] || `media/${id}`
    return `<figure class="image-block" data-media-id="${id}"><img src="${url}" alt="${escapeHtmlContent(caption)}"><figcaption>${escapeHtmlContent(caption)}</figcaption></figure>`
  })
}

// Resolve audio block markdown to HTML that AudioBlock can parse
function resolveAudioBlocks(md) {
  // Audio: [caption](media/id) on its own line -> <div class="audio-block">...</div>
  return md.replace(/^(?<!!)\[([^\]]+)\]\(media\/([^)]+)\)$/gm, (match, caption, id) => {
    return `<div class="audio-block" data-media-id="${id}" data-caption="${escapeHtmlContent(caption)}"><span class="audio-icon">🎵</span><span class="audio-caption">${escapeHtmlContent(caption)}</span></div>`
  })
}

// Preserve line breaks within blockquotes by converting to hard breaks
function resolveBlockquoteLineBreaks(md) {
  const lines = md.split('\n')
  const result = []

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const isQuoteLine = line.trimStart().startsWith('>')
    const nextLine = lines[i + 1]
    const nextIsQuoteLine = nextLine && nextLine.trimStart().startsWith('>')

    if (isQuoteLine && nextIsQuoteLine) {
      // Check if current line content (after >) is non-empty and next line content is also non-empty
      const currentContent = line.replace(/^\s*>\s?/, '')
      const nextContent = nextLine.replace(/^\s*>\s?/, '')

      // Only add <br> if both lines have content (not just empty > lines for paragraph breaks)
      if (currentContent.trim() && nextContent.trim()) {
        // Add hard break at end of line content
        result.push(line + '<br>')
      } else {
        result.push(line)
      }
    } else {
      result.push(line)
    }
  }

  return result.join('\n')
}


// Extract footnote definitions and convert footnote refs to HTML
function resolveFootnotes(md) {
  const lines = md.split('\n')
  const contentLines = []
  const footnoteDefinitions = []
  const defPattern = /^\[\^(\w+)\]:\s*(.+)$/

  for (const line of lines) {
    const match = line.match(defPattern)
    if (match) {
      footnoteDefinitions.push({ id: match[1], content: match[2] })
    } else {
      contentLines.push(line)
    }
  }

  // Convert [^id] refs to <sup> tags
  let content = contentLines.join('\n')
  content = content.replace(/\[\^(\w+)\]/g, (match, id) => {
    return `<sup class="footnote-ref" data-id="${id}">[${id}]</sup>`
  })

  // Append footnote definitions as HTML block
  if (footnoteDefinitions.length > 0) {
    const defsHtml = footnoteDefinitions.map(d =>
      `<span class="footnote-label">[${d.id}]</span> ${escapeHtmlContent(d.content)}`
    ).join('<br>')
    content += `\n<div class="footnote-definition">${defsHtml}</div>`
  }

  return content
}

let editor = null
let markdownTextarea = null
let currentMode = 'richtext' // 'richtext' or 'markdown'
let currentViewMode = 'edit' // 'edit', 'read', or 'present'
let debounceTimer = null
let currentMarkdown = ''
let savedSelection = null // { from, to } saved before sheet opens

// ---- Swift Bridge ----

function postToSwift(type, payload) {
  try {
    if (window.webkit?.messageHandlers?.tiptapBridge) {
      window.webkit.messageHandlers.tiptapBridge.postMessage({ type, ...payload })
    }
  } catch (e) {
    console.log('Swift bridge not available:', e)
  }
}

window.swiftBridge = function (type, payload) {
  postToSwift(type, payload || {})
}

// ---- Editor Setup ----

function initEditor() {
  const editorEl = document.getElementById('tiptap-editor')
  markdownTextarea = document.getElementById('markdown-editor')

  editor = new Editor({
    element: editorEl,
    extensions: [
      StarterKit.configure({
        heading: { levels: [1, 2, 3] },
        }),
      Link.configure({
        openOnClick: false,
        HTMLAttributes: { rel: null, target: null },
      }),
      Placeholder.configure({
        placeholder: 'Start writing…',
      }),
      Table.configure({
        resizable: false,
        HTMLAttributes: { class: 'tiptap-table' },
      }),
      TableRow,
      TableCell,
      TableHeader,
      Markdown.configure({
        html: true,
        transformPastedText: true,
        transformCopiedText: true,
        tightLists: true,
        indentation: {
          style: 'space',
          size: 4,
        },
      }),
      FootnoteRef,
      FootnoteDefinition,
      AudioBlock,
      ImageBlock,
    ],
    content: '',
    autofocus: false,

    onUpdate({ editor }) {
      if (currentMode !== 'richtext') return
      scheduleContentUpdate()
    },

    onSelectionUpdate({ editor }) {
      if (currentMode !== 'richtext') return
      reportSelectionState()
    },

    onFocus() {
      postToSwift('focusChanged', { focused: true })
    },

    onBlur() {
      postToSwift('focusChanged', { focused: false })
    },
  })

  // Markdown textarea events
  markdownTextarea.addEventListener('input', () => {
    if (currentMode !== 'markdown') return
    currentMarkdown = markdownTextarea.value
    scheduleContentUpdate()
  })

  markdownTextarea.addEventListener('focus', () => {
    if (currentMode === 'markdown') {
      postToSwift('focusChanged', { focused: true })
    }
  })

  markdownTextarea.addEventListener('blur', () => {
    if (currentMode === 'markdown') {
      postToSwift('focusChanged', { focused: false })
    }
  })

  // Click handler for non-editable modes (read/present)
  editorEl.addEventListener('click', (e) => {
    if (editor.isEditable) return

    // Intercept footnote ref clicks
    const footnoteRef = e.target.closest('sup.footnote-ref')
    if (footnoteRef) {
      e.preventDefault()
      const id = footnoteRef.getAttribute('data-id') || footnoteRef.textContent.replace(/[\[\]]/g, '')
      postToSwift('footnoteTapped', { id })
      return
    }

    // Intercept link clicks
    const link = e.target.closest('a')
    if (link) {
      e.preventDefault()
      const url = link.getAttribute('href')
      if (url) {
        postToSwift('linkTapped', { url })
      }
      return
    }

    // Intercept image clicks
    const img = e.target.closest('figure.image-block img')
    if (img) {
      const figure = img.closest('figure.image-block')
      const mediaId = figure?.getAttribute('data-media-id')
      if (mediaId) {
        postToSwift('imageTapped', { mediaId })
      }
      return
    }

    // Intercept audio block clicks
    const audioBlock = e.target.closest('.audio-block')
    if (audioBlock) {
      const mediaId = audioBlock.getAttribute('data-media-id')
      if (mediaId) {
        postToSwift('audioBlockTapped', { mediaId })
      }
      return
    }
  })

  postToSwift('ready', {})
}

function scheduleContentUpdate() {
  if (debounceTimer) clearTimeout(debounceTimer)
  debounceTimer = setTimeout(() => {
    const md = getMarkdownContent()
    currentMarkdown = md
    postToSwift('contentChanged', { markdown: md })
  }, 300)
}

function getMarkdownContent() {
  if (currentMode === 'markdown') {
    return markdownTextarea.value
  }
  // Extensions handle markdown serialization with media/id format directly
  let md = editor.storage.markdown.getMarkdown()

  // Post-process blockquotes: tiptap-markdown may output hard breaks as backslash
  // Convert "> Line 1\\\n> Line 2" or "> Line 1  \n> Line 2" patterns
  // Also handle cases where line breaks within blockquotes aren't properly prefixed
  md = md.replace(/^(>\s?)(.*)\\$/gm, '$1$2')  // Remove trailing backslash from quote lines
  md = md.replace(/^(>\s?)(.*)  $/gm, '$1$2')  // Remove trailing double space from quote lines

  // Remove empty blockquote lines between content lines (Enter key creates new paragraphs)
  // "> Line 1\n>\n> Line 2" -> "> Line 1\n> Line 2"
  md = md.replace(/^(>.*\S.*)\n>\s*\n(>)/gm, '$1\n$2')

  // Remove blank lines within lists to preserve nesting
  const lines = md.split('\n')
  const result = []
  let inList = false

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const isListItem = /^(\s*)([-*+]|\d+\.)\s/.test(line)
    const isEmpty = line.trim() === ''

    if (isListItem) {
      inList = true
      result.push(line)
    } else if (isEmpty && inList) {
      // Check if next non-empty line is also a list item
      let nextIsListItem = false
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].trim() !== '') {
          nextIsListItem = /^(\s*)([-*+]|\d+\.)\s/.test(lines[j])
          break
        }
      }
      if (nextIsListItem) {
        // Skip this blank line - it's within a list
        continue
      } else {
        // End of list
        inList = false
        result.push(line)
      }
    } else {
      inList = false
      result.push(line)
    }
  }

  return result.join('\n')
}

function reportSelectionState() {
  if (!editor) return
  postToSwift('selectionChanged', {
    bold: editor.isActive('bold'),
    italic: editor.isActive('italic'),
    heading: editor.isActive('heading') ? editor.getAttributes('heading').level : 0,
    blockquote: editor.isActive('blockquote'),
    bulletList: editor.isActive('bulletList'),
    orderedList: editor.isActive('orderedList'),
    link: editor.isActive('link'),
    table: editor.isActive('table'),
  })
}

// ---- Public API (called from Swift) ----

window.editorAPI = {
  setContent(markdown) {
    currentMarkdown = markdown || ''
    if (currentMode === 'richtext') {
      // Convert custom elements to HTML before parsing
      let resolved = resolveMediaPaths(currentMarkdown)
      resolved = resolveAudioBlocks(resolved)

      resolved = resolveBlockquoteLineBreaks(resolved)
      resolved = resolveFootnotes(resolved)
      editor.commands.setContent(resolved, false)
    } else {
      markdownTextarea.value = currentMarkdown
    }
  },

  getContent() {
    return getMarkdownContent()
  },

  toggleBold() {
    editor.chain().focus().toggleBold().run()
    reportSelectionState()
  },

  toggleItalic() {
    editor.chain().focus().toggleItalic().run()
    reportSelectionState()
  },

  setHeading(level) {
    if (level === 0) {
      editor.chain().focus().setParagraph().run()
    } else {
      editor.chain().focus().toggleHeading({ level }).run()
    }
    reportSelectionState()
  },

  setParagraph() {
    editor.chain().focus().setParagraph().run()
    reportSelectionState()
  },

  toggleBlockquote() {
    editor.chain().focus().toggleBlockquote().run()
    reportSelectionState()
  },

  toggleBulletList() {
    editor.chain().focus().toggleBulletList().run()
    reportSelectionState()
  },

  toggleOrderedList() {
    editor.chain().focus().toggleOrderedList().run()
    reportSelectionState()
  },

  indent() {
    editor.chain().focus().sinkListItem('listItem').run()
  },

  outdent() {
    editor.chain().focus().liftListItem('listItem').run()
  },

  insertLink(url) {
    if (!url) {
      editor.chain().focus().unsetLink().run()
      return
    }
    // Restore saved selection if the editor lost focus (e.g. sheet was open)
    if (savedSelection && savedSelection.from !== savedSelection.to) {
      editor.chain().focus().setTextSelection(savedSelection).setLink({ href: url }).run()
      savedSelection = null
    } else {
      const { from, to } = editor.state.selection
      if (from !== to) {
        editor.chain().focus().setLink({ href: url }).run()
      } else {
        editor.chain().focus().extendMarkRange('link').setLink({ href: url }).run()
      }
    }
  },

  removeLink() {
    editor.chain().focus().extendMarkRange('link').unsetLink().run()
  },

  insertFootnote(id, content) {
    // Insert footnote reference at cursor
    editor.chain().focus().insertContent({
      type: 'footnoteRef',
      attrs: { id },
    }).run()

    // Find or create footnote definition block at end
    const html = editor.getHTML()
    const defBlock = document.querySelector('.footnote-definition')
    if (defBlock) {
      // Append to existing definitions
      defBlock.innerHTML += `<br><span class="footnote-label">[${id}]</span> ${escapeHtmlContent(content)}`
    } else {
      // Create new definition block at end
      editor.commands.insertContentAt(editor.state.doc.content.size, {
        type: 'footnoteDefinition',
        attrs: { definitions: `[^${id}]: ${content}` },
        content: [{ type: 'text', text: `[${id}] ${content}` }],
      })
    }
  },

  insertScriptureQuote(citation, text) {
    // Citation is italic first paragraph, quote text is second paragraph
    const html = `<blockquote><p><em>${escapeHtmlContent(citation)}</em></p><p>${escapeHtmlContent(text)}</p></blockquote>`
    editor.chain().focus().insertContent(html).run()
  },

  insertImage(mediaId, caption, fileURL) {
    editor.chain().focus().insertContent({
      type: 'imageBlock',
      attrs: {
        src: fileURL || '',
        alt: caption || '',
        caption: caption || '',
        mediaId: mediaId,
      },
    }).run()
  },

  insertAudioBlock(mediaId, caption) {
    editor.chain().focus().insertContent({
      type: 'audioBlock',
      attrs: {
        mediaId: mediaId,
        caption: caption || 'Audio',
      },
    }).run()
  },

  insertHorizontalRule() {
    editor.chain().focus().setHorizontalRule().run()
  },

  insertTable(rows, cols, withHeaderRow) {
    editor.chain().focus().insertTable({ rows, cols, withHeaderRow: withHeaderRow !== false }).run()
  },

  addRowAfter() {
    editor.chain().focus().addRowAfter().run()
  },

  addColumnAfter() {
    editor.chain().focus().addColumnAfter().run()
  },

  deleteRow() {
    editor.chain().focus().deleteRow().run()
  },

  deleteColumn() {
    editor.chain().focus().deleteColumn().run()
  },

  deleteTable() {
    editor.chain().focus().deleteTable().run()
  },

  switchToRichText() {
    if (currentMode === 'richtext') return
    currentMode = 'richtext'
    // Convert current markdown and load into TipTap with pre-processing
    currentMarkdown = markdownTextarea.value
    let resolved = resolveMediaPaths(currentMarkdown)
    resolved = resolveAudioBlocks(resolved)
    resolved = resolveBlockquoteLineBreaks(resolved)
    resolved = resolveFootnotes(resolved)
    editor.commands.setContent(resolved, false)
    markdownTextarea.style.display = 'none'
    document.getElementById('tiptap-editor').style.display = 'block'
  },

  switchToMarkdown() {
    if (currentMode === 'markdown') return
    // Get current content as markdown
    currentMarkdown = getMarkdownContent()
    currentMode = 'markdown'
    markdownTextarea.value = currentMarkdown
    document.getElementById('tiptap-editor').style.display = 'none'
    markdownTextarea.style.display = 'block'
  },

  setMode(mode) {
    currentViewMode = mode
    document.body.classList.remove('mode-edit', 'mode-read', 'mode-present')
    document.body.classList.add('mode-' + mode)
    const isEditable = mode === 'edit'
    editor.setEditable(isEditable)
    if (!isEditable) {
      // Force richtext display in non-edit modes and sync currentMode
      currentMode = 'richtext'
      markdownTextarea.style.display = 'none'
      document.getElementById('tiptap-editor').style.display = 'block'
    }
  },

  scrollToFootnote(id) {
    const def = document.querySelector('.footnote-definition')
    if (def) {
      def.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }
  },

  setPresentPadding(bottom) {
    document.documentElement.style.setProperty('--present-bottom-padding', bottom + 'px')
  },

  setTheme(isDark) {
    document.body.classList.toggle('dark', isDark)
  },

  setFontSize(size) {
    document.documentElement.style.setProperty('--font-size', size + 'px')
  },

  setMediaMap(map) {
    mediaMap = map || {}
  },

  focus() {
    if (currentMode === 'richtext') {
      editor.commands.focus()
    } else {
      markdownTextarea.focus()
    }
  },

  blur() {
    if (currentMode === 'richtext') {
      editor.commands.blur()
    } else {
      markdownTextarea.blur()
    }
  },

  getSelectedText() {
    if (currentMode !== 'richtext' || !editor) return ''
    const { from, to } = editor.state.selection
    return editor.state.doc.textBetween(from, to, ' ')
  },

  saveSelection() {
    if (!editor) return
    const { from, to } = editor.state.selection
    savedSelection = { from, to }
  },

  restoreSelection() {
    if (!editor || !savedSelection) return
    editor.chain().focus().setTextSelection(savedSelection).run()
    savedSelection = null
  },
}

function escapeHtmlContent(str) {
  const div = document.createElement('div')
  div.textContent = str
  return div.innerHTML
}

// ---- Init ----
document.addEventListener('DOMContentLoaded', initEditor)
