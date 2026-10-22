// Verse references in a note's text, found as the app finds them where it
// draws a note (VerseReferenceParser in ToolPanelView.swift), so the editor
// shows the same ones: [John 3:16] or John 3:16, with an optional end verse,
// a book named in full, by abbreviation or by the start of its name, and a
// verse the reader's translation has.
//
// The host supplies the catalog (setVerseCatalog):
//   names:         { "john": 43, "1 john": 62, ... }   full names, lower-case
//   abbreviations: { "jn": 43, "1jn": 62, ... }        lower-case
//   verses:        { "43": [51, 25, 36, ...], ... }    verses in each chapter

const BRACKETED = /\[([1-3]?\s?[A-Za-z]+)\s+(\d+):(\d+)(?:-(\d+))?\]/g
const UNBRACKETED = /(?<!\[)(?<!\w)([1-3]?\s?[A-Za-z]{2,})\.?\s+(\d{1,3}):(\d{1,3})(?:-(\d{1,3}))?(?!\])(?!\w)/g

export function resolveBook(book, catalog) {
  const name = book.trim().toLowerCase()
  if (name in catalog.names) return catalog.names[name]
  if (name in catalog.abbreviations) return catalog.abbreviations[name]
  // The start of a name, "1 Jn" for "1 John": the first in Bible order.
  let found = null
  for (const [full, id] of Object.entries(catalog.names)) {
    if (full.startsWith(name) && (found === null || id < found)) found = id
  }
  return found
}

function exists(bookId, chapter, verse, catalog) {
  const chapters = catalog.verses[String(bookId)]
  return !!chapters && chapter >= 1 && chapter <= chapters.length && verse >= 1 && verse <= chapters[chapter - 1]
}

/** The references in `text`, as [{ start, end }] in its UTF-16 offsets. */
export function findVerseReferences(text, catalog) {
  if (!catalog) return []
  const found = []
  for (const pattern of [BRACKETED, UNBRACKETED]) {
    pattern.lastIndex = 0
    for (const match of text.matchAll(pattern)) {
      const bookId = resolveBook(match[1], catalog)
      if (bookId === null) continue
      if (!exists(bookId, Number(match[2]), Number(match[3]), catalog)) continue
      // The pattern lets a book's optional number take a space before it
      // even when there is no number; the space is no part of the reference.
      const lead = match[0].length - match[0].trimStart().length
      found.push({ start: match.index + lead, end: match.index + match[0].length })
    }
  }
  const seen = new Set()
  return found
    .sort((a, b) => a.start - b.start)
    .filter(r => {
      const key = `${r.start}-${r.end}`
      if (seen.has(key)) return false
      seen.add(key)
      return true
    })
}
