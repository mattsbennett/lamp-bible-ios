// tidyMarkdown as editor.js had it before tidyKeeping (review-trace.js)
// replaced it: kept only so tidy-keeping.test.mjs can prove the new one
// writes the same, byte for byte. Not part of the page.
export function tidyMarkdown(serialized) {
  let md = serialized

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
