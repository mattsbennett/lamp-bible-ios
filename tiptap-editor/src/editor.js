import './editor.css'
import { Editor, Extension, createDocument, getMarkRange } from '@tiptap/core'
import { EditorState, Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import { DOMSerializer, Fragment } from '@tiptap/pm/model'
import { Transform } from '@tiptap/pm/transform'
import { MarkdownSerializerState } from '@tiptap/pm/markdown'
import { closeHistory } from '@tiptap/pm/history'
import { StarterKit } from '@tiptap/starter-kit'
import { HardBreak } from '@tiptap/extension-hard-break'
import { Placeholder } from '@tiptap/extension-placeholder'
import { Table } from '@tiptap/extension-table'
import { TableRow } from '@tiptap/extension-table-row'
import { TableCell } from '@tiptap/extension-table-cell'
import { TableHeader } from '@tiptap/extension-table-header'
import { Markdown } from 'tiptap-markdown'
import { FootnoteRef, FootnoteDefinition, definitionHTML, noteLines, noteSpan, noteMarkdown, noteContent, CONTINUATION_INDENT } from './extensions/footnote.js'
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
import { findBareAddresses } from './bare-links.js'
import { searchPattern, findMatches } from './search.js'
import { traceDocument, placeByTrace, markdownRange, aroundLink, wholeLines, tidyKeeping } from './review-trace.js'
import { MARK_START, MARK_END, MARK_POINT, PLACE_END, placeDigit, readMarkers, withoutSpans, withoutTypedChanges, restorableByBlock, nextMark } from './review-marks.js'
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
// host asks with setFootnoteClicks('popover'). The note shows as the page
// shows it, its emphasis drawn rather than spelled out, in a small editor of
// its own: a separate one, outside the page's editor, so neither's keys or
// clicks reach the other. What's written goes into the note's own lines as
// it's written, so it goes out to the host, and undoes, like any other edit.
// A note holding more than text, such as a marker of its own, opens as its
// Markdown instead, since the small editor couldn't keep what it can't hold.
function openNotePopover(view, markerPos, shown) {
  closeNotePopover(false)
  const found = noteBlock(view.state.doc, shown)
  const span = found && noteSpan(found.node, shown)
  if (!span) return
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
  panel.append(heading)
  document.body.appendChild(panel)
  notePopover = { panel, shown, markerPos, noteEditor: null }

  const close = backToMarker => closeNotePopover(backToMarker)
  const textOnly = span.lines.every(line => {
    let ok = true
    line.forEach(node => { ok = ok && node.isText })
    return ok
  })
  if (textOnly) {
    const holder = document.createElement('div')
    holder.className = 'note-popover-editor'
    panel.append(holder)
    notePopover.noteEditor = new Editor({
      element: holder,
      extensions: [
        StarterKit.configure({
          heading: false,
          blockquote: false,
          bulletList: false,
          orderedList: false,
          listItem: false,
          codeBlock: false,
          horizontalRule: false,
          dropcursor: false,
          gapcursor: false,
          link: { openOnClick: false, HTMLAttributes: { rel: null, target: null }, protocols: ['lampbible'] },
        }),
        Extension.create({
          name: 'notePopoverKeys',
          addKeyboardShortcuts() {
            return {
              // A note's lines are lines, not paragraphs.
              Enter: () => this.editor.commands.setHardBreak(),
              // Closed after the key is handled, not while its editor is
              // still handling it.
              Escape: () => { setTimeout(() => close(true)); return true },
              'Mod-Enter': () => { setTimeout(() => close(true)); return true },
            }
          },
        }),
      ],
      content: notePanelContent(span),
      editorProps: { attributes: { 'aria-label': `Note ${shown}`, spellcheck: 'true' } },
      onUpdate: ({ editor: note }) => writeNoteContent(shown, noteFromPanel(note.state.doc, shown)),
    })
    placeNotePopover(view, panel, markerPos)
    notePopover.noteEditor.commands.focus('end')
  } else {
    // Said in the heading, so the difference reads as meant.
    title.textContent = `Note ${shown} · Markdown`
    const field = document.createElement('textarea')
    field.className = 'note-popover-text'
    field.value = noteMarkdown(editor, found.node, shown) ?? ''
    field.spellcheck = true
    panel.append(field)
    fitNotePopover(field)
    placeNotePopover(view, panel, markerPos)
    field.addEventListener('input', () => {
      writeNote(shown, field.value)
      fitNotePopover(field)
    })
    field.addEventListener('keydown', event => {
      if (event.key === 'Escape' || (event.key === 'Enter' && event.metaKey)) {
        event.preventDefault()
        close(true)
      }
    })
    field.focus()
    field.setSelectionRange(field.value.length, field.value.length)
  }

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
  document.addEventListener('mousedown', closeNotePopoverOutside, true)
}

// A note's lines as the panel's editor holds them: one paragraph, its lines
// apart by line breaks, the later ones without the indent the page sets
// them in by.
function notePanelContent(span) {
  const content = []
  span.lines.forEach((line, index) => {
    if (index > 0) content.push({ type: 'hardBreak' })
    const nodes = line.toJSON() ?? []
    if (index > 0 && nodes[0]?.type === 'text') {
      const text = nodes[0].text.replace(/^\s+/, '')
      if (text) nodes[0] = { ...nodes[0], text }
      else nodes.shift()
    }
    content.push(...nodes)
  })
  return { type: 'doc', content: [{ type: 'paragraph', content }] }
}

// The panel's note as the page shows it: its number, its first line, and
// each later line on a line of its own, set in.
function noteFromPanel(doc, shown) {
  const lines = [[]]
  doc.forEach((block, offset, index) => {
    if (index > 0) lines.push([])
    block.forEach(node => {
      if (node.type.name === 'hardBreak') lines.push([])
      else lines[lines.length - 1].push(editor.schema.nodeFromJSON(node.toJSON()))
    })
  })
  const nodes = [editor.schema.text(`[${shown}] `), ...lines[0]]
  for (const line of lines.slice(1)) {
    nodes.push(editor.schema.nodes.hardBreak.create(), editor.schema.text(CONTINUATION_INDENT), ...line)
  }
  return Fragment.from(nodes)
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
  writeNoteContent(shown, noteContent(editor, shown, markdown))
}

// Puts `content` in place of the note's lines in the document.
function writeNoteContent(shown, content) {
  const found = noteBlock(editor.state.doc, shown)
  const span = found && noteSpan(found.node, shown)
  if (!span) return
  const from = found.pos + 1 + span.from
  const to = found.pos + 1 + span.to
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
  const { panel, markerPos, noteEditor } = notePopover
  notePopover = null
  noteEditor?.destroy()
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

// Scrolls the caret's line to the middle of what can be seen of the page:
// the visual viewport, which a phone's keyboard shortens, rather than the
// page's whole height, half of which the keyboard can be covering. Without
// a keyboard the two are the same, and the line is centred as before. The
// line, not its block, since a block of notes can be taller than the page.
// A page its host lays out and scrolls doesn't scroll itself: there the host
// has the caret's reports to follow (setReportsHeight).
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
  window.scrollBy({ top: coords.top - (top + height / 2), behavior: 'smooth' })
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

// ---- Bare addresses ----

// The web and email addresses written out in the text, drawn as links to tap
// while reading: a mark on the screen only, so what's saved is the Markdown
// as typed, which reads them as words (linkify off). What isn't the writer's
// plain words (a link they made, code, a footnote's reference) is hidden from
// the finder, so an address that runs into it is left alone (bare-links.js).
const bareLinksKey = new PluginKey('bareLinks')

function bareLinkDecorations(doc) {
  const decorations = []
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true
    if (node.type.spec.code) return false
    let text = ''
    node.forEach(child => {
      // A line break ends a word, as a space does; anything else not plain
      // words is hidden, and holds its place.
      const plain = child.isText && !child.marks.some(mark => mark.type.name === 'link' || mark.type.name === 'code')
      if (child.type.name === 'hardBreak') text += '\n'
      else text += plain ? child.text : '\uFFFC'.repeat(child.isText ? child.text.length : child.nodeSize)
    })
    for (const address of findBareAddresses(text)) {
      // A link as the page's own are, to the eye, VoiceOver and the
      // keyboard, its tap taken by the page's click handler.
      decorations.push(Decoration.inline(pos + 1 + address.start, pos + 1 + address.end, {
        nodeName: 'a',
        href: address.href,
        class: 'bare-link',
      }))
    }
    return false
  })
  return DecorationSet.create(doc, decorations)
}

// Found once per document read, and not while it's written in: every
// keystroke makes a new document, and none of them is drawn with links.
const bareLinksFound = new WeakMap()

const BareLinks = Extension.create({
  name: 'bareLinks',
  addProseMirrorPlugins() {
    const editor = this.editor
    return [new Plugin({
      key: bareLinksKey,
      props: {
        // Only on a page that isn't being written in: while editing (the
        // writing's Edit, or a note) a tap puts the caret, and an address is
        // its words.
        decorations: state => {
          if (editor.isEditable) return DecorationSet.empty
          let found = bareLinksFound.get(state.doc)
          if (!found) {
            found = bareLinkDecorations(state.doc)
            bareLinksFound.set(state.doc, found)
          }
          return found
        },
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

// ---- Review marks (see review-marks.js) ----

const reviewKey = new PluginKey('reviewMarks')
// Whether the host has marks for the document shown, placed or not.
let reviewMarksShown = false

// The spans a transaction wrote, where they are in the document it made: what
// the writer typed, which is theirs and not the assistant's.
function writtenSpans(tr) {
  const spans = []
  const maps = tr.mapping.maps
  maps.forEach((map, index) => {
    map.forEach((_oldStart, _oldEnd, newStart, newEnd) => {
      let from = newStart
      let to = newEnd
      for (let later = index + 1; later < maps.length; later++) {
        from = maps[later].map(from, 1)
        to = maps[later].map(to, -1)
      }
      if (to >= from) spans.push([from, to])
    })
  })
  return spans
}

// `current`, if given, is the mark a step through them landed on
// (goToReviewMark), drawn more strongly: the selection it makes isn't drawn
// while the editor is unfocused, and focusing it would raise the keyboard.
function reviewDecorations(doc, ranges, current = null) {
  if (ranges.length === 0) return DecorationSet.empty
  return DecorationSet.create(doc, reviewDecorationList(doc, ranges, current))
}

// The decorations for `ranges`, or, with `region`, for the textblocks
// within it alone: what an edit redraws (see the plugin's apply), the rest
// of the page's marks being moved with the edit rather than drawn again.
function reviewDecorationList(doc, ranges, current = null, region = null) {
  const decorations = []
  // Drawn as the writer reads them, not as they are kept. A writing the
  // assistant has worked over many times holds a mark for every word each
  // turn changed, and drawn one by one they broke a marked paragraph into
  // dozens of washes with a gap at every space, and put a bar for every
  // turn that took words out at the same place. So within a block, washes
  // with only space or punctuation between them are drawn as one, as the
  // count reads them; a place words were taken out is drawn once, and not
  // at all where a wash already reaches it. Each mark is kept as it was,
  // for its clear, its restore and Next Change.
  const sameBlock = (a, b) => {
    const $a = doc.resolve(a)
    return $a.parent.isTextblock && $a.parent === doc.resolve(b).parent
  }
  const nothingBetween = (a, b) => a >= b || (sameBlock(a, b) && !/[\p{L}\p{N}]/u.test(doc.textBetween(a, b, '\n', '\uFFFC')))
  const washes = []
  for (const range of ranges.filter(r => r.to > r.from).sort((a, b) => a.from - b.from || a.to - b.to)) {
    const last = washes[washes.length - 1]
    if (last && (range.from <= last.to || nothingBetween(last.to, range.from))) last.to = Math.max(last.to, range.to)
    else washes.push({ from: range.from, to: range.to })
  }
  for (const wash of washes) {
    // A block with no text of its own (a rule, an image, an audio block):
    // the block itself, since there are no words to wash. Each one the
    // wash holds whole: a change that put in two rules is one wash, and
    // drawn inline it reaches no text and shows nothing.
    let leaves = 0
    doc.nodesBetween(wash.from, wash.to, (node, pos) => {
      if (!(node.isBlock && node.isLeaf)) return true
      if (pos >= wash.from && pos + node.nodeSize <= wash.to) {
        decorations.push(Decoration.node(pos, pos + node.nodeSize, { class: 'review-mark-block' }))
        leaves += node.nodeSize
      }
      return false
    })
    if (leaves < wash.to - wash.from) {
      decorations.push(Decoration.inline(wash.from, wash.to, { class: 'review-mark' }))
    }
  }
  // The mark a step landed on, more strongly, over its wash.
  if (current && current.to > current.from) {
    decorations.push(Decoration.inline(current.from, current.to, { class: 'review-mark review-current' }))
  }
  const points = new Set()
  for (const range of ranges) {
    if (range.from !== range.to || points.has(range.from)) continue
    const reached = washes.some(wash => (wash.from <= range.from && range.from <= wash.to)
      || (range.from < wash.from && nothingBetween(range.from, wash.from))
      || (wash.to < range.from && nothingBetween(wash.to, range.from)))
    const isCurrent = current !== null && current.from === range.from && current.to === range.to
    if (reached && !isCurrent) continue
    points.add(range.from)
    decorations.push(Decoration.widget(range.from, () => {
      const point = document.createElement('span')
      point.className = isCurrent ? 'review-point review-current' : 'review-point'
      point.setAttribute('aria-hidden', 'true')
      return point
    }, { side: 0, ignoreSelection: true, key: isCurrent ? 'review-point-current' : 'review-point' }))
  }
  // A clear button beside each block with something in it still to read,
  // and beside it a restore button where the block holds wording that can
  // be put back.
  const blocks = region ? textblocksBetween(doc, region.from, region.to) : textblocks(doc)
  const restorable = restorableByBlock(ranges, blocks)
  blocks.forEach(({ start, end }, index) => {
    if (!ranges.some(range => range.to >= start && range.from <= end)) return
    decorations.push(Decoration.widget(start, () => reviewClearButton(), {
      // Keyed by what it is, not where: every clear is the same button,
      // finding its block when pressed, so one carried through an edit
      // is the one a redraw there would make.
      side: -1, ignoreSelection: true, key: 'review-clear',
      // Everything the button hears is the button's. Return or Space on it
      // focused would otherwise reach the editor's keymap first, which
      // splits the block and stops the press, so the text changed and the
      // mark stayed.
      stopEvent: () => true,
    }))
    if (restorable[index].length === 0) return
    decorations.push(Decoration.widget(start, () => reviewRestoreButton(), {
      side: -1, ignoreSelection: true, key: 'review-restore',
      stopEvent: () => true,
    }))
  })
  return decorations
}

// The textblocks between two positions, as textblocks gives them.
function textblocksBetween(doc, from, to) {
  const blocks = []
  doc.nodesBetween(from, to, (node, pos) => {
    if (node.isBlock && node.isLeaf) {
      blocks.push({ start: pos, end: pos + node.nodeSize })
      return false
    }
    if (!node.isTextblock) return true
    blocks.push({ start: pos + 1, end: pos + node.nodeSize - 1 })
    return false
  })
  return blocks
}

// The part of the document an edit changed, in the document after it,
// widened to whole textblocks and to the full extent of any marks reaching
// into it, so what is drawn again there is drawn whole. Null for no change.
function editedRegion(tr, ranges) {
  const maps = tr.mapping.maps
  let from = Infinity
  let to = -Infinity
  maps.forEach((map, index) => {
    map.forEach((oldStart, oldEnd, newStart, newEnd) => {
      let a = newStart
      let b = newEnd
      for (let later = index + 1; later < maps.length; later++) {
        a = maps[later].map(a, -1)
        b = maps[later].map(b, 1)
      }
      from = Math.min(from, a)
      to = Math.max(to, b)
    })
  })
  if (from === Infinity) return null
  const doc = tr.doc
  const widen = () => {
    const $from = doc.resolve(Math.max(0, Math.min(from, doc.content.size)))
    const $to = doc.resolve(Math.max(0, Math.min(to, doc.content.size)))
    from = $from.depth > 0 ? $from.before(1) : 0
    to = $to.depth > 0 ? $to.after(1) : doc.content.size
  }
  widen()
  let grown = true
  while (grown) {
    grown = false
    for (const range of ranges) {
      if (range.to < from || range.from > to) continue
      if (range.from < from) { from = range.from; grown = true }
      if (range.to > to) { to = range.to; grown = true }
      // A mark on the region's edge reaches the block on the other side:
      // a rule ending where the region starts, whose buttons it may give,
      // and whose restore is its own when it is the first block the mark
      // touches. Drawn again too, so the buttons fall as a full redraw
      // would put them.
      if (range.from === from && from > 0) { from -= 1; grown = true }
      if (range.from === range.to && range.from === to && to < doc.content.size) { to += 1; grown = true }
    }
    // A block with no text starting where the region ends keeps its
    // buttons at its own start, the region's end, where they are taken
    // away with the region's: so it is drawn again too, whatever of it
    // is marked.
    const after = to < doc.content.size ? doc.nodeAt(to) : null
    if (after && after.isBlock && after.isLeaf) { to += after.nodeSize; grown = true }
    if (grown) widen()
  }
  return { from, to }
}

function reviewClearButton() {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'review-clear'
  button.contentEditable = 'false'
  button.title = 'Mark as reviewed'
  button.setAttribute('aria-label', 'Mark this paragraph as reviewed')
  // Pressed rather than clicked, so the caret does not move into the block
  // first, and the block is found again at press time: the widget's own
  // positions are only as good as the last redraw. On the pointer's first
  // event: on a phone a tap's mousedown comes after its touches, by which
  // time the caret is in the block and the keyboard on its way up.
  const clear = event => {
    event.preventDefault()
    event.stopPropagation()
    const doc = editor.state.doc
    const pos = editor.view.posAtDOM(button, 0)
    const $pos = doc.resolve(Math.min(pos, doc.content.size))
    let from
    let to
    if ($pos.parent.isTextblock) {
      from = $pos.start()
      to = $pos.end()
    } else {
      // A block with no text (a rule, a picture): the one the button
      // stands before, as it is now. Not where it was when the button was
      // drawn: typing above it moves it and keeps the button, and the old
      // place is someone else's words.
      const node = doc.nodeAt(pos)
      if (!node || !node.isBlock || !node.isLeaf) return
      from = pos
      to = pos + node.nodeSize
    }
    // With the page's own text beside it, written as every edit is reported
    // (getMarkdownContent), for a host whose copy is a moment behind.
    postToSwift('reviewClear', { markdown: markdownMarking(from, to), plain: getMarkdownContent() })
  }
  pressedOnce(button, clear)
  return button
}

// `act` on a press of `button`, once. A pointer acts on its first event,
// pointerdown, so the caret does not move into the block first, and its own
// click after it, which counts the clicks (1 or more), is passed over. Any
// other click acts: VoiceOver's and Full Keyboard Access's, which count 0,
// and an accessibility press, which can count 1 like a mouse's but has no
// pointerdown before it.
function pressedOnce(button, act) {
  let byPointer = false
  button.addEventListener('pointerdown', event => {
    byPointer = true
    act(event)
  })
  button.addEventListener('click', event => {
    const pointersOwn = byPointer && event.detail > 0
    byPointer = false
    if (pointersOwn) {
      event.preventDefault()
      return
    }
    act(event)
  })
}

// Where each textblock's text starts and ends.
function textblocks(doc) {
  const blocks = []
  doc.descendants((node, pos) => {
    // A block with no text (a rule, an image) is a block a mark can be on,
    // with a clear beside it too: the whole of it.
    if (node.isBlock && node.isLeaf) {
      blocks.push({ start: pos, end: pos + node.nodeSize })
      return false
    }
    if (!node.isTextblock) return true
    blocks.push({ start: pos + 1, end: pos + node.nodeSize - 1 })
    return false
  })
  return blocks
}

// Puts back what the assistant replaced in a block, shown first: what stands
// now and what would stand instead, both, since a writer about to press it
// is comparing, and where the assistant only took words out there is
// nothing marked to look at. Offered in editing only, where the change is
// saved. The page sends the passage back as a clear does, and the host,
// which keeps the old wording, works out the text and hands it to
// `restoreWording`, so the page makes the edit itself and it undoes like
// any other.
function reviewRestoreButton() {
  const button = document.createElement('button')
  button.type = 'button'
  button.className = 'review-restore'
  button.contentEditable = 'false'
  button.title = 'Restore Original Wording'
  button.setAttribute('aria-label', 'Restore Original Wording')
  // On the pointer's first event, as the clear button is, so the caret
  // stays where it was and the keyboard down. What the block offers is read
  // at press time, from the marks as they stand: the widget is kept across
  // redraws that leave it where it was.
  const open = event => {
    event.preventDefault()
    event.stopPropagation()
    if (reviewPopover?.button === button) {
      // A tap can come as more than one press; only a later one closes.
      if (performance.now() - reviewPopover.openedAt > 400) closeReviewPopover()
      return
    }
    const pos = editor.view.posAtDOM(button, 0)
    const { ranges } = reviewKey.getState(editor.state)
    const blocks = textblocks(editor.state.doc)
    const index = blocks.findIndex(block => pos >= block.start - 1 && pos <= block.end)
    if (index < 0) return
    const seen = new Set()
    const changes = restorableByBlock(ranges, blocks)[index]
      .map(at => ranges[at].change)
      .filter(change => !seen.has(change.id) && seen.add(change.id))
    if (changes.length > 0) openReviewPopover(button, changes)
  }
  pressedOnce(button, open)
  return button
}

// The restore preview open by its button, if one is: { panel, button }.
let reviewPopover = null

// What stands and what would come back for each change the block offers,
// each with its button, or why it can't be put back. A change is sent back
// by its id, which names the marks it puts back, so the host restores those
// and nothing beside them.
function openReviewPopover(button, changes) {
  closeReviewPopover()
  const panel = document.createElement('div')
  panel.className = 'review-popover'
  panel.setAttribute('role', 'dialog')
  panel.setAttribute('aria-label', 'Restore Original Wording')
  for (const change of changes) {
    const item = document.createElement('div')
    item.className = 'review-popover-item'
    if (change.reason) {
      if (typeof change.now === 'string') {
        item.append(reviewPopoverLabel('Now'), reviewPreview(change.now, 'Nothing: the assistant took words out here', true))
      }
      const why = document.createElement('div')
      why.className = 'review-popover-reason'
      why.textContent = 'Can’t be put back: you’ve edited this since'
      item.append(why)
      panel.append(item)
      continue
    }
    item.append(
      reviewPopoverLabel('Now'),
      reviewPreview(change.now, 'Nothing: the assistant took words out here', true),
      reviewPopoverLabel('Original'),
      reviewPreview(change.before, 'Nothing: the assistant added these words', false),
    )
    const restore = document.createElement('button')
    restore.type = 'button'
    restore.className = 'review-popover-restore'
    restore.textContent = 'Restore Original Wording'
    // Pressed without taking focus, so the caret and keyboard stay put.
    restore.addEventListener('pointerdown', event => event.preventDefault())
    restore.addEventListener('click', event => {
      event.preventDefault()
      closeReviewPopover()
      requestRestore(change)
    })
    item.append(restore)
    panel.append(item)
  }
  document.body.appendChild(panel)
  reviewPopover = { panel, button, openedAt: performance.now() }
  placeReviewPopover(button, panel)
  document.addEventListener('pointerdown', closeReviewPopoverOutside, true)
  document.addEventListener('keydown', closeReviewPopoverOnEscape, true)
}

function reviewPopoverLabel(text) {
  const label = document.createElement('div')
  label.className = 'review-popover-label'
  label.textContent = text
  return label
}

// Markdown shown as the page shows it, its emphasis drawn, or `empty` said
// where there is none.
function reviewPreview(markdown, empty, marked) {
  const holder = document.createElement('div')
  holder.className = 'review-popover-text' + (marked ? ' is-marked' : '')
  if (!markdown || !markdown.trim()) {
    holder.classList.add('is-empty')
    holder.textContent = empty
    return holder
  }
  try {
    const html = editor.storage.markdown.parser.parse(resolveForEditor(markdown.trim()))
    const doc = createDocument(html, editor.schema, editor.options.parseOptions)
    holder.append(DOMSerializer.fromSchema(editor.schema).serializeFragment(doc.content))
    // Shown, not followed: outside the editor nothing would catch a tap on
    // one, and the page would go to it.
    for (const link of holder.querySelectorAll('a[href]')) link.removeAttribute('href')
  } catch (e) {
    holder.textContent = markdown.trim()
  }
  return holder
}

// Under the button, kept inside the page's width and what can be seen of
// it: on a phone the keyboard covers the bottom of the window, which only
// the visual viewport leaves out (as revealCaret reckons it), and a button
// under it couldn't be pressed. Where there's no room below, the page is
// brought up until there is, as far as keeps the button in view: above it,
// the host's own header can lie over the page. Only what still doesn't fit
// is laid over the words.
function placeReviewPopover(button, panel) {
  const visible = window.visualViewport
  const visibleTop = visible ? visible.offsetTop : 0
  const visibleBottom = visibleTop + (visible ? visible.height : window.innerHeight)
  panel.style.maxHeight = `${Math.max(120, visibleBottom - visibleTop - 16)}px`
  const width = panel.offsetWidth
  const height = panel.offsetHeight
  let at = button.getBoundingClientRect()
  const short = at.bottom + 6 + height - (visibleBottom - 8)
  if (short > 0) {
    const lift = Math.min(short, at.top - visibleTop - 8)
    if (lift > 0) {
      window.scrollBy(0, lift)
      at = button.getBoundingClientRect()
    }
  }
  const left = Math.min(Math.max(8, at.right - width), window.innerWidth - width - 8)
  let top = at.bottom + 6
  if (top + height > visibleBottom - 8) top = Math.max(visibleTop + 8, visibleBottom - height - 8)
  panel.style.left = `${left + window.scrollX}px`
  panel.style.top = `${top + window.scrollY}px`
}

function closeReviewPopoverOutside(event) {
  if (reviewPopover && !reviewPopover.panel.contains(event.target) && !reviewPopover.button.contains(event.target)) {
    closeReviewPopover()
  }
}

function closeReviewPopoverOnEscape(event) {
  if (event.key !== 'Escape' || !reviewPopover) return
  event.preventDefault()
  event.stopPropagation()
  closeReviewPopover()
}

function closeReviewPopover() {
  if (!reviewPopover) return
  reviewPopover.panel.remove()
  reviewPopover = null
  document.removeEventListener('pointerdown', closeReviewPopoverOutside, true)
  document.removeEventListener('keydown', closeReviewPopoverOnEscape, true)
}

// Asks the host to put a change back, by its id, with the page's own text
// for the host to find its marks in: not by a range, which a link round it
// would widen to take changes beside it in. Only while it's still offered.
function requestRestore(change) {
  if (!editor.isEditable) return
  const offered = reviewKey.getState(editor.state).ranges
    .some(range => range.change && range.change.id === change.id && !range.change.reason)
  if (!offered) return
  postToSwift('reviewRestore', { id: change.id, plain: getMarkdownContent() })
}

// The document's Markdown with the markers written at `from` and `to`, for
// the host to find where they fell in the Markdown it holds, written as the
// page writes the document, the markers apart: a host maps them into its
// text, or into the page's (getMarkdownContent), only then.
//
// So a marker inside a link moves to the link's edge, the whole link taken
// as one: in it, the link would be split, each piece writing its address
// again, and an autolink's text would no longer be its address, so the page
// would write `<url>` as `[url](url)`, text the host never had. Each
// marker's formatting, never a link's, is the first of a few likely ones
// with which the Markdown, less the markers, is the page's own text: how
// the serializer opens and closes `**` and `*` round a marker depends on
// everything near it, so it's tried rather than reasoned out. A caret just
// after a bold word stays inside its `**`, where the mark it clears is.
//
// And an end marker goes before any hard breaks that end its block, the
// whole run of them, even from among them: after one, a break the page
// leaves off the end of a table cell would no longer be the cell's last,
// and would be written.
// `pos`, or the first word of the note whose shown number it is inside.
function pastNoteNumber(pos) {
  const $pos = editor.state.doc.resolve(pos)
  if ($pos.parent.type.name !== 'footnoteDefinition') return pos
  const start = $pos.start()
  let lineStart = start
  $pos.parent.forEach((child, offset) => {
    if (child.type.name === 'hardBreak' && start + offset < pos) lineStart = start + offset + child.nodeSize
  })
  const shown = editor.state.doc.textBetween(lineStart, $pos.end(), '', '\uFFFC').match(/^\[[^\]\s]+\][ \t]*/)
  return shown && pos < lineStart + shown[0].length ? lineStart + shown[0].length : pos
}

function markdownMarking(from, to) {
  const link = editor.schema.marks.link
  const outside = (pos, side) => {
    if (!link) return pos
    const range = getMarkRange(editor.state.doc.resolve(pos), link)
    if (!range || range.from >= pos || range.to <= pos) return pos
    return side < 0 ? range.from : range.to
  }
  const isBreak = node => node && node.type.name === 'hardBreak'
  const trailingBreaks = pos => {
    const $pos = editor.state.doc.resolve(pos)
    if ($pos.textOffset) return pos
    const parent = $pos.parent
    for (let index = $pos.index(); index < parent.childCount; index++) {
      if (!isBreak(parent.child(index))) return pos
    }
    let at = pos
    for (let index = $pos.index() - 1; index >= 0 && isBreak(parent.child(index)); index--) {
      at -= parent.child(index).nodeSize
    }
    return at
  }
  // A caret at a link's edge (just after its label, say) takes the whole
  // link too: left where it is, with no link mark, its markers would fall
  // outside the link's Markdown, after its address, away from the label.
  if (link && from === to) {
    const range = getMarkRange(editor.state.doc.resolve(from), link)
    if (range) {
      from = range.from
      to = range.to
    }
  }
  from = outside(from, -1)
  to = Math.max(from, outside(to, 1))
  // In a footnote block, a marker inside a note's shown `[1] ` stops the
  // line being read as a note, and the note is not written back: both ends
  // go to the note's first word. A selection of nothing but the number
  // selects no word, and is no clear of the word after it.
  const selected = from < to
  const inNumber = pastNoteNumber(from) !== from
  from = pastNoteNumber(from)
  to = Math.max(from, pastNoteNumber(to))
  if ((selected && from === to) || (!selected && inNumber)) return null
  to = Math.max(from, trailingBreaks(to))
  from = Math.min(from, to)
  // The page's Markdown with the range marked in it, from the trace: where
  // each character of the document was written. A document whose writing
  // could not be traced is not cleared from the page.
  const trace = currentTrace()
  if (!trace) return null
  const blockOf = pos => editor.state.doc.resolve(pos).parent
  let range = markdownRange(trace, from, to, blockOf)
  if (!range) return null
  // Widened to a link above: its syntax too.
  const $from = editor.state.doc.resolve(from)
  const $to = editor.state.doc.resolve(to)
  if (link && from < to && getMarkRange($from, link)?.from === from) range = aroundLink(trace.text, range)
  // A whole block, from its ✓: its whole lines.
  if (from < to) {
    range = wholeLines(trace.text, range, $from.parentOffset === 0, $to.parentOffset === $to.parent.content.size)
  }
  const text = trace.text
  return text.slice(0, range.from) + MARK_START + text.slice(range.from, range.to) + MARK_END + text.slice(range.to)
}

// Where two documents differ: from `start`, to `endA` in the first and
// `endB` in the second; null where they don't. Where they share text across
// the change the ends can pass the start, and both are moved on by as much.
function differing(a, b) {
  const start = a.content.findDiffStart(b.content)
  if (start === null) return null
  let { a: endA, b: endB } = a.content.findDiffEnd(b.content)
  const overlap = start - Math.min(endA, endB)
  if (overlap > 0) {
    endA += overlap
    endB += overlap
  }
  return { start, endA, endB }
}

// How far the part `span` of `parsed` (the page's own text, parsed) stands
// from where it stands in `page`, the document the page holds, or null
// where that can't be told for certain. The page can hold what its text
// doesn't write (an empty paragraph, a trailing break), each moving what
// follows it. So the two are walked block by block in order, an empty
// paragraph only the page has passed over, the rest paired as they come:
// the same block is found whichever of several equal ones it is. The
// blocks holding the part, and the one before it where it falls between
// blocks, must each be paired with one the same in the page, in a row.
function blocksInPage(page, parsed, span) {
  const pairs = pairedBlocks(page, parsed)
  if (!pairs) return null
  const $start = parsed.resolve(span.start)
  const $end = parsed.resolve(span.endA)
  const first = $start.depth === 0 ? Math.max(0, $start.index(0) - 1) : $start.index(0)
  const through = Math.min(parsed.childCount - 1, $end.index(0))
  if (first > through) return null
  for (let at = first; at <= through; at++) {
    if (!pairs[at].same || (at > first && pairs[at].index !== pairs[at - 1].index + 1)) return null
  }
  let inPage = 0
  for (let at = 0; at < pairs[first].index; at++) inPage += page.child(at).nodeSize
  let inParsed = 0
  for (let at = 0; at < first; at++) inParsed += parsed.child(at).nodeSize
  return inPage - inParsed
}

// The page's top-level block each of `parsed`'s stands for, in order, and
// whether it's the same: an empty paragraph only the page has is passed
// over, and every other block is paired with the next, the same or not.
// Null where the two don't come out even (the page runs out first, or has
// blocks with something in them left over), which is its text writing two
// of them as one, as it does two lists an emptied paragraph stood between.
function pairedBlocks(page, parsed) {
  if (parsed.childCount === 0) return null
  const isEmpty = node => node.isTextblock && node.content.size === 0
  const pairs = []
  let index = 0
  for (let at = 0; at < parsed.childCount; at++) {
    const block = parsed.child(at)
    while (index < page.childCount && !page.child(index).eq(block) && isEmpty(page.child(index))) index++
    if (index >= page.childCount) return null
    pairs.push({ index, same: page.child(index).eq(block) })
    index++
  }
  for (; index < page.childCount; index++) if (!isEmpty(page.child(index))) return null
  return pairs
}

// Whether `page` became `made` by the change `parsed` became `wanted` by:
// the same text taken out and put in, with the same text beside it on
// either side, as far as a few words or the end of the text, which counts
// as text of its own; spaces and line breaks there are compared as one
// space, since what only the page holds (an empty paragraph, a trailing
// break) is written as them. Otherwise the page's text can differ from the
// parsed one only away from the change, and the same words changed
// somewhere else don't pass.
function sameChange(page, made, parsed, wanted) {
  const change = (a, b) => {
    let start = 0
    while (start < a.length && start < b.length && a[start] === b[start]) start++
    let end = 0
    while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] === b[b.length - 1 - end]) end++
    return { start, out: a.slice(start, a.length - end), in: b.slice(start, b.length - end), endA: a.length - end }
  }
  const reach = 24
  const spaced = text => text.replace(/\s+/g, ' ')
  const around = (text, { start, endA }) => [
    ('\u0002' + spaced(text.slice(0, start)).replace(/^ /, '')).slice(-reach),
    (spaced(text.slice(endA)).replace(/ $/, '') + '\u0003').slice(0, reach),
  ]
  const one = change(page, made)
  const other = change(parsed, wanted)
  if (one.out !== other.out || one.in !== other.in) return false
  const [left, right] = around(page, one)
  const [wantedLeft, wantedRight] = around(parsed, other)
  return left === wantedLeft && right === wantedRight
}

// Whether `from` to `to` of `doc` leaves the textblock it starts in with an
// end inside a table.
function acrossCells(doc, from, to) {
  const $from = doc.resolve(from)
  const $to = doc.resolve(to)
  if ($from.parent.isTextblock && $from.sameParent($to)) return false
  const inTable = $pos => {
    for (let depth = $pos.depth; depth > 0; depth--) {
      if ($pos.node(depth).type.spec.tableRole) return true
    }
    return false
  }
  return inTable($from) || inTable($to)
}

// A textblock's text with every other inline node as one character per
// position it takes, so an offset in it is an offset into the block.
function blockText(node) {
  let text = ''
  node.forEach(child => {
    text += child.isText ? child.text : '\ufffc'.repeat(child.nodeSize)
  })
  return text
}

// Where a change inside one paragraph stands in the page, found by its
// words, for when the blocks round it don't come back from the page's own
// text as the page holds them (a quotation of several paragraphs is written
// as one). Looked for only inside the page's block paired with the one
// holding it (pairedBlocks), which must be the same kind with the same
// words, spaces and breaks apart. So each place in it is named by how many
// of those words' letters come before it, the same in both however the
// paragraphs and breaks fall: of the places the words changed stand, with
// as many beside them as tell them apart, the one taken is the one with as
// many letters before it as the change has. Null where the change isn't
// inside one paragraph in both, or that block can't be told, or no one
// place is that one.
function wordsInPage(page, before, after, span) {
  const $start = before.resolve(span.start)
  const $end = before.resolve(span.endA)
  const $newStart = after.resolve(span.start)
  const $newEnd = after.resolve(span.endB)
  if (!$start.parent.isTextblock || !$start.sameParent($end)) return null
  if (!$newStart.parent.isTextblock || !$newStart.sameParent($newEnd)) return null
  const pairs = pairedBlocks(page, before)
  const holding = $start.index(0)
  if (!pairs || !pairs[holding]) return null
  const inPage = page.child(pairs[holding].index)
  const bare = node => node.textBetween(0, node.content.size, '', '').replace(/\s+/g, '')
  if (inPage.type !== before.child(holding).type || bare(inPage) !== bare(before.child(holding))) return null
  // Each textblock in a top-level block, with its text and how many letters
  // (not spaces, nor what isn't text) come before it there.
  const isLetter = c => c !== '\ufffc' && !/\s/.test(c)
  const letters = (text, upTo) => {
    let count = 0
    for (let at = 0; at < upTo; at++) if (isLetter(text[at])) count++
    return count
  }
  const textblocksOf = (block, offset) => {
    const list = []
    let count = 0
    const visit = (node, pos) => {
      if (!node.isTextblock) return true
      const text = blockText(node)
      list.push({ start: pos + 1, text, before: count })
      count += letters(text, text.length)
      return false
    }
    if (block.isTextblock) visit(block, offset)
    else block.descendants((node, pos) => visit(node, offset + 1 + pos))
    return list
  }
  const offsetOf = (doc, index) => {
    let offset = 0
    for (let at = 0; at < index; at++) offset += doc.child(at).nodeSize
    return offset
  }
  const own = textblocksOf(before.child(holding), offsetOf(before, holding))
    .find(block => block.start === $start.start())
  if (!own) return null
  const text = own.text
  const from = $start.parentOffset
  const to = $end.parentOffset
  const wanted = own.before + letters(text, from)
  const words = text.slice(from, to)
  const blocks = textblocksOf(inPage, offsetOf(page, pairs[holding].index))
  for (const reach of [40, 20, 8, 3, 0]) {
    const left = text.slice(Math.max(0, from - reach), from)
    const needle = left + words + text.slice(to, to + reach)
    if (!needle) continue
    const found = []
    for (const block of blocks) {
      for (let at = block.text.indexOf(needle); at >= 0; at = block.text.indexOf(needle, at + 1)) {
        const place = at + left.length
        if (block.before + letters(block.text, place) === wanted) found.push(block.start + place)
      }
    }
    if (found.length > 1) return null
    if (found.length === 1) {
      return {
        from: found[0],
        to: found[0] + words.length,
        slice: $newStart.parent.slice($newStart.parentOffset, $newEnd.parentOffset),
      }
    }
  }
  return null
}

// Where each character of the document is written in the page's Markdown
// (review-trace.js), kept until the document changes: built when marks are
// drawn or cleared, never on typing. Null where the writing could not be
// traced, which the marker paths answer for instead.
let traceKept = null
// How many times the trace has been built, for the checks that hold typing
// to building none (webkit/check.swift, reviewMarksCost).
let traceBuilds = 0
function currentTrace() {
  const doc = editor.state.doc
  if (traceKept && traceKept.doc === doc) return traceKept.trace
  traceBuilds++
  let trace = null
  try {
    trace = traceDocument(editor, doc, tidyMarkdown, writtenDocument)
  } catch (e) {
    trace = null
  }
  traceKept = { doc, trace }
  return trace
}

// What a copy puts on the clipboard as plain text: the words of what is
// selected and nothing else, a block to a paragraph and a line break to a
// line. TipTap's own reads everything between the selection's two ends,
// which for cells chosen in a table takes the cells between them too.
const PlainTextCopy = Extension.create({
  name: 'plainTextCopy',
  // Ahead of TipTap's, which would otherwise answer first.
  priority: 1000,
  addProseMirrorPlugins() {
    return [new Plugin({
      props: {
        clipboardTextSerializer: slice => slice.content.textBetween(
          0, slice.content.size, '\n\n', leaf => leaf.type.name === 'hardBreak' ? '\n' : ''
        ),
      },
    })]
  },
})

const ReviewMarks = Extension.create({
  name: 'reviewMarks',
  addProseMirrorPlugins() {
    return [new Plugin({
      key: reviewKey,
      state: {
        init: () => ({ ranges: [], decorations: DecorationSet.empty, current: null }),
        apply(tr, old) {
          const meta = tr.getMeta(reviewKey)
          if (meta?.ranges) return { ranges: meta.ranges, decorations: reviewDecorations(tr.doc, meta.ranges), current: null }
          if (meta?.current) {
            return { ranges: old.ranges, decorations: reviewDecorations(tr.doc, old.ranges, meta.current), current: meta.current }
          }
          // The step's mark is drawn until the writer moves on from it.
          if (old.current && (tr.docChanged || tr.selectionSet)) {
            old = { ranges: old.ranges, decorations: reviewDecorations(tr.doc, old.ranges), current: null }
            if (!tr.docChanged) return old
          }
          if (!tr.docChanged || old.ranges.length === 0) return old
          // Carried through the writer's edit: the marks move with the words,
          // and what was typed into them is left out.
          // What a mark can put back goes with it until the writer types into
          // or beside it.
          const mapped = old.ranges.flatMap(range => {
            if (range.from === range.to) {
              const result = tr.mapping.mapResult(range.from, -1)
              return result.deleted ? [] : [{ ...range, from: result.pos, to: result.pos }]
            }
            const from = tr.mapping.map(range.from, 1)
            const to = tr.mapping.map(range.to, -1)
            return to > from ? [{ ...range, from, to }] : []
          })
          // A deletion's span is empty: no words of the writer's to take out,
          // but the words left are no longer the assistant's as marked.
          const written = writtenSpans(tr)
          const typed = written.filter(([from, to]) => to > from)
          const ranges = withoutSpans(withoutTypedChanges(mapped, written), typed)
          // Only what the edit touched is drawn again; the rest of the
          // page's marks move with it. Drawing every mark of a long writing
          // on every keystroke made typing in it lag.
          const region = editedRegion(tr, ranges)
          if (!region) return { ranges, decorations: reviewDecorations(tr.doc, ranges), current: null }
          let decorations = old.decorations.map(tr.mapping, tr.doc)
          decorations = decorations.remove(decorations.find(region.from, region.to))
          const inside = ranges.filter(range => range.to >= region.from && range.from <= region.to)
          decorations = decorations.add(tr.doc, reviewDecorationList(tr.doc, inside, null, region))
          return { ranges, decorations, current: null }
        },
      },
      props: {
        decorations: state => reviewKey.getState(state).decorations,
      },
    })]
  },
})

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
        // Copied as the words the reader sees (text/plain), not as Markdown;
        // text/html still carries the formatting for apps that take it.
        transformCopiedText: false,
        tightLists: true,
        indentation: {
          style: 'space',
          size: 4,
        },
      }),
      LineHardBreak,
      VerseReferences,
      BareLinks,
      Search,
      ReviewMarks,
      PlainTextCopy,
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

    // An undo or redo can take the text back to words a change was made
    // in, which typing had made the page stop offering to put back: the
    // host, which can tell, is asked for the marks again.
    // Asked though no mark is left on the page: one undone back in comes
    // with no mark, which only the host can give it again.
    // A restore preview open while the text changes may no longer say what
    // can be put back: it's closed, to be opened again as it now stands.
    onTransaction({ transaction }) {
      if (transaction.docChanged && reviewPopover) closeReviewPopover()
      if (!transaction.docChanged || !transaction.getMeta('history$') || !reviewMarksShown) return
      postToSwift('reviewMarksStale', {})
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
    // Caught, and said: thrown here, the edit was never reported, nor any
    // after it while the writing kept the shape that threw, and the host
    // went on holding the text from before.
    let md
    try {
      md = getMarkdownContent()
    } catch (error) {
      postToSwift('contentError', { message: String(error && error.message || error).slice(0, 300) })
      return
    }
    currentMarkdown = md
    postToSwift('contentChanged', { markdown: md })
  }, 300)
}

// prosemirror-markdown 1.13.3's isMarkAhead steps twice over a hard break,
// so after one that ends a paragraph it reads past the paragraph's end and
// throws: a line of bold, a line break, a line, and a line break at the end
// (Shift-Return there) could not be written, and no edit was saved while
// the paragraph stayed so. The same search, stepping once.
// And its atBlank asks a regular expression of the whole output written so
// far each time it is called, which is often: writing grows with the square
// of the writing's length, about 75 ms for a 56 KB writing, run 300 ms
// after the writer stops typing. The same question, of the last character.
MarkdownSerializerState.prototype.atBlank = function () {
  const length = this.out.length
  return length === 0 || this.out.charCodeAt(length - 1) === 10
}

// And its text, before a link's `[`, asks a regular expression whether the
// whole output so far ends in an unescaped `!`, so every link cost a pass
// over everything before it. The same question, of the last two characters.
const endsInBang = out => {
  const length = out.length
  return length > 0 && out.charCodeAt(length - 1) === 33 && (length === 1 || out.charCodeAt(length - 2) !== 92)
}
MarkdownSerializerState.prototype.text = function (text, escape = true) {
  const lines = text.split('\n')
  for (let i = 0; i < lines.length; i++) {
    this.write()
    // Escape exclamation marks in front of links
    if (!escape && lines[i][0] === '[' && endsInBang(this.out)) {
      this.out = this.out.slice(0, this.out.length - 1) + '\\!'
    }
    this.out += escape ? this.esc(lines[i], this.atBlockStart) : lines[i]
    if (i !== lines.length - 1) this.out += '\n'
  }
}

MarkdownSerializerState.prototype.isMarkAhead = function (parent, index, mark) {
  for (; index < parent.childCount; index++) {
    const next = parent.child(index)
    if (next.type.name !== this.options.hardBreakNodeName) return mark.isInSet(next.marks)
  }
  return false
}

function getMarkdownContent() {
  if (currentMode === 'markdown') {
    return markdownTextarea.value
  }
  // Extensions handle markdown serialization with media/id format directly
  return tidyMarkdown(writtenDocument())
}

// The writer's Markdown for the document as it stands, kept with the
// document it was written for: review marks' trace checks itself against
// it (traceDocument), and the page writes it after every pause in typing
// anyway, so a clear that follows an edit need not write it again.
let lastWriting = null
function writtenDocument() {
  const doc = editor.state.doc
  if (lastWriting && lastWriting.doc === doc) return lastWriting.raw
  const raw = editor.storage.markdown.getMarkdown()
  lastWriting = { doc, raw }
  return raw
}

// The serializer's Markdown as the host is given it, by every path that
// gives it, so a copy with review markers in it differs from the document's
// own by the markers alone.
function tidyMarkdown(serialized) {
  // What it takes out, and the map of what stays that review marks are
  // placed by, are one function's: review-trace.js, tidyKeeping.
  return tidyKeeping(serialized).text
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
    closeReviewPopover()
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

  // The writing assistant's changes the writer has not yet read, as the
  // document's Markdown with a marker at each edge (review-marks.js), or
  // null for none. Says whether they could be placed. A Markdown that is
  // not this document's changes nothing: the marks shown stay, carried
  // through the writer's edits as before, since a host whose copy of the
  // text is a moment behind the page's would otherwise wipe them on every
  // try. Kept through the writer's edits until the next call.
  //
  // `changes`, beside them, says for each marked range in the order the
  // markers stand what restoring it would put back: `{ id, now, before }`,
  // the words as Markdown and an id the host knows its marks by; or
  // `{ id, now, reason: 'edited' }` where it can't be, for something the
  // writer did; or null, saying nothing. Missing entries are null. Only the
  // words cross over, never a position. A marker with its place written
  // after it is paired with the change at that place, since the host may
  // have moved it out of syntax the parser drops, out of order.
  //
  // Answers true when every mark is drawn, false when the page holds another
  // text, and `{ drawn, unshown }` when it holds this one and not every mark
  // could be drawn — `drawn` may be 0, which is not the same as false: then
  // the host must still say that marks are missing, since a writer reading
  // what is drawn would otherwise take the rest for unchanged.
  // How many times the review marks' trace has been built: none while
  // typing, one a draw or clear of a changed document. For the checks.
  reviewTraceBuilds() {
    return traceBuilds
  },

  // What typing's partial redraw holds that drawing the same marks whole
  // would not, and the reverse, or null where they agree. For the checks.
  reviewRedrawDiffers() {
    const { ranges, decorations, current } = reviewKey.getState(editor.state)
    const doc = editor.state.doc
    const describe = set => set.find().map(d =>
      `${d.from}-${d.to}-${d.spec.key || ''}-${(d.type.attrs && d.type.attrs.class) || ''}`).sort()
    const drawn = describe(decorations)
    const whole = describe(reviewDecorations(doc, ranges, current))
    // Counted, not looked up: two of a button where a whole redraw draws
    // one is a difference.
    const count = list => list.reduce((m, d) => m.set(d, (m.get(d) || 0) + 1), new Map())
    const drawnCount = count(drawn)
    const wholeCount = count(whole)
    const extra = [...drawnCount].filter(([d, n]) => n > (wholeCount.get(d) || 0)).map(([d, n]) => `${d} x${n - (wholeCount.get(d) || 0)}`)
    const missing = [...wholeCount].filter(([d, n]) => n > (drawnCount.get(d) || 0)).map(([d, n]) => `${d} x${n - (drawnCount.get(d) || 0)}`)
    return extra.length === 0 && missing.length === 0 ? null : { extra, missing }
  },

  setReviewMarks(markedMarkdown, changes) {
    if (!editor) return false
    reviewMarksShown = Boolean(markedMarkdown)
    let placed = []
    let unshown = 0
    // Placed by where the page writes each character of its document; see
    // review-trace.js. False where the page holds another text, or its
    // writing could not be traced.
    if (markedMarkdown) {
      const byTrace = placeByTrace(markedMarkdown, currentTrace())
      if (!byTrace) return false
      placed = byTrace.ranges
      unshown = byTrace.unshown
    }
    closeReviewPopover()
    const ranges = placed.map(({ place, order, ...range }) => {
      // Paired with its change by its place, or by its own order among the
      // marks sent (placeByTrace).
      const at = place ?? order
      const change = Array.isArray(changes) && at !== undefined ? changes[at] : null
      if (!change || typeof change.id !== 'string' || typeof change.now !== 'string') return range
      if (change.reason === 'edited') return { ...range, change: { id: change.id, now: change.now, reason: 'edited' } }
      if (typeof change.before !== 'string') return range
      return { ...range, change: { id: change.id, now: change.now, before: change.before } }
    })
    editor.view.dispatch(editor.state.tr.setMeta(reviewKey, { ranges }).setMeta('addToHistory', false))
    return unshown > 0 ? { drawn: placed.length, unshown } : true
  },

  // Puts the assistant's change back, as the host worked it out from a
  // `reviewRestore`: the document becomes `markdown`, if it is still
  // `expected`, the text the press was made in. Made as one edit of the
  // part that differs, so it undoes as any edit does and the rest of the
  // page, the caret among it, stays as it was. Returns the page's Markdown
  // afterwards, which the host records the restore against, or null where
  // it was not made: typed into since, or not in editing.
  //
  // The part is found between the two texts as parsed, not between the
  // page and the new text: the page can hold what its Markdown doesn't
  // write (empty paragraphs, trailing breaks), which parsing the new text
  // would drop and a replace would take with it. It's made in the page at
  // the blocks holding it there (`blocksInPage`); where the page's own
  // blocks differ from them, nothing is made.
  restoreWording(markdown, expected) {
    if (!editor || !editor.isEditable || currentMode !== 'richtext') return null
    if (getMarkdownContent() !== expected) return null
    const parse = text => {
      const html = editor.storage.markdown.parser.parse(resolveForEditor(text))
      return createDocument(html, editor.schema, editor.options.parseOptions)
    }
    let before, after
    try {
      before = parse(expected)
      after = parse(markdown)
    } catch (e) {
      return null
    }
    // A change asked for that the page can't hold (an HTML comment, say)
    // parses to the document it has: refused, not reported as made.
    const span = differing(before, after)
    if (!span) return markdown === expected ? getMarkdownContent() : null
    // One replace can't be made across a table's cells, or into or out of
    // one: fitted there, it splits the row or takes what follows into a
    // cell. Refused rather than made wrong.
    if (acrossCells(before, span.start, span.endA) || acrossCells(after, span.start, span.endB)) return null
    const page = editor.state.doc
    let tr
    const shift = blocksInPage(page, before, span)
    if (shift !== null) {
      tr = editor.state.tr.replace(span.start + shift, span.endA + shift, after.slice(span.start, span.endB))
    } else {
      const found = wordsInPage(page, before, after, span)
      if (!found) return null
      tr = editor.state.tr.replace(found.from, found.to, found.slice)
    }
    // Made only if the page's text would change just as the host's does,
    // where it does: the same words out and in, with the same beside them.
    // Against the host's own change, and against the same change as the
    // page writes the parsed texts: either is enough, since the host may
    // spell the old wording otherwise, and writing a parsed text again can
    // tidy it otherwise round the change (a quotation's separators).
    const write = doc => tidyMarkdown(editor.storage.markdown.serializer.serialize(doc))
    const made = write(tr.doc)
    if (!sameChange(expected, made, expected, markdown) && !sameChange(expected, made, write(before), write(after))) return null
    closeReviewPopover()
    tr = closeHistory(tr)
    editor.view.dispatch(tr)
    // Its own step in the history at both ends: typing straight after it
    // undoes alone, and leaves the restore to undo after.
    editor.view.dispatch(closeHistory(editor.state.tr))
    return getMarkdownContent()
  },

  // Moves to the next change still to read after the caret, or the one
  // before it, round at either end, selecting it and bringing it into view.
  // The keyboard is not raised for it. Whether there was one.
  goToReviewMark(forward) {
    if (!editor) return false
    const { ranges } = reviewKey.getState(editor.state)
    const range = nextMark(ranges, editor.state.selection.from, forward !== false)
    if (!range) return false
    const doc = editor.state.doc
    editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(doc, range.from, range.to)))
    editor.view.dispatch(editor.state.tr.setMeta(reviewKey, { current: { from: range.from, to: range.to } }).setMeta('addToHistory', false))
    // Its own line in the middle of the view, as the caret is revealed: in a
    // paragraph taller than the view, its paragraph's middle may not be it.
    revealCaret(editor.view)
    return true
  },

  // The selection, as the document's Markdown with markers at its edges,
  // for the host to clear what of the marks it covers, with the page's own
  // text beside it as a clear sends it. A caret is both edges at once, and
  // clears the mark it stands in.
  reviewMarkdownForSelection() {
    if (!editor || currentMode !== 'richtext') return null
    const { from, to } = editor.state.selection
    const markdown = markdownMarking(from, to)
    return markdown === null ? null : { markdown, plain: getMarkdownContent() }
  },

  // The changes the selection stands in, as the page has them: their ids
  // joined (the marks they stand in), those the page no longer offers among
  // them, for the host to ask about by name; whether it touches a passage
  // the host sent no change for (`unnamed`); and the selection's Markdown
  // marked and the page's own text as reviewMarkdownForSelection gives
  // them. Not widened to a link round it, so a change beside the one
  // selected isn't taken too.
  reviewChangesForSelection() {
    if (!editor || currentMode !== 'richtext') return null
    const { from, to } = editor.state.selection
    const touches = range => {
      if (range.from === range.to) return range.from >= from && range.from <= to
      if (from === to) return from >= range.from && from <= range.to
      return range.from < to && from < range.to
    }
    const ids = []
    let unnamed = false
    for (const range of reviewKey.getState(editor.state).ranges.filter(touches)) {
      if (!range.change) {
        unnamed = true
        continue
      }
      for (const id of range.change.id.split(',')) if (!ids.includes(id)) ids.push(id)
    }
    const markdown = markdownMarking(from, to)
    if (markdown === null) return null
    return { ids: ids.join(','), unnamed, caret: from === to, markdown, plain: getMarkdownContent() }
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
    closeReviewPopover()
    reviewMarksShown = false
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
    // Nothing on the rich text is offered over the Markdown.
    closeReviewPopover()
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
    // Only on a change of mode: a host refreshing sends the same one again,
    // and a comparison being read stays open through it.
    if (mode !== currentViewMode) closeReviewPopover()
    currentViewMode = mode
    document.body.classList.remove('mode-edit', 'mode-read', 'mode-present')
    document.body.classList.add('mode-' + mode)
    const isEditable = mode === 'edit'
    // No update for it: none of the document changed, and the host would take
    // the Markdown it reported (the editor's own way of writing what it was
    // given) for an edit, and save it over what was stored.
    editor.setEditable(isEditable, false)
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
    document.body.classList.toggle('light', !isDark)
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
