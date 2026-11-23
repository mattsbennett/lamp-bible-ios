// Lining two texts up by their words, for review marks (review-trace.js):
// the host's Markdown with the page's own writing of it, where the page
// restyles what it was given, and a footnote's Markdown with the note as the
// page shows it. Each is the same words in the same order, with syntax on
// one side or the other, so they are matched word by word and character by
// character within the words, never by parsing anything.
//
// Pure: texts in, offsets out.

import { MARK_START, MARK_END, MARK_POINT, PLACE_END, placeDigit } from './review-marks.js'

// The marks in the host's marked Markdown, as offsets in the Markdown with
// the markers taken out: { text, marks: [{ from, to, place }] }, a point
// having from === to. Null where the markers do not pair.
export function marksInMarkdown(marked) {
  let text = ''
  const marks = []
  let open = null
  for (let i = 0; i < marked.length; i++) {
    const character = marked[i]
    if (character !== MARK_START && character !== MARK_END && character !== MARK_POINT) {
      if (placeDigit(character) !== null || character === PLACE_END) continue
      text += character
      continue
    }
    let end = i + 1
    while (end < marked.length && placeDigit(marked[end]) !== null) end++
    const placed = end > i + 1 && marked[end] === PLACE_END
    const place = placed ? Number([...marked.slice(i + 1, end)].map(placeDigit).join('')) : undefined
    if (character === MARK_START) {
      if (open !== null) return null
      open = { from: text.length, place }
    } else if (character === MARK_END) {
      if (open === null) return null
      marks.push({ from: open.from, to: text.length, place: open.place })
      open = null
    } else {
      marks.push({ from: text.length, to: text.length, place })
    }
    if (placed) i = end
  }
  return open === null ? { text, marks } : null
}

// A text's tokens: each run of letters, digits and combining marks, and each
// other character that is not space, with where it starts.
export function tokens(text) {
  const found = []
  const pattern = /[\p{L}\p{N}\p{M}]+|[^\s\p{L}\p{N}\p{M}]/gu
  for (const match of text.matchAll(pattern)) found.push({ text: match[0], at: match.index })
  return found
}

// The tokens of `a` and `b` that are the same words in the same order, as
// pairs of indexes: a patience alignment. Tokens found once in each, in
// order, anchor it; between anchors the same is done again, and where no
// token is unique, the ends that match are taken and a short stretch is
// lined up exactly. Linear but for those short stretches.
export function alignTokens(a, b) {
  const pairs = []
  const align = (aFrom, aTo, bFrom, bTo, depth) => {
    // The same at the start, and at the end.
    while (aFrom < aTo && bFrom < bTo && a[aFrom].text === b[bFrom].text) pairs.push([aFrom++, bFrom++])
    const tail = []
    while (aFrom < aTo && bFrom < bTo && a[aTo - 1].text === b[bTo - 1].text) tail.push([--aTo, --bTo])
    if (aFrom < aTo && bFrom < bTo) {
      const anchors = depth < 64 ? uniqueAnchors(a, aFrom, aTo, b, bFrom, bTo) : []
      if (anchors.length > 0) {
        let aAt = aFrom
        let bAt = bFrom
        for (const [i, j] of anchors) {
          align(aAt, i, bAt, j, depth + 1)
          pairs.push([i, j])
          aAt = i + 1
          bAt = j + 1
        }
        align(aAt, aTo, bAt, bTo, depth + 1)
      } else if ((aTo - aFrom) * (bTo - bFrom) <= 40000) {
        pairs.push(...commonSubsequence(a, aFrom, aTo, b, bFrom, bTo))
      }
    }
    pairs.push(...tail.reverse())
  }
  align(0, a.length, 0, b.length, 0)
  return pairs
}

// The tokens found exactly once in each stretch, kept where they keep their
// order in both: the longest such run, by patience sorting.
function uniqueAnchors(a, aFrom, aTo, b, bFrom, bTo) {
  const count = (list, from, to) => {
    const counts = new Map()
    for (let i = from; i < to; i++) {
      const seen = counts.get(list[i].text)
      counts.set(list[i].text, seen === undefined ? i : -1)
    }
    return counts
  }
  const inA = count(a, aFrom, aTo)
  const inB = count(b, bFrom, bTo)
  const candidates = []
  for (const [text, i] of inA) {
    if (i < 0) continue
    const j = inB.get(text)
    if (j !== undefined && j >= 0) candidates.push([i, j])
  }
  candidates.sort((x, y) => x[0] - y[0])
  // Longest increasing run by b's index.
  const tails = []
  const previous = new Array(candidates.length)
  for (let k = 0; k < candidates.length; k++) {
    let low = 0
    let high = tails.length
    while (low < high) {
      const middle = (low + high) >> 1
      if (candidates[tails[middle]][1] < candidates[k][1]) low = middle + 1
      else high = middle
    }
    previous[k] = low > 0 ? tails[low - 1] : -1
    tails[low] = k
  }
  const run = []
  for (let k = tails.length > 0 ? tails[tails.length - 1] : -1; k >= 0; k = previous[k]) run.push(candidates[k])
  return run.reverse()
}

// The longest common subsequence of two short stretches of tokens.
function commonSubsequence(a, aFrom, aTo, b, bFrom, bTo) {
  const n = aTo - aFrom
  const m = bTo - bFrom
  const table = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      table[i][j] = a[aFrom + i].text === b[bFrom + j].text
        ? table[i + 1][j + 1] + 1
        : Math.max(table[i + 1][j], table[i][j + 1])
    }
  }
  const pairs = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[aFrom + i].text === b[bFrom + j].text) {
      pairs.push([aFrom + i, bFrom + j])
      i++
      j++
    } else if (table[i + 1][j] >= table[i][j + 1]) {
      i++
    } else {
      j++
    }
  }
  return pairs
}

// For each character of `source`, the character of `shown` it is, or -1:
// the characters of the tokens the alignment paired.
export function characterMap(source, shown) {
  const a = tokens(source)
  const b = tokens(shown)
  const map = new Int32Array(source.length + 1).fill(-1)
  for (const [i, j] of alignTokens(a, b)) {
    for (let k = 0; k < a[i].text.length; k++) map[a[i].at + k] = b[j].at + k
  }
  return map
}

// For each character of `a`, the character of `b` it is, or -1: the longest
// common subsequence of their characters, for two short texts, such as a
// note's Markdown and the note shown, where emphasis can stand inside a
// word (`un*happy*`) and tokens would not match. Longer ones go by tokens.
export function characterAlignment(a, b) {
  if (a.length * b.length > 4000000) return characterMap(a, b)
  const n = a.length
  const m = b.length
  const rows = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1))
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      rows[i][j] = a[i] === b[j] ? rows[i + 1][j + 1] + 1 : Math.max(rows[i + 1][j], rows[i][j + 1])
    }
  }
  const map = new Int32Array(n + 1).fill(-1)
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) map[i++] = j++
    else if (rows[i + 1][j] >= rows[i][j + 1]) i++
    else j++
  }
  return map
}

// The footnote definitions in Markdown: each one's label, and where its
// words begin and end, its later lines (indented, perhaps after blank lines)
// included. A label written twice is the first one's.
export function noteDefinitions(text) {
  const notes = new Map()
  const lines = []
  let at = 0
  for (const line of text.split('\n')) {
    lines.push({ at, line })
    at += line.length + 1
  }
  // Not inside a code fence, where `[^x]: value` is text.
  let fence = null
  for (let i = 0; i < lines.length; i++) {
    const marker = lines[i].line.match(/^ {0,3}(`{3,}|~{3,})/)
    if (marker && (fence === null || marker[1][0] === fence)) {
      fence = fence === null ? marker[1][0] : null
      continue
    }
    if (fence !== null) continue
    const found = lines[i].line.match(/^ {0,3}\[\^([^\]\s]+)\]:[ \t]*/)
    if (!found) continue
    const start = lines[i].at
    let end = lines[i].at + lines[i].line.length
    let j = i + 1
    while (j < lines.length) {
      if (/^(?: {4}|\t)/.test(lines[j].line) && lines[j].line.trim() !== '') {
        end = lines[j].at + lines[j].line.length
        j++
      } else if (lines[j].line.trim() === '') {
        let k = j
        while (k < lines.length && lines[k].line.trim() === '') k++
        if (k < lines.length && /^(?: {4}|\t)/.test(lines[k].line)) j = k
        else break
      } else {
        break
      }
    }
    if (!notes.has(found[1])) notes.set(found[1], { start, words: start + found[0].length, end })
    i = j - 1
  }
  return notes
}
