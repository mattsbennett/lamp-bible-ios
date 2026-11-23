/**
 * The web and email addresses written out in a block's text, to be tapped.
 *
 * The page reads Markdown with linkify off, as the apps' readers do, so a
 * bare address is words to the document and is saved as words. This is
 * only for drawing: the page marks each address it finds as something to
 * tap (BareLinks, in editor.js), and nothing it finds is ever written back.
 *
 * The rules are core's (LampBareLinks.swift), after GitHub's extended
 * autolinks, which err towards leaving words alone. The text is read a word
 * at a time, and a word is an address only where all of it, less the
 * sentence's punctuation and the quote or bracket around it, is one: a web
 * address that begins https://, http:// or www. and names a host with a dot
 * in it, or an email address whose name is letters, digits and . + - _.
 * Never part of one, which would open somewhere else.
 *
 * A caller hides what isn't the writer's plain words (a link, code, a
 * footnote's reference) behind U+FFFC: an address that runs into one is
 * left as words, since it may go on past it.
 *
 * Kept free of the editor so it can be exercised on its own.
 */

const HIDDEN = '￼'

const OPENING = new Set([...'([{<"‘“«「『【〔《〈'])
const CLOSERS = {
  '(': ')', '[': ']', '{': '}', '<': '>', "'": "'", '"': '"', '‘': '’', '“': '”', '«': '»',
  '「': '」', '『': '』', '【': '】', '〔': '〕', '《': '》', '〈': '〉',
}
const CLOSING = new Set([...'?!.,:;*_~\'"’”»」』】〕》〉>}。、，：；！？…'])
const LETTER_OR_DIGIT = /[\p{L}\p{M}\p{N}]/u
const EMAIL = /^[A-Za-z0-9.+_-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]*[A-Za-z0-9])+$/

function isLetterOrDigit(character) {
  return LETTER_OR_DIGIT.test(character)
}

/** The character that ends just before `index` in `text`, pairs whole. */
function characterBefore(text, index) {
  if (index <= 0) return ''
  const code = text.charCodeAt(index - 1)
  if (code >= 0xDC00 && code <= 0xDFFF && index >= 2) return text.slice(index - 2, index)
  return text[index - 1]
}

function startsWithIgnoringCase(text, at, prefix) {
  return text.slice(at, at + prefix.length).toLowerCase() === prefix
}

/** Where a web address begins in a word: its start, or after punctuation. */
function webStart(word) {
  for (let index = 0; index < word.length; index++) {
    if (!(startsWithIgnoringCase(word, index, 'http://') || startsWithIgnoringCase(word, index, 'https://')
      || startsWithIgnoringCase(word, index, 'www.'))) continue
    if (index === 0) return 0
    const before = characterBefore(word, index)
    if (before === HIDDEN || isLetterOrDigit(before) || '.+_-/:@=&?#%\\'.includes(before)) return -1
    // Inside another scheme's address (`mailto:…`, `//host/…`): that one's.
    if (word.slice(0, index).includes(':') || word.startsWith('//')) return -1
    return index
  }
  return -1
}

/**
 * The sentence's punctuation taken off an address's end: a closing bracket
 * only where the address didn't open it, and a trailing `&name;` whole.
 */
function trimClosing(text) {
  let open = { '(': 0, '[': 0 }
  let close = { ')': 0, ']': 0 }
  for (const character of text) {
    if (character in open) open[character]++
    if (character in close) close[character]++
  }
  let end = text.length
  while (end > 0) {
    const last = text[end - 1]
    if (last === ')' && close[')'] > open['(']) {
      close[')']--
    } else if (last === ']' && close[']'] > open['[']) {
      close[']']--
    } else if (last === ';') {
      // An entity's `&name;` whole, read back only through its name.
      let index = end - 2
      while (index >= 0 && /[A-Za-z0-9]/.test(text[index])) index--
      if (index >= 0 && index < end - 2 && text[index] === '&') {
        end = index
        continue
      }
      // A semicolon ending a sentence is the sentence's.
    } else if (!CLOSING.has(last)) {
      break
    }
    end--
  }
  return text.slice(0, end)
}

/** A host to link to: two labels or more, and no `_` in the last two. */
function isHost(host) {
  const labels = (host.endsWith('.') ? host.slice(0, -1) : host).split('.')
  if (labels.length < 2 || labels.some(label => label === '' || !/^[\p{L}\p{M}\p{N}_-]+$/u.test(label))) return false
  return !labels.slice(-2).some(label => label.includes('_'))
}

/**
 * A web address, if `written` is one: its host checked as written, not as
 * the browser would repair it (`https:///x`, an integer for an address),
 * so the page and the apps' readers turn the same words away.
 */
function web(written) {
  if (!written || written.includes('<') || written.includes(HIDDEN)) return null
  const full = written.toLowerCase().startsWith('www.') ? `http://${written}` : written
  const authority = full.slice(full.indexOf('://') + 3).split(/[/?#]/)[0]
  if (authority.includes('@')) return null
  const host = authority.replace(/:[0-9]+$/, '')
  if (!isHost(host)) return null
  try {
    new URL(full)
  } catch {
    return null
  }
  return full
}

/** The address one word is, as where it stands in the word and what it opens. */
function addressInWord(word) {
  // Run into something hidden (a link, code, a footnote's reference), however
  // the punctuation falls: it may go on past it.
  if (word.includes(HIDDEN)) return null
  const start = webStart(word)
  if (start >= 0) {
    let kept = word.slice(start)
    const opener = start > 0 ? word[start - 1] : null
    const closer = opener ? CLOSERS[opener] : null
    if (closer) {
      if (opener === '(' || opener === '[') {
        // The bracket that closes the prose's: the first the address didn't open.
        let depth = 0
        for (let index = 0; index < kept.length; index++) {
          if (kept[index] === opener) depth++
          if (kept[index] === closer) {
            if (depth === 0) {
              kept = kept.slice(0, index)
              break
            }
            depth--
          }
        }
      } else {
        // A quote: the first that closes it, but an apostrophe may stand in
        // the address, so for one, the last.
        const end = opener === "'" ? kept.lastIndexOf(closer) : kept.indexOf(closer)
        if (end >= 0) kept = kept.slice(0, end)
      }
    }
    // Another script's punctuation ends it where that script's prose
    // follows (`…/help。を見る`). Where the address may go on past it (a
    // host's next label, `example.com。au`, or the path's, `/O’Reilly`)
    // there's no address to guess at.
    for (let index = 0; index < kept.length; index++) {
      const character = kept[index]
      if (character.charCodeAt(0) < 0x80 || !CLOSING.has(character)) continue
      const scheme = kept.toLowerCase().startsWith('https://') ? 8 : kept.toLowerCase().startsWith('http://') ? 7 : 0
      const inHost = !kept.slice(scheme, index).includes('/')
      const code = kept.codePointAt(index + 1)
      const after = code === undefined ? '' : String.fromCodePoint(code)
      if (after && (inHost ? isLetterOrDigit(after) : /[A-Za-z0-9]/.test(after))) return null
      kept = kept.slice(0, index)
      break
    }
    kept = trimClosing(kept)
    const href = web(kept)
    if (href) return { start, end: start + kept.length, href }
    // `www.alice@example.com` is someone to write to.
    if (kept.toLowerCase().startsWith('http') || kept.includes('/')) return null
  }
  if (!word.includes('@')) return null
  let start2 = 0
  while (start2 < word.length && OPENING.has(word[start2])) start2++
  let kept = trimClosing(word.slice(start2))
  // `'`, `*` and `~` may begin a mailbox's name: one is a wrapper only where
  // the same closes it.
  let head = 0
  let closerAt = start2 + kept.length
  while (head < kept.length && "'*~".includes(kept[head]) && word[closerAt] === kept[head]) {
    head++
    closerAt++
  }
  start2 += head
  kept = kept.slice(head)
  // An address ended by `_` is no address (GFM).
  if (word[start2 + kept.length] === '_') return null
  if (!EMAIL.test(kept)) return null
  return { start: start2, end: start2 + kept.length, href: `mailto:${kept}` }
}

/**
 * Every address written out in `text`, by where it stands (UTF-16, as the
 * page counts) and what it opens.
 */
export function findBareAddresses(text) {
  const found = []
  // Split as the apps' readers split: Unicode's white space, and a
  // zero-width space.
  for (const match of text.matchAll(/[^\p{White_Space}\u200B]+/gu)) {
    const address = addressInWord(match[0])
    if (address) found.push({ start: match.index + address.start, end: match.index + address.end, href: address.href })
  }
  return found
}
