// Where each character of the page's document lands in the Markdown the
// page writes for it, so review marks, which the host knows as ranges of the
// writing's Markdown, can be drawn exactly where they fall, and a clear made
// on the page sent back as a range of it.
//
// The page writes its document as Markdown on every edit. Here that writing
// is done again by a writer that records, for each character of the
// document's text, the place in the output it was written to. The Markdown
// is the page's own, so the map is exact by construction: no Markdown is
// parsed with anything in it, and no syntax can make a mark read as
// something else. Three guards hold it so: each character written must be
// the document's character at that place, the output must be the stock
// writer's byte for byte, and what the page tidies away afterwards is
// followed character by character.
//
// Only when the host's Markdown is not the page's own (the page restyles
// what it was given until the writer next types) are the two lined up, by
// `bridge`: equal stretches map exactly, and a difference holding words of
// the page's that the host's lacks means the host is behind, and nothing is
// drawn until it catches up.
//
// Built lazily, when marks are drawn or cleared, and kept until the
// document changes: typing costs nothing.

import { MarkdownSerializerState } from '@tiptap/pm/markdown'
import markdownit from 'markdown-it'
import { decodeLabels } from './footnote-numbering.js'
import { marksInMarkdown, noteDefinitions, characterMap, characterAlignment } from './review-align.js'

const md = markdownit()
function scanDelims(text, pos) {
  const state = new (md.inline.State)(text, null, null, [])
  return state.scanDelims(pos, true)
}
function shiftDelim(text, delim, start, offset) {
  const res = text.substring(0, start) + text.substring(start + delim.length)
  return res.substring(0, start + offset) + delim + res.substring(start + offset)
}
const escapeHTML = value => value?.replace(/</g, '&lt;').replace(/>/g, '&gt;')

// tiptap-markdown's writer (serialize/state.js), recording where the
// document's text goes. Its `render` and `markString` are copied here with
// the moves they make carried into the record; drift from the library is
// caught by the byte-for-byte guard in `traceDocument`.
class TracingState extends MarkdownSerializerState {
  constructor(nodes, marks, options, doc) {
    super({ ...nodes, text: (state, node) => state.docText(node.text) }, marks, options ?? {})
    this.inlines = []
    this.inTable = false
    // { pm, out, len }: the document's characters from pm written at out.
    this.runs = []
    // { pm, out, len }: an inline atom at pm, written as out..out+len.
    this.atoms = []
    // { pos, out, end }: a footnote block and the output it wrote.
    this.notes = []
    this.inline = null
    this.markCalls = []
    this.starts = new Map()
    // Blocks with no text (a rule, an image, an audio block), by where
    // each stands: written whole, they are known by their whole writing.
    this.leaves = new Map()
    doc.descendants((node, pos) => {
      if (node.isBlock && node.isLeaf) {
        const at = this.leaves.get(node)
        if (at) at.push(pos)
        else this.leaves.set(node, [pos])
        return false
      }
      if (!node.inlineContent && !node.type.spec.code) return true
      const at = this.starts.get(node)
      if (at) at.push(pos + 1)
      else this.starts.set(node, [pos + 1])
      return false
    })
  }

  // The base asks a regular expression of the whole output each time.
  atBlank() {
    const n = this.out.length
    return n === 0 || this.out.charCodeAt(n - 1) === 10
  }

  render(node, parent, index) {
    if (node.type.name === 'footnoteDefinition') {
      const pos = this.starts.get(node)?.[0]
      const out = this.out.length
      super.render(node, parent, index)
      if (pos !== undefined) this.notes.push({ node, pos: pos - 1, out, end: this.out.length })
      return
    }
    const ctx = this.inline
    const inlineChild = ctx && parent === ctx.parent
    if (node.type.spec.code && node.isBlock) return this.renderCode(node, parent, index)
    const before = this.out.length
    if (node.isBlock && node.isLeaf) {
      const pos = this.leaves.get(node)?.shift()
      super.render(node, parent, index)
      // Its writing, less the blank lines round it, stands for the block:
      // a mark on `---` is a mark on the rule.
      let from = before
      let to = this.out.length
      while (from < to && /\s/.test(this.out[from])) from++
      while (to > from && /\s/.test(this.out[to - 1])) to--
      if (pos !== undefined && to > from) this.atoms.push({ pm: pos, out: from, len: to - from, leaf: node.nodeSize })
      return
    }
    super.render(node, parent, index)
    if (inlineChild && !node.isText) {
      const offset = this.offsetOf(ctx, index)
      if (!ctx.failed && this.out.length > before) {
        this.atoms.push({ pm: ctx.start + offset, out: before, len: this.out.length - before })
      }
      ctx.cursor = offset + node.nodeSize
    }
    const top = this.inlines[this.inlines.length - 1]
    if (top?.start && top?.end) {
      let { delimiter, start, end } = top
      while (this.out.charAt(start).match(/\s/)) start++
      this.trim(delimiter, start, end)
      this.inlines.pop()
    }
  }

  // trimInline, moving what it moves.
  trim(delim, from, to) {
    let text = this.out
    const n = delim.length
    let pos = from
    while (pos < to) {
      if (scanDelims(text, pos).can_open) break
      text = shiftDelim(text, delim, pos, 1)
      pos++
    }
    if (pos > from) this.shift(from + n, pos + n, -n)
    const opened = pos
    pos = to
    while (pos > opened) {
      if (scanDelims(text, pos).can_close) break
      text = shiftDelim(text, delim, pos, -1)
      pos--
    }
    if (pos < to) this.shift(pos, to, n)
    if (pos - opened < n + 1) {
      text = text.substring(0, opened) + text.substring(pos + n)
      this.shift(pos + n, Infinity, -(pos + n - opened))
    }
    this.out = text
  }

  // What was written at [a, b) moves by d.
  shift(a, b, d) {
    const move = list => {
      let i = list.length - 1
      while (i >= 0 && list[i].out + list[i].len > a) i--
      const kept = list.splice(i + 1)
      for (const run of kept) {
        if (run.atom) {
          list.push(run.out >= a && run.out < b ? { ...run, out: run.out + d } : run)
          continue
        }
        const cuts = [0, Math.max(0, Math.min(run.len, a - run.out)), Math.max(0, Math.min(run.len, b - run.out)), run.len]
        for (let k = 0; k < 3; k++) {
          const len = cuts[k + 1] - cuts[k]
          if (len > 0) list.push({ pm: run.pm + cuts[k], out: run.out + cuts[k] + (k === 1 ? d : 0), len })
        }
      }
    }
    move(this.runs)
    this.atoms = this.atoms.map(atom => atom.out >= a && atom.out < b ? { ...atom, out: atom.out + d } : atom)
  }

  markString(mark, open, parent, index) {
    const info = this.marks[mark.type.name]
    if (info.expelEnclosingWhitespace) {
      if (open) this.inlines.push({ start: this.out.length, delimiter: info.open })
      else this.inlines.push({ ...this.inlines.pop(), end: this.out.length })
    }
    const value = super.markString(mark, open, parent, index)
    this.markCalls.push(value)
    return value
  }

  offsetOf(ctx, index) {
    if (!ctx.offsets) {
      ctx.offsets = []
      ctx.parent.forEach((_, offset) => ctx.offsets.push(offset))
    }
    return ctx.offsets[index]
  }

  renderInline(parent, fromBlockStart = true) {
    const saved = this.inline
    const start = this.starts.get(parent)?.shift()
    this.inline = start === undefined ? null : {
      parent, start, cursor: 0, firstRun: this.runs.length, firstAtom: this.atoms.length,
      text: parent.textBetween(0, parent.content.size, '', '￼'),
    }
    this.markCalls.length = 0
    try {
      super.renderInline(parent, fromBlockStart)
    } finally {
      this.inline = saved
    }
  }

  // A block whose writing could not be followed is left out of the record:
  // its marks are counted as not shown, never drawn in the wrong place.
  fail(ctx) {
    this.runs.length = ctx.firstRun
    this.atoms.length = ctx.firstAtom
    ctx.failed = true
  }

  record(pm, out) {
    const last = this.runs[this.runs.length - 1]
    if (last && last.pm + last.len === pm && last.out + last.len === out) last.len++
    else this.runs.push({ pm, out, len: 1 })
  }

  // The document's text, written escaped: each character's place.
  docText(raw) {
    const ctx = this.inline
    if (!ctx || ctx.failed) return super.text(escapeHTML(raw))
    if (ctx.text.substr(ctx.cursor, raw.length) !== raw) {
      this.fail(ctx)
      return super.text(escapeHTML(raw))
    }
    const lines = raw.split('\n')
    let pm = ctx.start + ctx.cursor
    for (let i = 0; i < lines.length; i++) {
      this.write()
      const line = lines[i]
      const escaped = this.esc(escapeHTML(line), this.atBlockStart)
      const base = this.out.length
      let j = 0
      // Most text is written as it is: one run.
      if (escaped === line) {
        if (line.length > 0) {
          const last = this.runs[this.runs.length - 1]
          if (last && last.pm + last.len === pm && last.out + last.len === base) last.len += line.length
          else this.runs.push({ pm, out: base, len: line.length })
        }
        j = line.length
      }
      for (let k = j; k < line.length && !ctx.failed; k++) {
        const c = line[k]
        if (escaped[j] === '\\' && escaped[j + 1] === c) j++
        if (c === '<' && escaped.startsWith('&lt;', j)) { this.record(pm + k, base + j); j += 4 }
        else if (c === '>' && escaped.startsWith('&gt;', j)) { this.record(pm + k, base + j); j += 4 }
        else if (escaped[j] === c || (/\s/.test(c) && escaped[j] === ' ')) { this.record(pm + k, base + j); j += 1 }
        else this.fail(ctx)
      }
      if (!ctx.failed && j !== escaped.length) this.fail(ctx)
      this.out += escaped
      pm += line.length
      if (i !== lines.length - 1) {
        if (!ctx.failed) this.record(pm, this.out.length)
        this.out += '\n'
        pm += 1
      }
      this.atBlockStart = false
    }
    ctx.cursor += raw.length
    this.markCalls.length = 0
  }

  text(text, escape = true) {
    const ctx = this.inline
    if (this.code && !escape && !ctx) return this.codeText(text)
    if (ctx && escape) return this.docText(text)
    // A code span: its text written unescaped between its two delimiters.
    const calls = this.markCalls
    const code = ctx && !ctx.failed && !escape && calls.length === 2
      && text.length > calls[0].length + calls[1].length
      && text.startsWith(calls[0]) && text.endsWith(calls[1])
    const out = this.out
    const bang = !escape && text[0] === '[' && out.length > 0 && out.charCodeAt(out.length - 1) === 33
      && (out.length === 1 || out.charCodeAt(out.length - 2) !== 92)
    const before = this.out.length
    super.text(text, escape)
    if (bang) this.shift(before - 1, before, 1)
    if (code) {
      const middle = text.slice(calls[0].length, text.length - calls[1].length)
      if (middle.includes('\n') || ctx.text.substr(ctx.cursor, middle.length) !== middle) {
        this.fail(ctx)
      } else {
        const at = this.out.length - calls[1].length - middle.length
        for (let k = 0; k < middle.length; k++) this.record(ctx.start + ctx.cursor + k, at + k)
        ctx.cursor += middle.length
      }
    }
    calls.length = 0
  }

  // A code block: its text as it is, each line after its indent.
  renderCode(node, parent, index) {
    const start = this.starts.get(node)?.shift()
    this.code = start === undefined ? null : { pm: start }
    const before = this.out.length
    this.nodes[node.type.name](this, node, parent, index)
    // An empty block has no text to place a point in: its whole writing
    // stands for the place inside it.
    if (start !== undefined && node.content.size === 0 && this.out.length > before) {
      this.atoms.push({ pm: start, out: before, len: this.out.length - before })
    }
    this.code = null
  }

  codeText(text) {
    const lines = text.split('\n')
    for (let i = 0; i < lines.length; i++) {
      this.write()
      if (lines[i].length) this.runs.push({ pm: this.code.pm, out: this.out.length, len: lines[i].length })
      this.out += lines[i]
      this.code.pm += lines[i].length + 1
      if (i !== lines.length - 1) this.out += '\n'
    }
  }
}

// The positions of `doc` in the Markdown `tidy(serialize(doc))`:
// { text, pmAt, atomAt } where pmAt[i] is the document position of the
// character written at i (-1 for syntax), and atomAt[i] the position of an
// inline atom (a footnote reference, a hard break) whose writing holds i.
// Null where the traced writing is not the stock writer's.
export function traceDocument(editor, doc, tidy, written = null) {
  const serializer = editor.storage.markdown.serializer
  const state = new TracingState(serializer.nodes, serializer.marks, { hardBreakNodeName: 'hardBreak' }, doc)
  state.renderContent(doc)
  const raw = state.out
  // The stock writer's own output for this document: the page's latest,
  // when it wrote this very document, or written now.
  if (raw !== (written ? written() : serializer.serialize(doc))) return null
  const rawPm = new Int32Array(raw.length).fill(-1)
  const rawAtom = new Int32Array(raw.length).fill(-1)
  const rawLeaf = new Int32Array(raw.length)
  for (const run of state.runs) for (let k = 0; k < run.len; k++) rawPm[run.out + k] = run.pm + k
  for (const atom of state.atoms) {
    for (let k = 0; k < atom.len; k++) {
      rawAtom[atom.out + k] = atom.pm
      if (atom.leaf) rawLeaf[atom.out + k] = atom.leaf
    }
  }
  for (const note of state.notes) traceNotes(note, raw, rawPm)

  // What tidying removes, as it removes it (tidyKeeping), so each
  // character that stays is known to be the one written there.
  const { text, kept } = tidyKeeping(raw)
  if (text !== tidy(raw)) return null
  const pmAt = new Int32Array(text.length).fill(-1)
  const atomAt = new Int32Array(text.length).fill(-1)
  const leafAt = new Int32Array(text.length)
  for (let t = 0; t < text.length; t++) {
    pmAt[t] = rawPm[kept[t]]
    atomAt[t] = rawAtom[kept[t]]
    leafAt[t] = rawLeaf[kept[t]]
  }
  return { text, pmAt, atomAt, leafAt }
}

// The page's tidying of what its writer wrote (editor.js's tidyMarkdown
// calls this), and for each character it keeps, where that character was
// in what it was given. It only ever takes characters out:
// - a quote line's trailing backslash, or two trailing spaces;
// - an empty quote line between two that have words;
// - a blank line inside a list, before another item.
export function tidyKeeping(serialized) {
  let text = serialized
  let kept = Int32Array.from({ length: text.length }, (_, i) => i)
  // Each match of `pattern` replaced by the spans `keep` gives of it.
  const keeping = (pattern, keep) => {
    let out = ''
    const map = []
    let at = 0
    for (const match of text.matchAll(pattern)) {
      for (let i = at; i < match.index; i++) { out += text[i]; map.push(kept[i]) }
      for (const [from, to] of keep(match)) {
        for (let i = from; i < to; i++) { out += text[i]; map.push(kept[i]) }
      }
      at = match.index + match[0].length
    }
    for (let i = at; i < text.length; i++) { out += text[i]; map.push(kept[i]) }
    text = out
    kept = Int32Array.from(map)
  }
  keeping(/^(>\s?)(.*)\\$/gmd, match => [match.indices[1], match.indices[2]])
  keeping(/^(>\s?)(.*)  $/gmd, match => [match.indices[1], match.indices[2]])
  keeping(/^(>.*\S.*)\n>\s*\n(>)/gmd, match => [
    match.indices[1], [match.indices[1][1], match.indices[1][1] + 1], match.indices[2],
  ])
  // Blank lines within a list, so its items stay one list.
  const lines = text.split('\n')
  const starts = []
  let offset = 0
  for (const line of lines) { starts.push(offset); offset += line.length + 1 }
  const item = /^(\s*)([-*+]|\d+\.)\s/
  let out = ''
  const map = []
  let inList = false
  let first = true
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    const isListItem = item.test(line)
    const isEmpty = line.trim() === ''
    let keepLine = true
    if (isListItem) {
      inList = true
    } else if (isEmpty && inList) {
      let nextIsListItem = false
      for (let j = i + 1; j < lines.length; j++) {
        if (lines[j].trim() !== '') { nextIsListItem = item.test(lines[j]); break }
      }
      if (nextIsListItem) keepLine = false
      else inList = false
    } else {
      inList = false
    }
    if (!keepLine) continue
    if (!first) { out += '\n'; map.push(kept[starts[i] - 1]) }
    for (let k = 0; k < line.length; k++) { out += line[k]; map.push(kept[starts[i] + k]) }
    first = false
  }
  return { text: out, kept: Int32Array.from(map) }
}

// A footnote block's notes: written from their sources, not traced through
// the writer, so each note is lined up with its line in the block, found by
// its label, and the two short texts matched character by character.
function traceNotes(note, raw, rawPm) {
  const { node, pos, out, end } = note
  const written = noteDefinitions(raw.slice(out, end))
  const labels = decodeLabels(node.attrs.labels)
  // The block's lines as shown: `[n] words`, with each character's place.
  const lines = [{ text: '', at: [] }]
  node.forEach((child, offset) => {
    const at = pos + 1 + offset
    if (child.type.name === 'hardBreak') lines.push({ text: '', at: [] })
    else if (child.isText) {
      for (let k = 0; k < child.text.length; k++) {
        lines[lines.length - 1].text += child.text[k]
        lines[lines.length - 1].at.push(at + k)
      }
    } else {
      lines[lines.length - 1].text += '￼'
      lines[lines.length - 1].at.push(-1)
    }
  })
  let current = null
  const shown = []
  for (const line of lines) {
    const number = line.text.match(/^\[([^\]\s]+)\][ \t]*/)
    if (number) {
      current = { label: labels.get(number[1]) ?? number[1], text: line.text.slice(number[0].length), at: line.at.slice(number[0].length) }
      shown.push(current)
    } else if (current) {
      current.text += '\n' + line.text
      current.at.push(-1, ...line.at)
    }
  }
  for (const note of shown) {
    const place = written.get(note.label)
    if (!place) continue
    const words = raw.slice(out + place.words, out + place.end)
    const map = characterAlignment(words, note.text)
    for (let k = 0; k < words.length; k++) {
      if (map[k] >= 0 && note.at[map[k]] >= 0) rawPm[out + place.words + k] = note.at[map[k]]
    }
  }
}

// The host's Markdown `source` lined up with the page's `text`: for each
// character of `source`, the character of `text` it is, or -1. False where
// the page holds words the host's text lacks: the host is behind the page.
//
// Footnote definitions are paired by label, each note's words with the
// same note's: the page writes them in the order they are referred to,
// which need not be the order they were written in, and lined up as one
// text a note moved would read as words taken out and put in elsewhere.
export function bridge(source, text, pmAt, atomAt) {
  const map = new Int32Array(source.length + 1).fill(-1)
  if (source === text) {
    for (let i = 0; i < source.length; i++) map[i] = i
    return map
  }
  const sourceNotes = noteDefinitions(source)
  const textNotes = noteDefinitions(text)
  // Each text without its notes, and where each kept character came from.
  const body = (whole, notes) => {
    const cut = [...notes.values()].sort((a, b) => a.start - b.start)
    let kept = ''
    const from = []
    let at = 0
    for (const note of cut) {
      for (let i = at; i < note.start; i++) { kept += whole[i]; from.push(i) }
      at = Math.max(at, note.end)
    }
    for (let i = at; i < whole.length; i++) { kept += whole[i]; from.push(i) }
    return { kept, from }
  }
  const sourceBody = body(source, sourceNotes)
  const textBody = body(text, textNotes)
  const aligned = characterMap(sourceBody.kept, textBody.kept)
  for (let i = 0; i < sourceBody.kept.length; i++) {
    if (aligned[i] >= 0) map[sourceBody.from[i]] = textBody.from[aligned[i]]
  }
  for (const [label, note] of sourceNotes) {
    const other = textNotes.get(label)
    if (!other) continue
    const words = characterMap(source.slice(note.words, note.end), text.slice(other.words, other.end))
    for (let k = 0; k < note.end - note.words; k++) {
      if (words[k] >= 0) map[note.words + k] = other.words + words[k]
    }
  }
  const reached = new Uint8Array(text.length)
  for (let i = 0; i < source.length; i++) if (map[i] >= 0) reached[map[i]] = 1
  const word = /[\p{L}\p{N}]/u
  for (let t = 0; t < text.length; t++) {
    if (!reached[t] && (pmAt[t] >= 0 || atomAt[t] >= 0) && word.test(text[t])) return false
  }
  // And the other way: words of the host's the page has none of, but for
  // what the page may drop or write otherwise (an HTML comment or tag, an
  // entity), mean the page is behind the host.
  const dropped = new Uint8Array(source.length)
  // A note's `[^label]:` is syntax on either side, written as the page
  // writes it.
  for (const note of sourceNotes.values()) for (let i = note.start; i < note.words; i++) dropped[i] = 1
  for (const match of source.matchAll(/<!--[\s\S]*?-->|<\/?[A-Za-z][^>\n]*>|&#?\w+;/g)) {
    for (let i = match.index; i < match.index + match[0].length; i++) dropped[i] = 1
  }
  for (let i = 0; i < source.length; i++) {
    if (map[i] < 0 && !dropped[i] && word.test(source[i])) return false
  }
  return map
}

// The host's marks as ranges of the page's document, each with its place:
// { ranges, unshown }. False where the host is behind the page; null where
// the page's writing could not be traced.
export function placeByTrace(marked, trace) {
  if (!trace) return null
  const read = marksInMarkdown(marked)
  if (!read) return null
  const map = bridge(read.text, trace.text, trace.pmAt, trace.atomAt)
  if (map === false) return false
  const { text, pmAt, atomAt, leafAt } = trace
  // The document position before the character written at t, and after it:
  // after a whole block, for a block with no text.
  const start = t => (pmAt[t] >= 0 ? pmAt[t] : atomAt[t])
  const end = t => (pmAt[t] >= 0 ? pmAt[t] + 1 : atomAt[t] + (leafAt[t] || 1))
  const traced = t => pmAt[t] >= 0 || atomAt[t] >= 0
  // Where the host's notes' words are: a mark that runs into or out of a
  // note, or across notes, is drawn in each part separately, since the page
  // shows the notes in another order and one span would cover notes
  // between that nobody changed.
  const notes = [...noteDefinitions(read.text).values()].sort((a, b) => a.start - b.start)
  const parts = (from, to) => {
    const found = []
    let at = from
    for (const note of notes) {
      if (note.end <= at || note.start >= to) continue
      if (note.start > at) found.push([at, Math.min(note.start, to)])
      found.push([Math.max(at, note.words), Math.min(note.end, to)])
      at = Math.min(note.end, to)
    }
    if (at < to) found.push([at, to])
    return found.filter(([a, b]) => b > a)
  }
  const ranges = []
  let unshown = 0
  for (const [order, mark] of read.marks.entries()) {
    // Nothing but space between its ends marks nothing.
    if (mark.to > mark.from && read.text.slice(mark.from, mark.to).trim() === '') continue
    // Paired with its change by its place, or failing one by its own order
    // among the marks sent: never by the order pieces come out in, which a
    // mark drawn in several parts, or one left out, would move.
    let placed = null
    if (mark.to > mark.from) {
      for (const [from, to] of parts(mark.from, mark.to)) {
        let first = -1
        let last = -1
        for (let i = from; i < to; i++) {
          const t = map[i]
          if (t >= 0 && traced(t)) {
            if (first < 0) first = t
            last = t
          }
        }
        if (first < 0) continue
        const piece = { from: start(first), to: Math.max(start(first), end(last)), order }
        ranges.push(mark.place === undefined ? piece : { ...piece, place: mark.place })
        placed = placed ?? piece
      }
      if (placed) continue
    }
    // A point; or a range of nothing the page shows as text (a note's label
    // changed, and nothing else), shown as a point where it stood.
    if (!placed) {
      // A point: the next character the document has, or after the last,
      // not across a blank line.
      let t = -1
      for (let i = mark.from; i < read.text.length; i++) {
        if (read.text[i] === '\n' && read.text[i + 1] === '\n') break
        if (map[i] >= 0 && traced(map[i])) { t = map[i]; break }
      }
      if (t >= 0) placed = { from: start(t), to: start(t) }
      else {
        for (let i = mark.from - 1; i >= 0; i--) {
          if (read.text[i] === '\n' && read.text[i - 1] === '\n') break
          if (map[i] >= 0 && traced(map[i])) { t = map[i]; break }
        }
        if (t >= 0) placed = { from: end(t), to: end(t) }
      }
      if (!placed) {
        // Among syntax the page writes otherwise (a fence of backticks for
        // one of tildes): between the nearest characters each side that
        // lined up, the first the page's text gives a place to.
        let before = -1
        let after = text.length
        for (let i = mark.from - 1; i >= 0; i--) if (map[i] >= 0) { before = map[i]; break }
        for (let i = mark.from; i < read.text.length; i++) if (map[i] >= 0) { after = map[i]; break }
        for (let t = before + 1; t < after; t++) {
          if (traced(t)) { placed = { from: start(t), to: start(t) }; break }
        }
      }
    }
    if (placed) ranges.push(mark.place === undefined ? { ...placed, order } : { ...placed, order, place: mark.place })
    else unshown++
  }
  return { ranges, unshown, text }
}

// A range of the document as a range of the page's Markdown: from the first
// character written for it to just past the last. A caret is the place
// just after the last character before it, so one after a bold word stays
// inside the word's stars; failing that, before the first after it. Null
// where nothing in it was written traceably.
export function markdownRange(trace, from, to, blockOf = null) {
  const { pmAt, atomAt } = trace
  const sameBlock = pm => !blockOf || blockOf(pm) === blockOf(from)
  let first = -1
  let last = -1
  let before = -1
  for (let t = 0; t < pmAt.length; t++) {
    const pm = pmAt[t] >= 0 ? pmAt[t] : atomAt[t]
    if (pm < 0) continue
    if (from === to) {
      // Only within the caret's own block: a caret at the start of a
      // paragraph is not the end of the one before.
      if (pm < from) { if (sameBlock(pm)) before = t }
      else if (first < 0 && sameBlock(pm)) first = t
      continue
    }
    if (pm >= from && pm < to) {
      if (first < 0) first = t
      last = t
    }
  }
  if (from === to) {
    if (before >= 0) return { from: before + 1, to: before + 1 }
    return first >= 0 ? { from: first, to: first } : null
  }
  if (first < 0) return null
  return { from: first, to: last + 1 }
}

// A range of the page's Markdown widened over a link's syntax when it holds
// the link's words exactly: `[` before, `](address)` after, or an autolink's
// `<` and `>`, so a clear takes in a change to where the link points.
export function aroundLink(text, range) {
  let { from, to } = range
  // Through any emphasis inside the link's brackets: `[**words**](…)`.
  while (from > 0 && '*_~'.includes(text[from - 1])) from--
  while (to < text.length && '*_~'.includes(text[to])) to++
  if (text[from - 1] === '<' && text[to] === '>') return { from: from - 1, to: to + 1 }
  if (text[from - 1] === '[' && text[to] === ']' && text[to + 1] === '(') {
    let depth = 0
    for (let i = to + 1; i < text.length; i++) {
      if (text[i] === '\\') { i++; continue }
      if (text[i] === '(') depth++
      else if (text[i] === ')' && --depth === 0) return { from: from - 1, to: i + 1 }
      else if (text[i] === '\n') break
    }
  }
  return range
}

// A range of the page's Markdown widened to whole lines: a block cleared from
// its ✓ is cleared with all its syntax, a list item's marker, a quote's mark,
// a link's address at its end, which a change to alone would otherwise keep.
export function wholeLines(text, range, fromLineStart, toLineEnd) {
  let { from, to } = range
  if (fromLineStart) while (from > 0 && text[from - 1] !== '\n') from--
  if (toLineEnd) while (to < text.length && text[to] !== '\n') to++
  return { from, to }
}
