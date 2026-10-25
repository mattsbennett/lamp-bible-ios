// Find in a document: where literal text occurs in one block's text.
//
// A block's text is read as the editor holds it, with each inline that is not
// text (a footnote reference, a line break) standing as U+FFFC, so an offset
// here is a position there and a match never runs across one.

const wordCharacter = '[\\p{L}\\p{M}\\p{N}]'

// The query as a pattern, or null for none. Literal text, matched case
// insensitively unless asked otherwise: `i` with `u` folds case without
// changing lengths, as lowercasing the text first would (İ becomes two
// characters). A whole word has no letter, mark or digit either side, so
// "grace" is not found in "gracéd".
export function searchPattern(query, options = {}) {
  if (typeof query !== 'string' || query === '') return null
  let source = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  if (options.wholeWord) source = `(?<!${wordCharacter})${source}(?!${wordCharacter})`
  return new RegExp(source, options.caseSensitive ? 'gu' : 'giu')
}

// Each place the pattern matches in the text, as { start, end }.
export function findMatches(text, pattern) {
  if (!pattern) return []
  const matches = []
  for (const match of text.matchAll(pattern)) {
    matches.push({ start: match.index, end: match.index + match[0].length })
  }
  return matches
}
