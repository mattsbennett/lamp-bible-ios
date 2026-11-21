import assert from 'node:assert/strict'
import { MARK_START, MARK_END, MARK_POINT, readMarkers, withoutSpans, withoutTypedChanges, restorableByBlock, nextMark } from './review-marks.js'

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

// Typed into, beside or deleted from, a mark can't be put back, and says
// so; elsewhere it still can.
{
  const change = { id: 'a', now: 'deux', before: 'two' }
  const other = { id: 'b', now: 'cinq', before: 'five' }
  const edited = { id: 'a', reason: 'edited' }
  const ranges = [{ from: 5, to: 9, change }, { from: 20, to: 24, change: other }]
  assert.deepEqual(withoutTypedChanges(ranges, [[9, 10]]), [{ from: 5, to: 9, change: edited }, ranges[1]])
  assert.deepEqual(withoutTypedChanges(ranges, [[6, 7]]), [{ from: 5, to: 9, change: edited }, ranges[1]])
  // A deletion's span is empty.
  assert.deepEqual(withoutTypedChanges(ranges, [[7, 7]]), [{ from: 5, to: 9, change: edited }, ranges[1]])
  assert.deepEqual(withoutTypedChanges(ranges, [[12, 14]]), ranges)
  // A point typed at goes with its change.
  assert.deepEqual(withoutTypedChanges([{ from: 5, to: 5, change }], [[5, 6]]), [{ from: 5, to: 5, change: edited }])
}

// Each change is offered once, in the first block it touches.
{
  const change = { id: 'x', now: 'a', before: 'b' }
  const ranges = [{ from: 2, to: 4, change }, { from: 6, to: 14, change }, { from: 16, to: 17 }]
  const blocks = [{ start: 1, end: 8 }, { start: 10, end: 18 }]
  assert.deepEqual(restorableByBlock(ranges, blocks), [[0, 1], []])
  assert.deepEqual(restorableByBlock([{ from: 16, to: 17 }], blocks), [[], []])
}

// Stepping through the marks, round at either end.
{
  const ranges = [{ from: 20, to: 22 }, { from: 5, to: 9 }, { from: 12, to: 12 }]
  assert.deepEqual(nextMark(ranges, 0, true), { from: 5, to: 9 })
  assert.deepEqual(nextMark(ranges, 5, true), { from: 12, to: 12 })
  assert.deepEqual(nextMark(ranges, 21, true), { from: 5, to: 9 })
  assert.deepEqual(nextMark(ranges, 12, false), { from: 5, to: 9 })
  assert.deepEqual(nextMark(ranges, 3, false), { from: 20, to: 22 })
  assert.equal(nextMark([], 3, true), null)
}

console.log('review-marks: ok')
