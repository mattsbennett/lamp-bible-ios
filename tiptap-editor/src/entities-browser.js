// markdown-it's only use of the `entities` package: decoding one named
// character reference it has matched, such as `&copy;`. The page already
// has a decoder that follows the same HTML rules, so the package's tables,
// most of a hundred kilobytes, stay out of the bundle (vite.config.js).
const area = document.createElement('textarea')

export function decodeHTML(str) {
  area.innerHTML = str
  return area.value
}
