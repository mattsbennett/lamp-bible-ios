import './editor.css'
import { Editor, Extension } from '@tiptap/core'
import { EditorState, Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import { Fragment } from '@tiptap/pm/model'
import { closeHistory } from '@tiptap/pm/history'
import { StarterKit } from '@tiptap/starter-kit'
import { HardBreak } from '@tiptap/extension-hard-break'
import { Placeholder } from '@tiptap/extension-placeholder'
import { Table } from '@tiptap/extension-table'
import { TableRow } from '@tiptap/extension-table-row'
import { TableCell } from '@tiptap/extension-table-cell'
import { TableHeader } from '@tiptap/extension-table-header'
import { Markdown } from 'tiptap-markdown'
import { FootnoteRef, FootnoteDefinition, definitionHTML, noteLines, noteSpan, noteMarkdown, noteContent } from './extensions/footnote.js'
import {
  readFootnotes,
  decodeLabels,
  shownLabel,
  orderedDefinitions,
  encodeLabels,
  encodeSources,
  markerPattern,
} from './footnote-numbering.js'
import { AudioBlock } from './extensions/audio-block.js'
import { findVerseReferences } from './verse-references.js'
import { searchPattern, findMatches } from './search.js'
import { ImageBlock } from './extensions/image-caption.js'

// Media map for resolving media/id to file URLs
let mediaMap = {}

// Resolve media/id references to HTML figure elements that ImageBlock can parse
function resolveMediaPaths(md) {
  // Images: ![caption](media/id) -> <figure class="image-block">...</figure>
  const figure = (caption, id) => {
    const url = mediaMap[id] || (id.startsWith('lamp-media://') ? id : `media/${id}`)
    return `<figure class="image-block" data-media-id="${escapeHtmlAttribute(id)}"><img src="${escapeHtmlAttribute(url)}" alt="${escapeHtmlAttribute(caption)}"><figcaption>${escapeHtmlContent(caption)}</figcaption></figure>`
  }
  return md
    .replace(/!\[([^\]]*)\]\(media\/([^)]+)\)/g, (match, caption, id) => figure(caption, id))
    .replace(/!\[([^\]]*)\]\((lamp-media:\/\/[^)]+)\)/g, (match, caption, id) => figure(caption, id))
}

// Resolve audio block markdown to HTML that AudioBlock can parse
function resolveAudioBlocks(md) {
  // Audio: [caption](media/id) on its own line -> <div class="audio-block">...</div>
  const block = (caption, id) => `<div class="audio-block" data-media-id="${escapeHtmlAttribute(id)}" data-caption="${escapeHtmlAttribute(caption)}"><span class="audio-icon">🎵</span><span class="audio-caption">${escapeHtmlContent(caption)}</span></div>`
  return md
    .replace(/^(?<!!)\[([^\]]+)\]\(media\/([^)]+)\)$/gm, (match, caption, id) => block(caption, id))
    .replace(/^(?<!!)\[([^\]]+)\]\((lamp-media:\/\/[^)]+)\)$/gm, (match, caption, id) => block(caption, id))
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


// Extract footnote definitions and convert footnote refs to HTML.
//
// Footnotes are shown numbered by the order they are first referred to, so a
// writing can label them anything — [^lewis], [^2a], or numbers written out of
// order — and still read 1, 2, 3 down the page. Only the display is numbered:
// each original label travels with it, in `data-id` on a reference and in
// `data-labels` on the definition block, so what is written back to Markdown
// is what the writing already said.
function resolveFootnotes(md) {
  const read = readFootnotes(md)
  const { numbers } = read

  // Escaped on the way in: a label may hold any character but a space and a
  // closing bracket, a quotation mark among them.
  const content = read.content.replace(markerPattern(), (match, id) => {
    const shown = shownLabel(numbers, id)
    return `<sup class="footnote-ref" data-id="${escapeHtmlAttribute(id)}"`
      + ` data-number="${escapeHtmlAttribute(shown)}">[${escapeHtmlContent(shown)}]</sup>`
  })

  if (read.runs.length === 0) return content

  // Each run of definitions where it was written, a block of its own, apart
  // from what is around it so the Markdown reads it as a block.
  const lines = content.split('\n')
  for (const run of [...read.runs].reverse()) {
    lines.splice(run.at, 0, '', definitionsBlock(run, numbers), '')
  }
  return lines.join('\n')
}

// A run's definitions, numbered in reading order: each one's own Markdown
// shown as the body's is, bold as bold, and what it was read from kept with
// it, to be written back as it was.
function definitionsBlock(run, numbers) {
  const ordered = orderedDefinitions({ definitions: run.definitions, numbers })
  const defsHtml = ordered.map(d =>
    `<span class="footnote-label">[${escapeHtmlContent(d.shown)}]</span> ${definitionHTML(editor, d.content)}`
  ).join('<br>')
  const labels = escapeHtmlAttribute(encodeLabels(ordered))
  const sources = escapeHtmlAttribute(encodeSources(ordered))
  const spacing = run.spaced ? '' : ' data-spaced="false"'
  return `<div class="footnote-definition" data-labels="${labels}" data-sources="${sources}"${spacing}>${defsHtml}</div>`
}

let editor = null
let markdownTextarea = null
let currentMode = 'richtext' // 'richtext' or 'markdown'
let currentViewMode = 'edit' // 'edit', 'read', or 'present'
let debounceTimer = null
let currentMarkdown = ''
let savedSelection = null // { from, to } saved before sheet opens
let placeholderText = 'Start writing…'
let reportsHeight = false
// To the definitions holding the footnote labelled `id`, wherever they were
// written, or else the first.
function scrollToFootnote(id) {
  const blocks = Array.from(document.querySelectorAll('.footnote-definition'))
  const reference = Array.from(document.querySelectorAll('sup.footnote-ref'))
    .find(sup => sup.getAttribute('data-id') === String(id))
  const shown = reference?.getAttribute('data-number') ?? String(id)
  const def = blocks.find(block => block.innerText.split('\n').some(line => line.startsWith(`[${shown}]`)))
    ?? blocks[0]
  if (def) {
    def.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }
}

// What a footnote marker shows: its number in reading order, or its label
// until it has one.
function shownNumber(marker) {
  return String(marker.attrs.number ?? marker.attrs.id)
}

// Where the text of the note shown as `shown` begins, or null where the page
// doesn't hold it.
function notePosition(doc, shown) {
  let found = null
  doc.descendants((node, pos) => {
    if (found !== null) return false
    if (node.type.name !== 'footnoteDefinition') return true
    const line = noteLines(node).find(line => line.shown === shown)
    if (line) found = pos + 1 + line.text
    return false
  })
  return found
}

// Just after the first marker showing `shown`, or null.
function markerPosition(doc, shown) {
  let found = null
  doc.descendants((node, pos) => {
    if (found !== null) return false
    if (node.type.name === 'footnoteRef' && shownNumber(node) === shown) found = pos + node.nodeSize
    return true
  })
  return found
}

// The number of the note whose number is at `offset` in a block of notes,
// or null where `offset` is anywhere else.
function labelAt(block, offset) {
  const line = noteLines(block).find(line => line.shown !== null && offset >= line.start && offset <= line.text)
  return line ? line.shown : null
}

// What a click on a footnote's marker does while writing: 'jump' into the
// note, or open it in a 'popover' by the marker (setFootnoteClicks).
let footnoteClicks = 'jump'
// The note open by its marker, if one is: { panel, shown, markerPos }.
let notePopover = null

// The block of notes holding the note shown as `shown`, and where it is.
function noteBlock(doc, shown) {
  let found = null
  doc.descendants((node, pos) => {
    if (found !== null) return false
    if (node.type.name !== 'footnoteDefinition') return true
    if (noteLines(node).some(line => line.shown === shown)) found = { node, pos }
    return false
  })
  return found
}

// A note opened by its marker, to write in where it's referred to, as a
// host asks with setFootnoteClicks('popover'). What's typed goes into the
// note's own lines as it's typed, so it goes out to the host, and undoes,
// like any other edit. The panel sits outside the editor's own page, so the
// editor's keys and clicks leave it alone.
function openNotePopover(view, markerPos, shown) {
  closeNotePopover(false)
  const found = noteBlock(view.state.doc, shown)
  if (!found) return
  const panel = document.createElement('div')
  panel.className = 'note-popover'
  panel.setAttribute('role', 'dialog')
  panel.setAttribute('aria-label', `Note ${shown}`)
  const heading = document.createElement('div')
  heading.className = 'note-popover-heading'
  const title = document.createElement('span')
  title.textContent = `Note ${shown}`
  // Takes the footnote out, marker and note together; Undo brings it back.
  const remove = document.createElement('button')
  remove.type = 'button'
  remove.className = 'note-popover-remove'
  remove.textContent = 'Remove'
  remove.setAttribute('aria-label', `Remove footnote ${shown}`)
  heading.append(title, remove)
  const field = document.createElement('textarea')
  field.className = 'note-popover-text'
  field.value = noteMarkdown(editor, found.node, shown) ?? ''
  field.spellcheck = true
  panel.append(heading, field)
  document.body.appendChild(panel)
  notePopover = { panel, shown, markerPos }
  fitNotePopover(field)
  placeNotePopover(view, panel, markerPos)

  field.addEventListener('input', () => {
    writeNote(shown, field.value)
    fitNotePopover(field)
  })
  remove.addEventListener('click', () => {
    const marker = editor.state.doc.nodeAt(notePopover?.markerPos ?? -1)
    const label = marker?.type.name === 'footnoteRef' ? marker.attrs.id : null
    const at = notePopover?.markerPos ?? null
    closeNotePopover(false)
    if (label === null) return
    removeFootnote(label)
    // The caret where the marker was.
    const pos = Math.min(at, editor.state.doc.content.size)
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.near(editor.state.doc.resolve(pos))))
    editor.view.focus()
  })
  field.addEventListener('keydown', event => {
    if (event.key === 'Escape' || (event.key === 'Enter' && event.metaKey)) {
      event.preventDefault()
      closeNotePopover(true)
    }
  })
  document.addEventListener('mousedown', closeNotePopoverOutside, true)
  field.focus()
  field.setSelectionRange(field.value.length, field.value.length)
}

// Grows the note's box with what's in it, up to a dozen lines.
function fitNotePopover(field) {
  field.style.height = 'auto'
  const line = parseFloat(getComputedStyle(field).lineHeight) || 20
  field.style.height = Math.min(Math.max(field.scrollHeight, line * 2), line * 12) + 'px'
}

// Under the marker, or above it where there's no room below, and kept
// inside the page's width.
function placeNotePopover(view, panel, markerPos) {
  const at = view.coordsAtPos(markerPos)
  const width = panel.offsetWidth
  const height = panel.offsetHeight
  const left = Math.min(Math.max(8, at.left - 16), window.innerWidth - width - 8)
  const below = at.bottom + 6
  const top = below + height > window.innerHeight - 8 && at.top - height - 6 > 8
    ? at.top - height - 6
    : below
  panel.style.left = `${left + window.scrollX}px`
  panel.style.top = `${top + window.scrollY}px`
}

// Every marker for the footnote labelled `label`, and its note where the
// page holds it, out as one edit. Whether the note was found.
function removeFootnote(label) {
  const { state } = editor
  const markers = []
  let shown = null
  state.doc.descendants((node, pos) => {
    if (node.type.name === 'footnoteRef' && node.attrs.id === label) {
      markers.push(pos)
      shown = shown ?? shownNumber(node)
    }
    return true
  })
  if (shown === null) {
    // A note nothing refers to any more: its number from the block's own
    // record of which label each number stands for, or else its label.
    state.doc.descendants(node => {
      if (node.type.name !== 'footnoteDefinition') return true
      for (const [number, written] of decodeLabels(node.attrs.labels)) {
        if (written === label) shown = shown ?? number
      }
      return false
    })
    shown = shown ?? label
  }
  const tr = state.tr
  const found = noteBlock(state.doc, shown)
  const span = found && noteSpan(found.node, shown)
  if (span) {
    const lines = noteLines(found.node)
    const onlyNote = lines.every(line => line.shown === null || line.shown === shown)
    if (onlyNote) {
      tr.delete(found.pos, found.pos + found.node.nodeSize)
    } else {
      // With the line break before it, or after it for the first note.
      const start = found.pos + 1 + span.from
      const end = found.pos + 1 + span.to
      tr.delete(span.from > 0 ? start - 1 : start, span.from > 0 ? end : Math.min(end + 1, found.pos + found.node.nodeSize - 1))
    }
  }
  for (const pos of markers.reverse()) {
    const at = tr.mapping.map(pos)
    tr.delete(at, at + 1)
  }
  if (tr.docChanged) editor.view.dispatch(tr)
  return Boolean(span)
}

// Writes the note's Markdown into its lines in the document.
function writeNote(shown, markdown) {
  const found = noteBlock(editor.state.doc, shown)
  const span = found && noteSpan(found.node, shown)
  if (!span) return
  const from = found.pos + 1 + span.from
  const to = found.pos + 1 + span.to
  const content = noteContent(editor, shown, markdown)
  editor.view.dispatch(editor.state.tr.replaceWith(from, to, content))
  // Notes written above their marker move it as they grow or shrink.
  if (notePopover && from < notePopover.markerPos) notePopover.markerPos += content.size - (to - from)
}

function closeNotePopoverOutside(event) {
  if (notePopover && !notePopover.panel.contains(event.target)) closeNotePopover(false)
}

// Closes the open note, if there is one, and with `backToMarker` puts the
// caret back just after its marker, where the writer was.
function closeNotePopover(backToMarker) {
  if (!notePopover) return
  const { panel, markerPos } = notePopover
  notePopover = null
  panel.remove()
  document.removeEventListener('mousedown', closeNotePopoverOutside, true)
  if (backToMarker && editor.isEditable) {
    const after = Math.min(markerPos + 1, editor.state.doc.content.size)
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, after)))
    editor.view.focus()
  }
}

// The caret at `pos`, and the page brought round to it.
function goTo(view, pos) {
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, pos)))
  view.focus()
  revealCaret(view)
  // A keyboard rising after the tap takes the bottom of the page: once it
  // has, look again.
  const visible = window.visualViewport
  if (visible) {
    const again = () => {
      visible.removeEventListener('resize', again)
      revealCaret(view)
    }
    visible.addEventListener('resize', again)
    setTimeout(() => visible.removeEventListener('resize', again), 1000)
  }
}

// Scrolls the caret's line a third of the way down what can be seen of the
// page: the visual viewport, which a phone's keyboard shortens, rather than
// the page's whole height, half of which the keyboard can be covering. The
// line, not its block, since a block of notes can be taller than the page.
// A host that scrolls the page itself is kept to the caret by its reports.
function revealCaret(view) {
  let coords
  try {
    coords = view.coordsAtPos(view.state.selection.head)
  } catch (e) {
    return
  }
  const visible = window.visualViewport
  const top = visible ? visible.offsetTop : 0
  const height = visible ? visible.height : window.innerHeight
  window.scrollBy({ top: coords.top - (top + height / 3), behavior: 'smooth' })
}
// Names the document loaded last, so a host can tell a message about it from
// one the previous document sent just before the editor changed hands.
let documentToken = null
// Whether a single line break in the Markdown is a break in the text, as in a
// note typed as plain text, rather than a space, as Markdown otherwise reads it.
let lineBreaks = false

// Books and verse counts for finding verse references (setVerseCatalog);
// none until a host gives them, and then none are looked for.
let verseCatalog = null
const verseReferenceKey = new PluginKey('verseReferences')

// Each textblock's text, with where it starts in the document. A footnote
// reference or a line break stands for one place, as in the document, so an
// offset in this text is a position there.
function eachTextblock(doc, visit) {
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true
    let text = ''
    node.forEach(child => { text += child.isText ? child.text : '\uFFFC' })
    visit(text, pos + 1)
    return false
  })
}

function verseReferenceDecorations(doc) {
  if (!verseCatalog) return DecorationSet.empty
  const decorations = []
  eachTextblock(doc, (text, start) => {
    for (const reference of findVerseReferences(text, verseCatalog)) {
      decorations.push(Decoration.inline(start + reference.start, start + reference.end, { class: 'verse-reference' }))
    }
  })
  return DecorationSet.create(doc, decorations)
}

// Verse references shown as the host shows them where it draws the text: a
// mark on the screen only, so what is written is the Markdown as typed.
const VerseReferences = Extension.create({
  name: 'verseReferences',
  addProseMirrorPlugins() {
    return [new Plugin({
      key: verseReferenceKey,
      state: {
        init: (_, state) => verseReferenceDecorations(state.doc),
        apply: (tr, old) => (tr.docChanged || tr.getMeta(verseReferenceKey))
          ? verseReferenceDecorations(tr.doc)
          : old.map(tr.mapping, tr.doc),
      },
      props: {
        decorations: state => verseReferenceKey.getState(state),
      },
    })]
  },
})

// ---- Find ----

// What is being looked for (setSearch), kept apart from any one document so
// a search carries on into the next document loaded; null while none is.
let searchQuery = null
const searchKey = new PluginKey('search')
const noSearch = { matches: [], current: -1, decorations: DecorationSet.empty }

// Every match in the document, and which is current: the first at or after
// `at`, or the first of all.
function searchIn(doc, at) {
  if (!searchQuery) return noSearch
  const matches = []
  eachTextblock(doc, (text, start) => {
    for (const match of findMatches(text, searchQuery)) {
      matches.push({ from: start + match.start, to: start + match.end })
    }
  })
  if (matches.length === 0) return { ...noSearch }
  const after = matches.findIndex(match => match.from >= at)
  return withCurrent(doc, matches, after === -1 ? 0 : after)
}

function withCurrent(doc, matches, current) {
  const decorations = matches.map((match, index) => Decoration.inline(match.from, match.to, {
    class: index === current ? 'search-match search-match-current' : 'search-match',
  }))
  return { matches, current, decorations: DecorationSet.create(doc, decorations) }
}

// Matches are found again whenever the document changes, so a count and a
// current match never go stale. The current one stays where it was, or, if
// it was edited away, moves to the next. A transaction can say where the
// current match is to be found from instead (`at`), or which it is (`current`).
const Search = Extension.create({
  name: 'search',
  addProseMirrorPlugins() {
    return [new Plugin({
      key: searchKey,
      state: {
        init: (_, state) => searchIn(state.doc, state.selection.from),
        apply(tr, old) {
          const meta = tr.getMeta(searchKey)
          if (meta?.at !== undefined) return searchIn(tr.doc, meta.at)
          if (meta?.current !== undefined) return withCurrent(tr.doc, old.matches, meta.current)
          if (!tr.docChanged) return old
          const at = old.current === -1
            ? tr.selection.from
            : tr.mapping.map(old.matches[old.current].from, -1)
          return searchIn(tr.doc, at)
        },
      },
      props: {
        decorations: state => searchKey.getState(state).decorations,
      },
      // A host showing "3 of 12" hears whenever the document changes it.
      view: () => ({
        update(view, previous) {
          if (searchQuery && view.state.doc !== previous.doc) postToSwift('searchChanged', searchResult())
        },
      }),
    })]
  },
})

function searchResult() {
  if (!searchQuery || currentMode !== 'richtext') return { count: 0, current: 0 }
  const { matches, current } = searchKey.getState(editor.state)
  return { count: matches.length, current: current + 1 }
}

// The current match brought into sight, where it is out of sight, without
// moving the selection or taking focus from the host's find field.
function revealCurrentMatch() {
  const match = editor.view.dom.querySelector('.search-match-current')
  if (!match) return
  const box = match.getBoundingClientRect()
  if (box.top >= 0 && box.bottom <= window.innerHeight) return
  match.scrollIntoView({ block: 'center', inline: 'nearest' })
}

// Replaced as typed over it: the text takes the marks of what it replaces,
// so a bold word stays bold. Nothing for a replacement deletes the match.
function replaceMatch(tr, match, replacement) {
  if (!replacement) return tr.delete(match.from, match.to)
  const $from = tr.doc.resolve(match.from)
  const marks = $from.marksAcross(tr.doc.resolve(match.to)) ?? []
  return tr.replaceWith(match.from, match.to, editor.schema.text(replacement, marks))
}

// A break within a block, written as Markdown's backslash break, or, where
// single line breaks are breaks, as the plain line break it was read from.
// Only between content, as tiptap-markdown writes it: one at the end of a
// block says nothing.
const LineHardBreak = HardBreak.extend({
  addStorage() {
    return {
      markdown: {
        serialize(state, node, parent, index) {
          for (let i = index + 1; i < parent.childCount; i++) {
            if (parent.child(i).type != node.type) {
              if (state.inTable) state.write('<br>')
              else if (lineBreaks) state.text('\n', false)
              else state.write('\\\n')
              return
            }
          }
        },
        parse: {},
      },
    }
  },
})

// ---- Swift Bridge ----

function postToSwift(type, payload) {
  try {
    if (window.webkit?.messageHandlers?.tiptapBridge) {
      const message = { type, ...payload }
      if (documentToken !== null) message.token = documentToken
      window.webkit.messageHandlers.tiptapBridge.postMessage(message)
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
      // StarterKit brings Link; configured here rather than added again.
      StarterKit.configure({
        heading: { levels: [1, 2, 3] },
        hardBreak: false,
        link: {
          openOnClick: false,
          HTMLAttributes: { rel: null, target: null },
          // The apps' own links, to a verse or a Strong's entry. Link keeps
          // only web schemes otherwise, and drops the rest as it parses.
          protocols: ['lampbible'],
        },
      }),
      Placeholder.configure({
        placeholder: () => placeholderText,
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
      LineHardBreak,
      VerseReferences,
      Search,
      FootnoteRef,
      FootnoteDefinition,
      AudioBlock,
      ImageBlock,
    ],
    content: '',
    autofocus: false,

    editorProps: {
      // While writing, a footnote's marker leads into its note, the caret at
      // the start of its text, ready to write in, or, for a host that asks
      // (setFootnoteClicks), opens the note beside the marker; the note's
      // number leads back to the marker. The caret goes too, rather than the page alone:
      // on a phone a tap places the caret itself, and the page follows the
      // caret. A shift-click keeps the ordinary selection, and the keyboard
      // still selects or deletes a marker. Where the page doesn't hold the
      // note, as when a host keeps notes apart from the writing, the host is
      // told, as it is of a tap when reading.
      handleClickOn(view, pos, node, nodePos, event) {
        if (!view.editable || event.shiftKey) return false
        if (node.type.name === 'footnoteRef') {
          const shown = shownNumber(node)
          const note = notePosition(view.state.doc, shown)
          if (note === null) {
            postToSwift('footnoteTapped', { id: node.attrs.id, editing: true })
          } else if (footnoteClicks === 'popover') {
            openNotePopover(view, nodePos, shown)
          } else {
            goTo(view, note)
          }
          return true
        }
        if (node.type.name === 'footnoteDefinition') {
          const shown = labelAt(node, pos - nodePos - 1)
          const marker = shown === null ? null : markerPosition(view.state.doc, shown)
          if (marker === null) return false
          goTo(view, marker)
          return true
        }
        return false
      },
    },

    onUpdate({ editor }) {
      if (currentMode !== 'richtext') return
      scheduleContentUpdate()
    },

    onSelectionUpdate({ editor }) {
      if (currentMode !== 'richtext') return
      reportSelectionState()
      reportCaret()
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

// Markdown as the editor parses it: media, audio, quoted line breaks and
// footnotes turned into the HTML the extensions read.
function resolveForEditor(md) {
  let resolved = resolveMediaPaths(md)
  resolved = resolveAudioBlocks(resolved)
  resolved = resolveBlockquoteLineBreaks(resolved)
  return resolveFootnotes(resolved)
}

// The editor's height to its last line, measured from the top of the page so
// a margin above it counts, for a host that sizes the view to its text.
function reportContentHeight() {
  if (!reportsHeight) return
  const root = document.getElementById('tiptap-editor')
  postToSwift('contentHeight', {
    height: Math.ceil(root.getBoundingClientRect().bottom + window.scrollY),
  })
}

// Where the caret is, from the top of the page, for a host that scrolls the
// page itself and has to keep the caret in sight.
function reportCaret() {
  if (!reportsHeight || currentMode !== 'richtext') return
  let coords
  try {
    coords = editor.view.coordsAtPos(editor.state.selection.head)
  } catch (e) {
    return
  }
  postToSwift('caret', {
    top: Math.floor(coords.top + window.scrollY),
    bottom: Math.ceil(coords.bottom + window.scrollY),
  })
}

function cancelContentUpdate() {
  if (debounceTimer) clearTimeout(debounceTimer)
  debounceTimer = null
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
    closeNotePopover(false)
    currentMarkdown = markdown || ''
    if (currentMode === 'richtext') {
      editor.commands.setContent(resolveForEditor(currentMarkdown), { emitUpdate: false })
    } else {
      markdownTextarea.value = currentMarkdown
    }
  },

  getContent() {
    return getMarkdownContent()
  },

  // Replaces the document with another, for an editor handed from one note
  // or writing to the next. Nothing is reported back as an edit: a change
  // the previous document had not yet reported is dropped rather than
  // arriving at the next one's host as its own. And the undo history starts
  // afresh, so nothing can be undone back into the previous document.
  //
  // `token`, if given, comes back on every message about this document.
  load(markdown, token) {
    closeNotePopover(false)
    cancelContentUpdate()
    documentToken = token ?? null
    savedSelection = null
    currentMarkdown = markdown || ''
    markdownTextarea.value = currentMarkdown
    editor.commands.setContent(resolveForEditor(currentMarkdown), { emitUpdate: false })
    editor.view.updateState(EditorState.create({
      doc: editor.state.doc,
      plugins: editor.state.plugins,
    }))
    if (currentMode === 'richtext') reportSelectionState()
    // A document the same height as the last fires no resize, and the host
    // it was handed to would never learn its height.
    reportContentHeight()
    reportCaret()
  },

  // The books and verse counts verse references are found by: the host's
  // own, so the editor marks the references the host would. Null stops it.
  setVerseCatalog(catalog) {
    verseCatalog = catalog || null
    editor.view.dispatch(editor.state.tr.setMeta(verseReferenceKey, true))
  },

  // Single line breaks as breaks, for documents written as plain text, such
  // as a note. Applies to the next document loaded.
  setLineBreaks(on) {
    lineBreaks = on === true
    editor.storage.markdown.parser.md.set({ breaks: lineBreaks })
  },

  // A reference to a footnote the host keeps outside the document, at the
  // caret, or where the caret was when saveSelection was called.
  insertFootnoteRef(id) {
    const chain = editor.chain().focus()
    if (savedSelection) {
      chain.setTextSelection(savedSelection)
      savedSelection = null
    }
    chain.insertContent({ type: 'footnoteRef', attrs: { id: String(id) } }).run()
  },

  // Sizes the page to the text, for a host laying the editor out among
  // other views, and reports its height whenever it changes, and whether
  // anything in the page has focus.
  setReportsHeight(on) {
    if (reportsHeight || !on) return
    reportsHeight = true
    const style = document.createElement('style')
    style.id = 'lamp-compact-layout'
    style.textContent = `
      html, body { height: auto !important; }
      #tiptap-editor { min-height: 0 !important; padding: 10px 12px !important; }
      #tiptap-editor .tiptap { min-height: 0 !important; }
    `
    document.head.appendChild(style)
    new ResizeObserver(reportContentHeight).observe(document.getElementById('tiptap-editor'))
    document.addEventListener('focusin', () => postToSwift('focusChanged', { focused: true }))
    document.addEventListener('focusout', () => postToSwift('focusChanged', { focused: false }))
    reportContentHeight()
  },

  // The page behind the text, in either theme: the stylesheet's dark theme
  // is pure black, darker than the host's own surfaces.
  setBackgroundColor(css) {
    let style = document.getElementById('lamp-host-background')
    if (!style) {
      style = document.createElement('style')
      style.id = 'lamp-host-background'
      document.head.appendChild(style)
    }
    style.textContent = css ? `body, body.dark { --bg-color: ${css} !important; }` : ''
  },

  setPlaceholder(text) {
    placeholderText = text || ''
    // Placeholder decorations are drawn per transaction.
    editor.view.dispatch(editor.state.tr)
  },

  // Find, in the rich-text editor only. The query is literal text, found
  // within a block: options are { caseSensitive, wholeWord }. Every match is
  // marked, and the current one, the first at or after the selection, is
  // brought into sight. Nothing, or an empty query, ends the search. Each
  // call returns { count, current }, current counting from 1, 0 for none;
  // and while a search is set, every change to the document posts
  // `searchChanged` with the same.
  setSearch(query, options) {
    if (currentMode !== 'richtext') return { count: 0, current: 0 }
    searchQuery = searchPattern(query, options || {})
    editor.view.dispatch(editor.state.tr.setMeta(searchKey, { at: editor.state.selection.from }))
    revealCurrentMatch()
    return searchResult()
  },

  clearSearch() {
    if (!searchQuery) return
    searchQuery = null
    editor.view.dispatch(editor.state.tr.setMeta(searchKey, { at: 0 }))
  },

  findNext() {
    return moveCurrentMatch(1)
  },

  findPrevious() {
    return moveCurrentMatch(-1)
  },

  // The current match replaced, as one step to undo, and the next match
  // after it made current. A document that cannot be edited is left alone.
  replaceCurrent(replacement) {
    if (!searchQuery || currentMode !== 'richtext' || !editor.isEditable) return searchResult()
    const { matches, current } = searchKey.getState(editor.state)
    if (current === -1) return searchResult()
    const match = matches[current]
    const tr = replaceMatch(editor.state.tr, match, replacement || '')
    tr.setMeta(searchKey, { at: match.from + (replacement || '').length })
    editor.view.dispatch(closeHistory(tr))
    revealCurrentMatch()
    return searchResult()
  },

  // Every match replaced at once, undone at once. Returns how many were.
  replaceAll(replacement) {
    if (!searchQuery || currentMode !== 'richtext' || !editor.isEditable) return 0
    const { matches } = searchKey.getState(editor.state)
    if (matches.length === 0) return 0
    const tr = editor.state.tr
    // From the last, so each match's place is still where it was found.
    for (let index = matches.length - 1; index >= 0; index--) {
      replaceMatch(tr, matches[index], replacement || '')
    }
    editor.view.dispatch(closeHistory(tr))
    return matches.length
  },

  // The current match selected, with the editor focused: what a find bar
  // leaves behind as it closes. Focused at once, not as TipTap focuses, a
  // frame later and not at all if the page's focus is still on the editor,
  // as it can be while the host's find field has the keyboard.
  selectCurrentMatch() {
    if (!searchQuery || currentMode !== 'richtext') return
    const { matches, current } = searchKey.getState(editor.state)
    if (current === -1) return
    const match = matches[current]
    editor.view.dispatch(editor.state.tr.setSelection(
      TextSelection.create(editor.state.doc, match.from, match.to)
    ))
    editor.view.focus()
    revealCurrentMatch()
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

  // A footnote at the caret: its marker, and its note after the last of
  // the notes, or in a block of its own at the end where there are none.
  // One edit, so it goes out, and undoes, as one. A host editing notes by
  // their markers (setFootnoteClicks('popover')) gets the new note open by
  // its marker, to write in straight away.
  insertFootnote(id, content) {
    const label = String(id)
    let markerPos = null
    editor.chain().focus().command(({ tr }) => {
      tr.replaceSelectionWith(editor.schema.nodes.footnoteRef.create({ id: label }), false)
      markerPos = tr.selection.from - 1
      const steps = tr.steps.length
      // The text as given, not Markdown: what the phone's footnote sheet
      // takes is written back escaped, as it always has been.
      const note = Fragment.from(editor.schema.text(`[${label}] ${content || ''}`))
      let last = null
      tr.doc.descendants((node, pos) => {
        if (node.type.name === 'footnoteDefinition') last = { node, pos }
        return node.isBlock
      })
      if (last) {
        const end = last.pos + last.node.nodeSize - 1
        tr.insert(end, Fragment.from(editor.schema.nodes.hardBreak.create()).append(note))
      } else {
        tr.insert(tr.doc.content.size, editor.schema.nodes.footnoteDefinition.create(null, note))
      }
      markerPos = tr.mapping.slice(steps).map(markerPos)
      return true
    }).run()
    if (footnoteClicks === 'popover' && markerPos !== null) {
      openNotePopover(editor.view, markerPos, label)
    }
  },

  // Takes out the footnote labelled `id`: every marker for it, and its note
  // where the page holds it, as one edit. Whether the page held the note,
  // so a host keeping notes apart from the writing knows to take out its
  // own copy.
  removeFootnote(id) {
    return removeFootnote(String(id))
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
    editor.commands.setContent(resolveForEditor(currentMarkdown), { emitUpdate: false })
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
    closeNotePopover(false)
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
    scrollToFootnote(id)
  },

  // What a click on a footnote's marker does while writing: 'jump' into the
  // note, the default, or 'popover', opening the note by its marker to write
  // in there. Read mode is the same either way. A note the page doesn't
  // hold is reported to the host (footnoteTapped, editing) either way.
  setFootnoteClicks(behaviour) {
    footnoteClicks = behaviour === 'popover' ? 'popover' : 'jump'
    closeNotePopover(false)
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

  // Focuses the editor with the caret at a point in the page, as near as the
  // text allows: where a host's own drawing of the document was tapped.
  focusAt(x, y) {
    // A page handed from one document to the next can still hold the last
    // one's focus; focusing it again would be no focus at all, and a host
    // waiting on one to raise the keyboard would wait.
    if (editor.view.hasFocus()) editor.view.dom.blur()
    const found = editor.view.posAtCoords({ left: x, top: y - window.scrollY })
    if (found) {
      editor.chain().focus().setTextSelection(found.pos).run()
    } else {
      editor.commands.focus('end')
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

function moveCurrentMatch(step) {
  if (!searchQuery || currentMode !== 'richtext') return searchResult()
  const { matches, current } = searchKey.getState(editor.state)
  if (matches.length === 0) return searchResult()
  const next = (current + step + matches.length) % matches.length
  editor.view.dispatch(editor.state.tr.setMeta(searchKey, { current: next }))
  revealCurrentMatch()
  return searchResult()
}

function escapeHtmlContent(str) {
  const div = document.createElement('div')
  div.textContent = str
  return div.innerHTML
}

function escapeHtmlAttribute(str) {
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

// ---- Init ----
document.addEventListener('DOMContentLoaded', initEditor)
