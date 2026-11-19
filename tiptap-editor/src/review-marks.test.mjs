import assert from 'node:assert/strict'
import { MARK_START, MARK_END, MARK_POINT, readMarkers, withoutSpans } from './review-marks.js'

// A mark across a word, read where the markers are taken out.
{
  const read = readMarkers([{ pos: 1, text: `One ${MARK_START}deux${MARK_END} three.` }])
  assert.deepEqual(read.ranges, [{ from: 5, to: 9 }])
  assert.deepEqual(read.positions, [5, 10])
}

// Marks in two blocks, and a point: each position counts the markers before.
{
  const read = readMarkers([
    { pos: 1, text: `${MARK_START}A${MARK_END} b` },
    { pos: 10, text: `c${MARK_POINT} d` },
  ])
  assert.deepEqual(read.ranges, [{ from: 1, to: 2 }, { from: 9, to: 9 }])
}

// A mark left open is not drawn.
assert.equal(readMarkers([{ pos: 1, text: `${MARK_START}open` }]), null)
assert.throws(() => readMarkers([{ pos: 1, text: `${MARK_END}x` }]))

// What the writer types inside a mark is theirs.
assert.deepEqual(
  withoutSpans([{ from: 1, to: 10 }], [[4, 6]]),
  [{ from: 1, to: 4 }, { from: 6, to: 10 }],
)
// Typed at a point, the point goes; elsewhere it stays.
assert.deepEqual(withoutSpans([{ from: 5, to: 5 }], [[5, 8]]), [])
assert.deepEqual(withoutSpans([{ from: 5, to: 5 }], [[6, 8]]), [{ from: 5, to: 5 }])
// Nothing typed, nothing taken.
assert.deepEqual(withoutSpans([{ from: 1, to: 3 }], []), [{ from: 1, to: 3 }])

console.log('review-marks: ok')
