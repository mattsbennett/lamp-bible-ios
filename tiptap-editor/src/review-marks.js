// What the writing assistant changed that the writer has not yet read: the
// host's marks, drawn over the document, and the writer's clears, sent back.
//
// The host keeps the marks against the writing's Markdown, which this page
// does not show. They cross over as markers written into a copy of that
// Markdown at each mark's edges: the page parses the copy as it parses any
// document, finds where the markers fell, takes them out, and draws there if
// what is left is the document it is showing. A clear goes back the same
// way: markers written into a copy of the document at the edges of what was
// cleared, serialised, and found again in the Markdown by the host. So no
// position is ever translated between the two by rule, and anything the
// round trip cannot place exactly is not drawn rather than drawn wrong.

// Private-use characters, which no writing contains and no Markdown rule
// treats as anything but a letter.
export const MARK_START = ''
export const MARK_END = ''
export const MARK_POINT = ''

// A passage's place among the marks the host sent, written after its start
// or point marker in private-use digits (U+E010 to U+E019) and closed by
// U+E01A, by a host that moves markers out of syntax the parser drops (a
// link's address): the passages can then stand in another order than the
// marks, and are paired with the host's changes by place, not by order.
export const PLACE_END = '\uE01A'

export function placeDigit(character) {
  const code = character.charCodeAt(0)
  return character.length === 1 && code >= 0xE010 && code <= 0xE019 ? code - 0xE010 : null
}

export function isMarker(character) {
  return character === MARK_START || character === MARK_END || character === MARK_POINT
    || placeDigit(character) !== null || character === PLACE_END
}

// Where the markers stand in a run of text pieces, each `{ pos, text }` with
// `pos` its position in the document, in order. Returns the marks as ranges
// in the document the markers are taken out of — `{ from, to }`, with
// `from === to` for a point, and `place` where the host wrote one — and each
// marker's own position, for taking them out. Null where the markers do not
// pair, which a host never sends.
export function readMarkers(pieces) {
  const markers = []
  for (const piece of pieces) {
    let offset = 0
    for (const character of piece.text) {
      if (isMarker(character)) markers.push({ character, pos: piece.pos + offset })
      offset += character.length
    }
  }
  const ranges = []
  let open = null
  // The place written after the marker at `index`, if one is.
  const placeAfter = index => {
    let value = 0
    let at = index + 1
    while (at < markers.length && placeDigit(markers[at].character) !== null) {
      value = value * 10 + placeDigit(markers[at].character)
      at += 1
    }
    return at > index + 1 && at < markers.length && markers[at].character === PLACE_END ? value : undefined
  }
  markers.forEach((marker, index) => {
    // Every marker before this one is taken out, and each was one position.
    const at = marker.pos - index
    if (marker.character === MARK_START) {
      if (open !== null) throw new Error('nested')
      open = { from: at, place: placeAfter(index) }
    } else if (marker.character === MARK_END) {
      if (open === null) throw new Error('unopened')
      ranges.push(placed({ from: open.from, to: at }, open.place))
      open = null
    } else if (marker.character === MARK_POINT) {
      ranges.push(placed({ from: at, to: at }, placeAfter(index)))
    }
  })
  if (open !== null) return null
  return { ranges, positions: markers.map(marker => marker.pos) }
}

function placed(range, place) {
  return place === undefined ? range : { ...range, place }
}

// `ranges` less every span in `taken`, each `[from, to]`: what of the marks
// is still the assistant's once the writer has typed into them. A point
// standing where something was typed goes too.
export function withoutSpans(ranges, taken) {
  let result = ranges
  for (const [from, to] of taken) {
    const next = []
    for (const range of result) {
      if (range.from === range.to) {
        if (range.from < from || range.from > to) next.push(range)
        continue
      }
      if (range.to <= from || range.from >= to) {
        next.push(range)
        continue
      }
      if (range.from < from) next.push({ ...range, to: from })
      if (range.to > to) next.push({ ...range, from: to })
    }
    result = next
  }
  return result
}

// `ranges` with any the writer has typed into or beside, or deleted from,
// by the spans in `typed` (a deletion's is empty), no longer offering to
// put its wording back: their words and the assistant's can no longer be
// told apart there, and a restore would take both. Its `change` says why
// instead, as the host would. The host checks again before putting anything
// back, so this only keeps the page from offering what it would refuse.
export function withoutTypedChanges(ranges, typed) {
  return ranges.map(range => {
    if (!range.change || range.change.reason) return range
    const touched = typed.some(([from, to]) => from <= range.to && to >= range.from)
    if (!touched) return range
    return { ...range, change: { id: range.change.id, reason: 'edited' } }
  })
}

// Which of `ranges` each block offers to put back, or says why it can't: a
// range with a `change`, in the first block it touches, so one that runs
// over several is offered once. `blocks` are `{ start, end }` in document order; returns, for each,
// the indexes of its ranges.
export function restorableByBlock(ranges, blocks) {
  // Both in document order, walked together: a range is offered in the
  // first block it touches, so once a block has passed a range's start the
  // range is either offered or never will be. Linear in blocks and ranges,
  // where comparing each with each was not, on a long writing with many.
  const order = ranges.map((range, index) => index)
    .filter(index => ranges[index].change)
    .sort((a, b) => ranges[a].from - ranges[b].from || ranges[a].to - ranges[b].to)
  const own = blocks.map(() => [])
  let first = 0
  for (const index of order) {
    const range = ranges[index]
    while (first < blocks.length && blocks[first].end < range.from) first++
    if (first < blocks.length && range.to >= blocks[first].start && range.from <= blocks[first].end) own[first].push(index)
  }
  for (const list of own) list.sort((a, b) => a - b)
  return own
}

// The range a step through the marks lands on from a caret at `at`: the
// first starting after it, going forward, or the last starting before it,
// going back, round to the other end when there is none. Null with none.
export function nextMark(ranges, at, forward) {
  if (ranges.length === 0) return null
  const sorted = [...ranges].sort((a, b) => a.from - b.from || a.to - b.to)
  if (forward) return sorted.find(range => range.from > at) ?? sorted[0]
  return [...sorted].reverse().find(range => range.from < at) ?? sorted[sorted.length - 1]
}

