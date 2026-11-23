// Checks the built editor in WebKit itself, the engine both apps run it in:
// what a host relies on when it hands one editor from document to document,
// and what must survive a round trip through it. macOS only.
//
//   npm run test:webkit
import AppKit
import WebKit
setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
let roundTrip = """
See [verse 16](lampbible://verse/43003016) and [H157](lampbible://strongs/0/H157).

[An audio clip](media/aud-1)
"""

final class Probe: NSObject, WKScriptMessageHandler {
    var onReady: (() -> Void)?
    var changes: [String] = []
    var heights: [Int] = []
    var carets: [(top: Int, bottom: Int)] = []
    var tokens: [String: [String?]] = [:]
    var searches: [(count: Int, current: Int, token: String?)] = []
    var footnoteTaps: [(id: String, editing: Bool)] = []
    var reviewClears: [String] = []
    var reviewClearTexts: [String] = []
    var reviewRestores: [(id: String, plain: String)] = []
    var reviewStale = 0
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        tokens[type, default: []].append(body["token"] as? String)
        if type == "ready" { onReady?() }
        if type == "contentChanged" { changes.append(body["markdown"] as? String ?? "") }
        if type == "contentHeight" { heights.append(body["height"] as? Int ?? -1) }
        if type == "caret" { carets.append((body["top"] as? Int ?? -1, body["bottom"] as? Int ?? -1)) }
        if type == "footnoteTapped" { footnoteTaps.append((body["id"] as? String ?? "", body["editing"] as? Bool ?? false)) }
        if type == "reviewClear" {
            reviewClears.append(body["markdown"] as? String ?? "")
            reviewClearTexts.append(body["plain"] as? String ?? "")
        }
        if type == "reviewMarksStale" { reviewStale += 1 }
        if type == "reviewRestore" {
            reviewRestores.append((body["id"] as? String ?? "", body["plain"] as? String ?? ""))
        }
        if type == "searchChanged" { searches.append((body["count"] as? Int ?? -1, body["current"] as? Int ?? -1, body["token"] as? String)) }
    }
}
let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
window.orderBack(nil)
let probe = Probe()
let config = WKWebViewConfiguration()
config.userContentController.add(probe, name: "tiptapBridge")
let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 400), configuration: config)
window.contentView?.addSubview(view)

func js(_ s: String, _ done: @escaping (Any?) -> Void) {
    view.evaluateJavaScript(s) { r, e in if let e { print("  js error: \(e)") }; done(r) }
}
func after(_ ms: Int, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: f) }
let undo = "document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown', {key: 'z', code: 'KeyZ', metaKey: true, bubbles: true, cancelable: true}))"
var failed = false
func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL")  \(what)"); if !ok { failed = true } }

// Edit one document, hand the editor to another inside the 300 ms debounce,
// then press Undo. `replace` is how the second document arrives.
func trial(_ name: String, replace: String, leaks: Bool = false, _ next: @escaping () -> Void) {
    print("-- \(name)")
    js("window.editorAPI.load ? window.editorAPI.load('First note') : window.editorAPI.setContent('First note'); window.editorAPI.focus(); window.editorAPI.insertScriptureQuote('John 1:1', 'In the beginning'); window.editorAPI.getContent()") { first in
        check((first as? String ?? "").contains("In the beginning"), "\(name): the first document was edited")
        after(50) {
            probe.changes = []
            js("\(replace)('Second note'); window.editorAPI.getContent()") { second in
                check((second as? String) == "Second note", "\(name): the second document is in place")
                after(600) {
                    check(probe.changes.isEmpty != leaks, "\(name): \(leaks ? "the earlier edit's report arrives late" : "nothing reported as an edit afterwards") (got \(probe.changes.count): \(probe.changes.map { String($0.prefix(40)) }))")
                    js("\(undo); window.editorAPI.getContent()") { undone in
                        let text = undone as? String ?? ""
                        check((text == "Second note") != leaks, "\(name): Undo \(leaks ? "reaches back into the first document" : "stays in the second document") (read: \(text.prefix(60).debugDescription))")
                        next()
                    }
                }
            }
        }
    }
}

// Once any pending report has gone, a host's own setContent is not
// reported back to it as an edit.
func echo() {
    print("-- setContent echo")
    js("window.editorAPI.load('First note')") { _ in
        after(400) {
            probe.changes = []
            js("window.editorAPI.setContent('Third note')") { _ in
                after(600) {
                    check(probe.changes.isEmpty, "setContent is not reported back (got \(probe.changes.count))")
                    height()
                }
            }
        }
    }
}

func height() {
    print("-- height")
    js("window.editorAPI.setReportsHeight(true)") { _ in
        after(200) {
            check(!probe.heights.isEmpty && probe.heights.allSatisfy { $0 > 0 }, "a height is reported when turned on (\(probe.heights))")
            js("window.editorAPI.load('Same height A')") { _ in
                after(200) {
                    probe.heights = []
                    js("window.editorAPI.load('Same height B')") { _ in
                        after(200) {
                            check(probe.heights.count >= 1, "load() reports a height even when it is unchanged (\(probe.heights))")
                            probe.heights = []
                            js("window.editorAPI.load('One\\n\\nTwo\\n\\nThree\\n\\nFour')") { _ in
                                after(300) {
                                    let taller = probe.heights.max() ?? 0
                                    check(taller > 0, "a taller document reports its height (\(probe.heights))")
                                    js("window.editorAPI.setBackgroundColor('rgb(28, 28, 30)'); document.body.classList.add('dark'); getComputedStyle(document.body).backgroundColor") { bg in
                                        check((bg as? String) == "rgb(28, 28, 30)", "setBackgroundColor holds in the dark theme (read: \(String(describing: bg)))")
                                        survives()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// Verse references are marked on screen as the host finds them, and the
// Markdown is left as it was written.
func references() {
    print("-- verse references")
    let note = "Born again[^1] — John 3:3; see Jn. 3:16 and Version 2:10."
    let literal = String(data: try! JSONSerialization.data(withJSONObject: [note]), encoding: .utf8)!.dropFirst().dropLast()
    js("window.editorAPI.load(\(literal)); document.querySelectorAll('.verse-reference').length") { r in
        check((r as? Int) == 0, "without a catalog nothing is marked (read: \(String(describing: r)))")
        js("""
            window.editorAPI.setVerseCatalog({
                names: { john: 43 }, abbreviations: { jn: 43 },
                verses: { '43': [51, 25, 36] }
            });
            [Array.from(document.querySelectorAll('.verse-reference')).map(e => e.textContent), window.editorAPI.getContent()]
            """) { r in
            let parts = r as? [Any] ?? []
            let marked = parts.first as? [String] ?? []
            check(marked == ["John 3:3", "Jn. 3:16"], "the references are marked, after a footnote too (read: \(marked))")
            check((parts.last as? String) == note, "and the Markdown is as written (read: \(String(describing: parts.last)))")
            js("window.editorAPI.setVerseCatalog(null)") { _ in find() }
        }
    }
}

// A tap on the host's drawing of a note puts the caret by the word tapped.
func focused() {
    print("-- focus at a point")
    js("""
        window.editorAPI.load('Alpha beta gamma delta');
        const range = document.createRange();
        const text = document.querySelector('.ProseMirror p').firstChild;
        range.setStart(text, 13); range.setEnd(text, 14);
        const box = range.getBoundingClientRect();
        window.editorAPI.focusAt(box.left + 1, box.top + box.height / 2 + window.scrollY);
        window.editorAPI.insertFootnoteRef('9');
        window.editorAPI.getContent()
        """) { r in
        check((r as? String) == "Alpha beta ga[^9]mma delta", "focusAt places the caret at the point (read: \(String(describing: r)))")
        js("window.editorAPI.load('Short'); window.editorAPI.focusAt(5, 5000); window.editorAPI.insertFootnoteRef('8'); window.editorAPI.getContent()") { r in
            check((r as? String) == "Short[^8]", "a point past the text puts the caret at the end (read: \(String(describing: r)))")
            references()
        }
    }
}

// A note typed as plain text keeps its line breaks through the editor, where
// the host asks for them; elsewhere Markdown's own reading stands.
func breaks() {
    print("-- line breaks")
    let notes = [
        "Line one\nLine two\nLine three",
        "Para one\n\nPara two\nstill two",
        "> quoted\n> and more",
        "- one\n- two\n\nafter",
    ]
    let literal = String(data: try! JSONSerialization.data(withJSONObject: notes), encoding: .utf8)!
    js("window.editorAPI.setLineBreaks(true); \(literal).map(n => { window.editorAPI.load(n); return window.editorAPI.getContent() })") { r in
        let back = r as? [String] ?? []
        for (note, out) in zip(notes, back) {
            check(out == note, "kept as typed: \(note.debugDescription) (read: \(out.debugDescription))")
        }
        js("window.editorAPI.setLineBreaks(false); window.editorAPI.load('Line one\\nLine two'); window.editorAPI.getContent()") { r in
            check((r as? String) == "Line one Line two", "without it, Markdown's soft break stands (read: \(String(describing: r)))")
            focused()
        }
    }
}

// Every message about a document loaded with a token carries it.
func tokened() {
    print("-- token")
    js("window.editorAPI.load('Tokened', 'doc-7')") { _ in
        after(100) {
            probe.tokens = [:]
            js("window.editorAPI.focus(); window.editorAPI.insertScriptureQuote('John 1:1', 'Word')") { _ in
                after(500) {
                    let changed = probe.tokens["contentChanged"] ?? []
                    check(!changed.isEmpty && changed.allSatisfy { $0 == "doc-7" }, "an edit's report carries its document's token (\(changed))")
                    let all = probe.tokens.values.flatMap { $0 }
                    check(!all.isEmpty && all.allSatisfy { $0 == "doc-7" }, "so does every other message (\(probe.tokens.mapValues { $0.count }))")
                    breaks()
                }
            }
        }
    }
}

// The apps' own links and an audio block come back as they went in.
func survives() {
    print("-- round trip")
    let literal = String(data: try! JSONSerialization.data(withJSONObject: [roundTrip]), encoding: .utf8)!.dropFirst().dropLast()
    js("window.editorAPI.load(\(literal)); window.editorAPI.getContent()") { back in
        let text = back as? String ?? ""
        check(text.contains("[verse 16](lampbible://verse/43003016)") && text.contains("[H157](lampbible://strongs/0/H157)"), "lampbible links are kept")
        check(text.contains("[An audio clip](media/aud-1)"), "an audio block keeps its caption and media (read: \(text.debugDescription))")
        fences()
    }
}

// A code block holding ``` is saved between a longer fence, so it reads back
// whole, through a save and a load and a save again.
func fences() {
    let fenced = "Before.\\n\\n````\\nfirst\\n```\\nstill code\\n````\\n\\nAfter."
    js("""
    (() => {
      window.editorAPI.load('\(fenced)');
      const once = window.editorAPI.getContent();
      window.editorAPI.load(once);
      return [once, window.editorAPI.getContent(), document.querySelectorAll('.ProseMirror pre').length,
        document.querySelector('.ProseMirror pre')?.textContent ?? '']
    })()
    """) { r in
        let parts = r as? [Any] ?? []
        let once = parts.first as? String ?? ""
        check(once.contains("````\nfirst\n```\nstill code\n````"), "a code block holding ``` is saved between a longer fence (read: \(once.debugDescription))")
        check(parts.count == 4 && parts[1] as? String == once, "and saves the same after it is read back")
        check(parts.count == 4 && parts[2] as? Int == 1 && parts[3] as? String == "first\n```\nstill code", "and is still one block, every line its own (read: \(parts.dropFirst(2)))")
        codeLikeProse()
    }
}

// Code shaped like a quote or a list is saved as written: tidying the
// writer's quotes and lists leaves fenced code alone.
func codeLikeProse() {
    let code = "```\\n> x\\\\\\n- a\\n\\n- b\\n```"
    js("window.editorAPI.load('\(code)'); [window.editorAPI.getContent(), document.querySelector('.ProseMirror pre')?.textContent ?? '']") { r in
        let parts = r as? [String] ?? []
        check(parts.first == "```\n> x\\\n- a\n\n- b\n```", "code shaped like a quote and a list is saved as written (read: \(parts.first.debugDescription))")
        check(parts.count == 2 && parts[1] == "> x\\\n- a\n\n- b", "and shown as written (read: \(parts.dropFirst()))")
        let quoted = "> ```\\n> x\\\\\\n>\\n> y  \\n> ```"
        js("window.editorAPI.load('\(quoted)'); [window.editorAPI.getContent(), document.querySelector('.ProseMirror blockquote pre')?.textContent ?? '']") { r in
            let parts = r as? [String] ?? []
            check(parts.first == "> ```\n> x\\\n> \n> y  \n> ```", "and so is code in a quote, its empty line written as the serializer writes one in any quote (read: \(parts.first.debugDescription))")
            check(parts.count == 2 && parts[1] == "x\\\n\ny  ", "and shown as written (read: \(parts.dropFirst()))")
            // Codex's cases: code is what markdown-it reads as code. A quote's
            // line indented in its paragraph is not a fence, and a fence left
            // open ends with its quote, so later quotes keep their lines.
            let indented = "> before\\n>     ~~~\\n> after\\n> last"
            let open = "> ```\\n> code\\n\\nOutside\\n\\n> first\\n> second"
            js("(() => { window.editorAPI.load('\(indented)'); const a = window.editorAPI.getContent(); window.editorAPI.load('\(open)'); return [a, window.editorAPI.getContent()] })()") { r in
                let parts = r as? [String] ?? []
                check(parts.first?.hasSuffix("\n> after\n> last") == true, "a quote's indented line of tildes is not code (read: \(parts.first.debugDescription))")
                check(parts.count == 2 && parts[1].hasSuffix("> first\n> second"), "and a fence left open in a quote ends with it (read: \(parts.last.debugDescription))")
                bareLinks()
            }
        }
    }
}

// Addresses written out are drawn as links to tap, and saved as written:
// a link the writer made and code are left as they are.
func bareLinks() {
    print("-- bare links")
    let written = "Read https://example.com/noah and [made](https://made.example), `https://code.example`, then study@example.com."
    let literal = String(data: try! JSONSerialization.data(withJSONObject: [written]), encoding: .utf8)!.dropFirst().dropLast()
    js("""
        (() => {
          window.editorAPI.load(\(literal));
          const drawn = () => [...document.querySelectorAll('.bare-link')].map(link => link.getAttribute('href'));
          const editing = drawn();
          window.editorAPI.setMode('read');
          const reading = drawn();
          const content = window.editorAPI.getContent();
          window.editorAPI.setMode('edit');
          return [reading, content, editing, drawn()];
        })()
        """) { result in
        let parts = result as? [Any] ?? []
        let links = parts.first as? [String] ?? []
        check(links == ["https://example.com/noah", "mailto:study@example.com"], "addresses written out are links while reading, and only those (\(links))")
        check(parts.count == 4 && (parts[1] as? String) == written, "and the Markdown is saved as written (read: \(String(describing: parts.count > 1 ? parts[1] : nil)))")
        check(parts.count == 4 && (parts[2] as? [String]) == [] && (parts[3] as? [String]) == [], "and words while editing (\(parts.dropFirst(2)))")
        notes()
    }
}

// What a notes host leans on: the caret's place, a reference inserted for a
// footnote kept outside the document, and references shown by their labels.
func notes() {
    print("-- notes")
    probe.carets = []
    js("window.editorAPI.load('One\\n\\nTwo')") { _ in
        after(150) {
            let first = probe.carets.last
            check(first.map { $0.top >= 0 && $0.bottom > $0.top } == true, "load() reports the caret (\(String(describing: first)))")
            js("window.editorAPI.focus(); window.editorAPI.insertScriptureQuote('John 1:1', 'In the beginning was the Word')") { _ in
                after(150) {
                    let moved = probe.carets.last
                    check((moved?.top ?? -1) > (first?.top ?? Int.max), "the caret is reported as it moves down (\(String(describing: first)) -> \(String(describing: moved)))")
                    js("window.editorAPI.load('Before after'); window.editorAPI.focus(); window.editorAPI.insertFootnoteRef(3); window.editorAPI.getContent()") { md in
                        check((md as? String ?? "").contains("[^3]"), "insertFootnoteRef writes the reference (read: \(String(describing: md)))")
                        // A note's footnotes are kept outside it, and a reference
                        // with no definition here shows its own label, as the
                        // host's list of them does.
                        js("window.editorAPI.load('b [^2] a [^1]'); [document.querySelector('sup.footnote-ref').textContent, window.editorAPI.getContent()]") { r in
                            let parts = r as? [String] ?? []
                            check(parts.first == "[2]", "a note's reference shows its own label (read: \(parts))")
                            check(parts.last == "b [^2] a [^1]", "and is written back as it was")
                            tokened()
                        }
                    }
                }
            }
        }
    }
}

// Find and replace, for a host's find bar: what is found, the current match
// moved and wrapped, and a replacement that keeps its marks and undoes as one.
func found(_ r: Any?) -> [Int] {
    let d = r as? [String: Any] ?? [:]
    return [d["count"] as? Int ?? -1, d["current"] as? Int ?? -1]
}
// This window is never key, so focus never lands in it: what is checked is
// whether the editor asks for it, by the calls to its element's focus(). Nor
// is it ever drawn, so it gets no animation frames, which TipTap focuses on:
// a timer stands in for them, so a focus TipTap asks for is counted too.
let countFocus = """
    window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16);
    var editorElement = document.querySelector('.ProseMirror');
    var focusRequests = 0;
    var elementFocus = editorElement.focus;
    editorElement.focus = function () { focusRequests += 1; return elementFocus.apply(this, arguments) };
    """
func find() {
    print("-- find")
    js("""
        \(countFocus)
        window.editorAPI.load('grace upon Grace and gracefully grace');
        var first = window.editorAPI.setSearch('grace', {});
        window.editorAPI.findNext(); window.editorAPI.findPrevious();
        [first, document.querySelectorAll('.search-match').length,
         document.querySelector('.search-match-current').textContent,
         focusRequests === 0,
         window.editorAPI.getContent()]
        """) { r in
        let parts = r as? [Any] ?? []
        check(found(parts.first) == [4, 1], "setSearch counts every match and the first is current (read: \(found(parts.first)))")
        check((parts.count > 1 ? parts[1] as? Int : nil) == 4, "every match is marked")
        check((parts.count > 2 ? parts[2] as? String : nil) == "grace", "the current match is marked as such")
        check((parts.count > 3 ? parts[3] as? Bool : nil) == true, "setSearch, findNext and findPrevious ask for no focus")
        check((parts.last as? String) == "grace upon Grace and gracefully grace", "the marks are not written into the Markdown")
        js("""
            var a = window.editorAPI;
            [a.findNext(), a.findNext(), a.findNext(), a.findNext(), a.findPrevious(),
             a.setSearch('grace', { caseSensitive: true }), a.setSearch('grace', { wholeWord: true }),
             a.setSearch('race', { wholeWord: true }), a.setSearch('', {}),
             document.querySelectorAll('.search-match').length]
            """) { r in
            let parts = r as? [Any] ?? []
            let moves = parts.prefix(5).map(found)
            check(moves == [[4, 2], [4, 3], [4, 4], [4, 1], [4, 4]], "next and previous move the current match and wrap (read: \(moves))")
            check(parts.count > 5 && found(parts[5]) == [3, 1], "case is matched when asked (read: \(parts.count > 5 ? found(parts[5]) : []))")
            check(parts.count > 6 && found(parts[6]) == [3, 1], "a whole word is not found inside a longer one (read: \(parts.count > 6 ? found(parts[6]) : []))")
            check(parts.count > 7 && found(parts[7]) == [0, 0], "nor is part of a word (read: \(parts.count > 7 ? found(parts[7]) : []))")
            check(parts.count > 9 && found(parts[8]) == [0, 0] && parts[9] as? Int == 0, "an empty query ends the search")
            replaced()
        }
    }
}

func replaced() {
    print("-- replace")
    js("""
        var a = window.editorAPI;
        a.load('**Grace** upon grace and grace');
        a.focus();
        a.setSearch('grace', {});
        var current = [a.replaceCurrent('Mercy'), a.getContent()];
        var next = [a.replaceCurrent('love'), a.getContent()];
        [current, next]
        """) { r in
        let parts = r as? [[Any]] ?? []
        let current = parts.first ?? [], next = parts.last ?? []
        check(current.first.map(found) == [2, 1], "replaceCurrent makes the next match current (read: \(current.first.map(found) ?? []))")
        check(current.last as? String == "**Mercy** upon grace and grace", "the replacement keeps the match's marks (read: \(String(describing: current.last)))")
        check(next.last as? String == "**Mercy** upon love and grace", "and the next replace replaces the next (read: \(String(describing: next.last)))")
        js("window.editorAPI.focus(); \(undo); window.editorAPI.getContent()") { r in
            check(r as? String == "**Mercy** upon grace and grace", "Undo undoes one replacement at a time (read: \(String(describing: r)))")
            js("""
                var a = window.editorAPI;
                a.load('grace and grace and grace');
                a.focus();
                a.setSearch('grace', {});
                [a.replaceAll('love'), a.getContent(), a.findNext()]
                """) { r in
                let parts = r as? [Any] ?? []
                check(parts.first as? Int == 3 && parts.count > 1 && parts[1] as? String == "love and love and love", "replaceAll replaces every match (read: \(parts.prefix(2)))")
                check(parts.count > 2 && found(parts[2]) == [0, 0], "and leaves none to find")
                js("window.editorAPI.focus(); \(undo); window.editorAPI.getContent()") { r in
                    check(r as? String == "grace and grace and grace", "a single Undo undoes replaceAll (read: \(String(describing: r)))")
                    js("""
                        var a = window.editorAPI;
                        a.load('grace and grace');
                        a.setSearch('grace', {});
                        [a.replaceCurrent('grace upon grace'), a.getContent()]
                        """) { r in
                        let parts = r as? [Any] ?? []
                        check(parts.first.map(found) == [3, 3] && parts.last as? String == "grace upon grace and grace", "a replacement that holds the query is passed over, not found again (read: \(parts))")
                        // An edit just before, and touching the match, would
                        // otherwise be undone with it.
                        js("""
                            var a = window.editorAPI;
                            a.load('grace');
                            a.focus();
                            a.insertFootnoteRef('1');
                            a.setSearch('grace', {});
                            a.replaceCurrent('mercy');
                            a.focus();
                            \(undo);
                            a.getContent()
                            """) { r in
                            check(r as? String == "[^1]grace", "Undo undoes the replacement alone, after an edit beside it (read: \(String(describing: r)))")
                            across()
                        }
                    }
                }
            }
        }
    }
}

func across() {
    print("-- find within a block")
    js("""
        var a = window.editorAPI;
        a.load('gra[^1]ce and grace\\n\\ngra\\\\\\nce\\n\\n[^1]: a note on grace');
        var result = a.setSearch('grace', {});
        [result, a.replaceAll('mercy'), a.getContent()]
        """) { r in
        let parts = r as? [Any] ?? []
        check(found(parts.first) == [2, 1], "no match runs across a footnote reference or a line break, and a footnote is searched (read: \(found(parts.first)))")
        let md = parts.last as? String ?? ""
        check(md.contains("[^1]: a note on mercy") && md.contains("gra[^1]ce and mercy"), "a replaced footnote is written back (read: \(md.debugDescription))")
        reported()
    }
}

func reported() {
    print("-- searchChanged")
    js("window.editorAPI.setSearch('grace', {}); window.editorAPI.load('a grace', 'doc-9')") { _ in
        after(100) {
            let loaded = probe.searches.last
            check(loaded.map { [$0.count, $0.current] } == [1, 1] && loaded?.token == "doc-9", "load() reports the search in the next document, with its token (\(String(describing: loaded)))")
            probe.searches = []
            js("window.editorAPI.focus(); window.editorAPI.insertScriptureQuote('John 1:16', 'grace for grace')") { _ in
                after(100) {
                    let typed = probe.searches.last
                    // The quote goes in before the match that was current, which stays so.
                    check(typed.map { [$0.count, $0.current] } == [3, 3], "an edit reports the new count, and the current match stays current (\(probe.searches))")
                    probe.searches = []
                    js("window.editorAPI.clearSearch(); window.editorAPI.insertScriptureQuote('John 1:17', 'grace and truth'); document.querySelectorAll('.search-match').length") { r in
                        after(100) {
                            check(probe.searches.isEmpty && r as? Int == 0, "nothing is reported or marked once the search ends (\(probe.searches))")
                            selected()
                        }
                    }
                }
            }
        }
    }
}

func selected() {
    print("-- select the current match")
    js("""
        var a = window.editorAPI;
        a.load('one grace two grace');
        a.setSearch('grace', {});
        a.findNext();
        focusRequests = 0;
        a.selectCurrentMatch();
        var asked = focusRequests > 0;
        a.clearSearch();
        """) { _ in
        after(100) {
        js("[window.editorAPI.getSelectedText(), asked]") { r in
        let parts = r as? [Any] ?? []
        check(parts.first as? String == "grace" && parts.last as? Bool == true, "selectCurrentMatch selects it and focuses the editor (read: \(parts))")
        js("""
            var a = window.editorAPI;
            a.load('read only grace');
            a.setMode('read');
            a.setSearch('grace', {});
            var result = [a.replaceAll('x'), a.getContent()];
            a.clearSearch();
            a.setMode('edit');
            result
            """) { r in
            let parts = r as? [Any] ?? []
            check(parts.first as? Int == 0 && parts.last as? String == "read only grace", "a document that cannot be edited is not replaced in (read: \(parts))")
            footnoteMarkdown()
        }
        }
        }
    }
}

// A footnote's own Markdown is shown as the body's is, and given back as it
// was read while it reads the same; one changed is written from what is shown.
func footnoteMarkdown() {
    print("-- footnote formatting")
    let first = "[^1]: See **this**, _that_ and [John 3:16](lampbible://verse/43003016)."
    let strongs = "[^s]: Love, [H157](lampbible://strongs/0/H157)."
    let doc = "See[^1] and[^a], love[^s].\n\n\(first)\n[^a]: plain\n\(strongs)"
    let literal = String(data: try! JSONSerialization.data(withJSONObject: [doc]), encoding: .utf8)!.dropFirst().dropLast()
    js("""
        var a = window.editorAPI;
        a.load(\(literal));
        var d = document.querySelector('.footnote-definition');
        var shown = [d.querySelector('strong')?.textContent ?? '', d.querySelector('em')?.textContent ?? '',
         Array.from(d.querySelectorAll('a')).map(l => l.getAttribute('href')).join(' ')];
        var back = a.getContent();
        a.load(back);
        shown.concat([back, a.getContent()])
        """) { r in
        let parts = r as? [String] ?? []
        guard parts.count == 5 else { check(false, "footnote formatting read (read: \(String(describing: r)))"); exit(1) }
        check(parts[0] == "this" && parts[1] == "that", "bold and italic in a footnote are shown as such (read: \(parts[0]), \(parts[1]))")
        check(parts[2] == "lampbible://verse/43003016 lampbible://strongs/0/H157", "and its verse and Strong's links are links (read: \(parts[2]))")
        check(parts[3] == doc, "an unedited document comes back as it was written (read: \(parts[3].debugDescription))")
        check(parts[4] == parts[3], "and reads back the same a second time")
        js("""
            var a = window.editorAPI;
            a.setSearch('plain', {}); a.selectCurrentMatch(); a.clearSearch();
            a.toggleBold();
            a.getContent()
            """) { r in
            let md = r as? String ?? ""
            check(md.hasSuffix("\(first)\n[^a]: **plain**\n\(strongs)"), "a word bolded in a footnote is written in bold, and the footnotes around it as they were (read: \(md.debugDescription))")
            js("""
                var a = window.editorAPI;
                a.setSearch('See', { caseSensitive: true }); a.findNext(); a.selectCurrentMatch(); a.clearSearch();
                a.toggleBold();
                var md = a.getContent();
                a.load(md);
                [md, document.querySelectorAll('.footnote-definition strong').length, document.querySelector('.footnote-definition a')?.getAttribute('href') ?? '']
                """) { r in
                let parts = r as? [Any] ?? []
                let md = parts.first as? String ?? ""
                check(md.contains("[^1]: **See** **this**, *that* and [John 3:16](lampbible://verse/43003016)."), "a footnote changed is written from what is shown, its link kept (read: \(md.debugDescription))")
                check(parts.count == 3 && parts[1] as? Int == 3 && parts[2] as? String == "lampbible://verse/43003016", "and reads back as it was shown (read: \(parts.dropFirst()))")
                js("""
                    var a = window.editorAPI;
                    a.load('A note[^1].\\n\\n[^1]: plain');
                    a.setSearch('plain', {}); a.replaceCurrent('2 * 3 * 4 and _x_'); a.clearSearch();
                    var md = a.getContent();
                    a.load(md);
                    [md, document.querySelector('.footnote-definition').textContent, document.querySelectorAll('.footnote-definition em').length]
                    """) { r in
                    let parts = r as? [Any] ?? []
                    check(parts.count == 3 && (parts[1] as? String)?.hasSuffix("2 * 3 * 4 and _x_") == true && parts[2] as? Int == 0, "what is typed into a footnote reads back as typed, not as Markdown (read: \(parts))")
                    longFootnotes()
                }
            }
        }
    }
}

// Footnotes over more than one line, as the apps' own writer writes them
// (LampPersonalMarkdownWriter.footnoteDefinitions): later lines set in four
// spaces, an empty one as four spaces, a blank line between definitions.
func longFootnotes() {
    print("-- footnotes over more than one line")
    let core = "Grace[^1] and faith[^2].\n\n[^1]: first line\n    second **bold** line\n    \n    fourth line\n\n[^2]: single"
    let trailing = "Body[^1].\n\n[^1]: note\n    [sic] more\n\nAfter the footnotes."
    let literal = String(data: try! JSONSerialization.data(withJSONObject: [core, trailing]), encoding: .utf8)!
    js("""
        var a = window.editorAPI;
        var docs = \(literal);
        a.load(docs[0]);
        var d = document.querySelector('.footnote-definition');
        var shown = [d.innerText, d.querySelectorAll('br').length, d.querySelector('strong')?.textContent ?? ''];
        var back = a.getContent();
        a.load(docs[1]);
        var body = [a.getContent(), document.querySelectorAll('.tiptap pre').length,
                    Array.from(document.querySelectorAll('.tiptap > p')).map(p => p.textContent).filter(t => t)];
        [shown, back, body]
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 3, let shown = parts[0] as? [Any], let body = parts[2] as? [Any] else { check(false, "long footnotes read (read: \(String(describing: r)))"); exit(1) }
        let text = shown.first as? String ?? ""
        let indent = String(repeating: "\u{00A0}", count: 4)
        check(text.contains("[1] first line\n\(indent)second bold line\n\(indent)\n\(indent)fourth line\n[2] single"), "a footnote's later lines are shown beneath its first, set in (read: \(text.debugDescription))")
        check(shown.count == 3 && shown[1] as? Int == 4 && shown[2] as? String == "bold", "each on its own line, its marks shown (read: \(shown.dropFirst()))")
        check(parts[1] as? String == core, "the writer's own footnotes come back as written (read: \(String(describing: parts[1]).debugDescription))")
        let md = body.first as? String ?? ""
        check(md == trailing, "what follows the footnotes stays after them, and a later line beginning [sic] stays in its footnote (read: \(md.debugDescription))")
        check(body.count == 3 && body[1] as? Int == 0 && (body[2] as? [String]) == ["Body[1].", "After the footnotes."], "and nothing set in reads as code (read: \(body.dropFirst()))")
        js("""
            var a = window.editorAPI;
            a.load(docs[0]);
            a.setSearch('fourth', {}); a.selectCurrentMatch(); a.clearSearch();
            a.toggleBold();
            var bolded = a.getContent();
            a.load(docs[1]);
            a.setSearch('note', { wholeWord: true }); a.selectCurrentMatch(); a.clearSearch();
            a.toggleItalic();
            [bolded, a.getContent()]
            """) { r in
            let parts = r as? [String] ?? []
            check(parts.first == "Grace[^1] and faith[^2].\n\n[^1]: first line\n    second **bold** line\n    \n    **fourth** line\n\n[^2]: single", "a word bolded on a later line is written as the writer writes it (read: \(String(describing: parts.first).debugDescription))")
            check(parts.last == "Body[^1].\n\n[^1]: *note*\n    \\[sic\\] more\n\nAfter the footnotes.", "a later line beginning [sic] is still one when its footnote is changed (read: \(String(describing: parts.last).debugDescription))")
            js("""
                var a = window.editorAPI;
                a.load('One[^1].\\n\\n[^1]: first');
                a.focus();
                a.insertFootnote('2', 'added *here*');
                1
                """) { _ in
                // One edit, there at once; the wait is only to be sure
                // nothing arrives after it.
                after(150) {
                    js("window.editorAPI.getContent()") { r in
                        // Its reference goes in at the caret, here the start.
                        check(r as? String == "[^2]One[^1].\n\n[^1]: first\n\n[^2]: added \\*here\\*", "a footnote the phone adds is written beneath the others (read: \(String(describing: r).debugDescription))")
                        placedFootnotes()
                    }
                }
            }
        }
    }
}

// Footnotes stay where they were written: prose after them stays after them,
// and runs of them through a writing each stay in their place.
func placedFootnotes() {
    print("-- footnotes where they were written")
    let docs = [
        "Before.[^1]\n\n[^1]: Note\n\nAfter the note.",
        "A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: three\n\nEnd.",
        "[^1]: first\n\nBody[^1].",
    ]
    let literal = String(data: try! JSONSerialization.data(withJSONObject: docs), encoding: .utf8)!
    js("""
        var a = window.editorAPI;
        var docs = \(literal);
        var back = docs.map(d => { a.load(d); return a.getContent() });
        a.load(docs[1]);
        var blocks = Array.from(document.querySelectorAll('.footnote-definition'));
        var shown = blocks.map(b => b.innerText);
        var order = Array.from(document.querySelector('.tiptap').children).map(c => c.className === 'footnote-definition' ? 'notes' : c.textContent).filter(t => t);
        var scrolled = [];
        var scrollIntoView = Element.prototype.scrollIntoView;
        Element.prototype.scrollIntoView = function () { scrolled.push(blocks.indexOf(this)) };
        a.scrollToFootnote('3'); a.scrollToFootnote('1');
        Element.prototype.scrollIntoView = scrollIntoView;
        [back, shown, order, scrolled]
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 4, let back = parts[0] as? [String] else { check(false, "placed footnotes read (read: \(String(describing: r)))"); exit(1) }
        for (doc, out) in zip(docs, back) {
            check(out == doc, "kept in place: \(doc.debugDescription) (read: \(out.debugDescription))")
        }
        check((parts[1] as? [String]) == ["[1] one", "[2] two\n[3] three"], "each run is a block of its own, numbered through the writing (read: \(String(describing: parts[1])))")
        check((parts[2] as? [String]) == ["A[1].", "notes", "B[2] and C[3].", "notes", "End."], "in its place among the paragraphs (read: \(String(describing: parts[2])))")
        check((parts[3] as? [Int]) == [1, 0], "a tapped reference goes to the block holding its footnote (read: \(String(describing: parts[3])))")
        js("""
            var a = window.editorAPI;
            a.load(docs[1]);
            a.setSearch('three', {}); a.selectCurrentMatch(); a.clearSearch();
            a.toggleBold();
            var bolded = a.getContent();
            a.load('One.');
            a.focus();
            a.insertFootnote('1', 'new');
            a.load(docs[1]);
            a.focus();
            a.insertFootnote('4', 'four');
            bolded
            """) { r in
            check(r as? String == "A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: **three**\n\nEnd.", "a footnote changed changes only its own line, in its place (read: \(String(describing: r).debugDescription))")
            after(150) {
                js("window.editorAPI.getContent()") { r in
                    check(r as? String == "[^4]A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: three\n[^4]: four\n\nEnd.", "a footnote added goes with the last of them (read: \(String(describing: r).debugDescription))")
                    js("var a = window.editorAPI; a.load('One.'); a.focus(); a.insertFootnote('1', 'new'); a.getContent()") { r in
                        check(r as? String == "[^1]One.\n\n[^1]: new", "and where there are none, at the end (read: \(String(describing: r).debugDescription))")
                        // Written close, with no blank line either side: the
                        // block still stands apart, and the prose after it is
                        // still prose.
                        js("var a = window.editorAPI; a.load('Before.[^1]\\n[^1]: Note\\nAfter **it**.'); [a.getContent(), Array.from(document.querySelectorAll('.tiptap > p')).map(p => p.innerHTML).filter(t => t)]") { r in
                            let parts = r as? [Any] ?? []
                            check(parts.first as? String == "Before.[^1]\n\n[^1]: Note\n\nAfter **it**.", "footnotes written close to prose keep their place (read: \(String(describing: parts.first).debugDescription))")
                            check((parts.last as? [String])?.last == "After <strong>it</strong>.", "and the prose after them is read as prose (read: \(String(describing: parts.last)))")
                            markerClicks()
                        }
                    }
                }
            }
        }
    }
}

// While writing, a footnote's marker leads into its note, the caret at the
// start of its text, by a click or a tap alike; the note's number leads back.
// Each press is a separate click: two at one spot within half a second are a
// double-click to ProseMirror.
func markerClicks() {
    print("-- a marker and its note while writing")
    js("""
        var doc = 'A[^1].\\n\\n[^1]: one\\n\\nB[^2] and C[^3].\\n\\n[^2]: two\\n[^3]: three\\n\\nEnd.';
        // Where each jump asks the page to scroll: the caret's line, so
        // what's recorded is which kind of line the caret is on.
        var scrolled = [];
        var scrollIntoView = Element.prototype.scrollIntoView;
        var scrollBy = window.scrollBy;
        window.scrollBy = function () {
            var at = window.getSelection().anchorNode;
            var element = at && (at.nodeType === 1 ? at : at.parentElement);
            scrolled.push(element && element.closest('.footnote-definition') ? 'note' : 'text');
        };
        function press(target, kind, x) {
            var r = target.getBoundingClientRect();
            var at = {clientX: x === undefined ? r.left + r.width / 2 : r.left + x, clientY: r.top + r.height / 2, button: 0, bubbles: true, cancelable: true};
            target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({pointerType: kind}, at)));
            target.dispatchEvent(new MouseEvent('mousedown', at));
            target.dispatchEvent(new MouseEvent('mouseup', at));
            target.dispatchEvent(new MouseEvent('click', at));
        }
        function onMarker(kind) {
            var a = window.editorAPI;
            a.load(doc);
            press(document.querySelector('sup.footnote-ref[data-id="3"]'), kind);
            var selected = !!document.querySelector('.ProseMirror-selectednode');
            a.insertFootnoteRef('9');
            return [a.getContent(), selected];
        }
        onMarker('mouse')
        """) { mouse in
        after(600) {
            js("onMarker('touch')") { touch in
                for (kind, result) in [("click", mouse), ("tap", touch)] {
                    let parts = result as? [Any] ?? []
                    check(parts.first as? String == "A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: [^9]three\n\nEnd.", "a \(kind) on a marker puts the caret at the start of its note (read: \(String(describing: parts.first).debugDescription))")
                    check(parts.last as? Bool == false, "and leaves the marker unselected, so typing can't replace it (\(kind))")
                }
                after(600) {
                    js("""
                        var a = window.editorAPI;
                        a.load(doc);
                        press(document.querySelectorAll('.footnote-definition')[1], 'mouse', 2);
                        a.insertFootnoteRef('8');
                        window.scrollBy = scrollBy;
                        [a.getContent(), scrolled]
                        """) { r in
                        let parts = r as? [Any] ?? []
                        check(parts.first as? String == "A[^1].\n\n[^1]: one\n\nB[^2][^8] and C[^3].\n\n[^2]: two\n[^3]: three\n\nEnd.", "the note's number leads back to its marker (read: \(String(describing: parts.first).debugDescription))")
                        check((parts.last as? [String]) == ["note", "note", "text"], "and the page goes with the caret each time (read: \(String(describing: parts.last)))")
                        // A host can keep the notes apart from the writing:
                        // then the marker has nothing on the page to go to,
                        // and the host is told.
                        after(600) {
                            js("window.editorAPI.load('Kept apart.[^7]'); press(document.querySelector('sup.footnote-ref'), 'mouse'); window.editorAPI.getContent()") { r in
                                after(100) {
                                    check(probe.footnoteTaps.count == 1 && probe.footnoteTaps.first?.id == "7" && probe.footnoteTaps.first?.editing == true, "a marker whose note isn't on the page tells the host, as editing (read: \(probe.footnoteTaps))")
                                    check(r as? String == "Kept apart.[^7]", "and changes nothing (read: \(String(describing: r).debugDescription))")
                                    after(600) { notePopovers() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// For a host that asks (setFootnoteClicks('popover')), a marker opens its
// note beside it, drawn as the page draws it, to write in; what's written
// goes into the note's lines. A note holding more than text opens as its
// Markdown.
func notePopovers() {
    print("-- a note opened by its marker")
    js("""
        var a = window.editorAPI;
        function panelEditor() {
            var pm = document.querySelector('.note-popover .note-popover-editor .ProseMirror');
            return pm ? pm.editor : null;
        }
        a.setFootnoteClicks('popover');
        a.load(doc);
        press(document.querySelector('sup.footnote-ref[data-id="3"]'), 'mouse');
        var panel = document.querySelector('.note-popover');
        var note = panelEditor();
        var opened = [!!panel, panel ? panel.querySelector('.note-popover-heading span').textContent : null, note ? note.getText() : null];
        if (note) note.chain().selectAll().insertContent([{type: 'text', text: 'three, edited'}, {type: 'hardBreak'}, {type: 'text', text: 'and a second line'}]).run();
        var edited = a.getContent();
        if (note) note.chain().selectAll().insertContent([{type: 'text', text: 'bold', marks: [{type: 'bold'}]}, {type: 'text', text: ' word'}]).run();
        var emphasised = a.getContent();
        if (note) note.view.dom.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true}));
        [opened, edited, emphasised]
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 3, let opened = parts[0] as? [Any] else { check(false, "note popover read (read: \(String(describing: r)))"); exit(1) }
        check(opened.first as? Bool == true && opened[1] as? String == "Note 3" && opened[2] as? String == "three", "a click on a marker opens its note by it, holding the note's text (read: \(opened))")
        check(parts[1] as? String == "A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: three, edited\n    and a second line\n\nEnd.", "what's written goes into the note, a later line set in (read: \(String(describing: parts[1]).debugDescription))")
        check(parts[2] as? String == "A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: **bold** word\n\nEnd.", "emphasis written there is the note's emphasis (read: \(String(describing: parts[2]).debugDescription))")
        after(50) {
            js("""
                var dismissed = !document.querySelector('.note-popover');
                a.insertFootnoteRef('7');
                var back = a.getContent();
                a.load('A[^1].\\n\\n[^1]: one *two* three');
                [dismissed, back]
                """) { r in
                let parts = r as? [Any] ?? []
                check(parts.first as? Bool == true, "Escape closes it")
                check(parts.last as? String == "A[^1].\n\n[^1]: one\n\nB[^2] and C[^3][^7].\n\n[^2]: two\n[^3]: **bold** word\n\nEnd.", "and the caret is back just after the marker (read: \(String(describing: parts.last).debugDescription))")
                after(600) {
                    js("""
                        press(document.querySelector('sup.footnote-ref'), 'mouse');
                        var em = document.querySelector('.note-popover .ProseMirror em');
                        var drawn = em ? em.textContent : null;
                        a.setFootnoteClicks('jump');
                        a.load(doc);
                        drawn
                        """) { r in
                        check(r as? String == "two", "emphasis shows as emphasis there, as it does in the page (read: \(String(describing: r)))")
                        after(600) {
                            // A marker of its own in a note: the small editor
                            // can't hold it, so the note opens as Markdown.
                            js("""
                                press(document.querySelector('sup.footnote-ref[data-id="3"]'), 'mouse');
                                a.insertFootnoteRef('9');
                                a.setFootnoteClicks('popover');
                                1
                                """) { _ in
                                after(600) {
                                    js("""
                                        press(document.querySelector('sup.footnote-ref[data-id="3"]'), 'mouse');
                                        var field = document.querySelector('.note-popover textarea');
                                        var result = [field ? field.value : null, !!document.querySelector('.note-popover .ProseMirror'), document.querySelector('.note-popover-heading span').textContent];
                                        if (field) field.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true}));
                                        a.setFootnoteClicks('jump');
                                        result
                                        """) { r in
                                        let parts = r as? [Any] ?? []
                                        check(parts.count == 3 && parts[0] as? String == "[^9]three" && parts[1] as? Bool == false, "a note holding a marker opens as its Markdown (read: \(String(describing: r)))")
                                        check(parts.last as? String == "Note 3 · Markdown", "and says so (read: \(String(describing: parts.last)))")
                                        after(600) { addingAndRemoving() }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// A footnote added is one edit, its marker and its note together, there to
// read at once and undone as one; a footnote removed takes both out.
func addingAndRemoving() {
    print("-- adding and removing a footnote")
    let original = "A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: three\n\nEnd."
    js("""
        var a = window.editorAPI;
        a.load(doc); a.focus();
        a.insertFootnote('4', 'four');
        var added = a.getContent();
        \(undo);
        var undone = a.getContent();
        a.setFootnoteClicks('popover');
        a.load(doc); a.focus();
        a.insertFootnote('4', '');
        var panel = document.querySelector('.note-popover');
        var pm = panel && panel.querySelector('.ProseMirror');
        var note = pm ? pm.editor : null;
        // Not focus: the harness's window is never key, so focus never lands.
        var opened = [!!panel, panel ? panel.querySelector('.note-popover-heading span').textContent : null, note ? note.getText() : null];
        if (note) note.commands.insertContent('four');
        var written = a.getContent();
        if (pm) pm.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true, cancelable: true}));
        a.setFootnoteClicks('jump');
        a.load(doc);
        var removed = [a.removeFootnote('2'), a.getContent()];
        \(undo);
        var restored = a.getContent();
        var missing = [a.removeFootnote('nope'), a.getContent()];
        var whole = [a.removeFootnote('1'), a.getContent()];
        [added, undone, opened, written, removed, restored, missing, whole]
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 8 else { check(false, "adding and removing read (read: \(String(describing: r)))"); exit(1) }
        check(parts[0] as? String == "[^4]A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: three\n[^4]: four\n\nEnd.", "a footnote added is in the writing at once, after the last note (read: \(String(describing: parts[0]).debugDescription))")
        check(parts[1] as? String == original, "and one Undo takes out both marker and note (read: \(String(describing: parts[1]).debugDescription))")
        let opened = parts[2] as? [Any] ?? []
        check(opened.count == 3 && opened[0] as? Bool == true && opened[1] as? String == "Note 4" && opened[2] as? String == "", "with notes edited by their markers, a footnote added opens ready to write (read: \(opened))")
        check(parts[3] as? String == "[^4]A[^1].\n\n[^1]: one\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: three\n[^4]: four\n\nEnd.", "and what's written goes into it (read: \(String(describing: parts[3]).debugDescription))")
        let removed = parts[4] as? [Any] ?? []
        check(removed.first as? Bool == true && removed.last as? String == "A[^1].\n\n[^1]: one\n\nB and C[^3].\n\n[^3]: three\n\nEnd.", "a footnote removed takes out its marker and its note (read: \(removed))")
        check(parts[5] as? String == original, "and Undo brings both back (read: \(String(describing: parts[5]).debugDescription))")
        let missing = parts[6] as? [Any] ?? []
        check(missing.first as? Bool == false && missing.last as? String == original, "a footnote that isn't there reports so and changes nothing (read: \(missing))")
        let whole = parts[7] as? [Any] ?? []
        check(whole.first as? Bool == true && whole.last as? String == "A.\n\nB[^2] and C[^3].\n\n[^2]: two\n[^3]: three\n\nEnd.", "the only note in its block takes the block with it (read: \(whole))")
        after(600) {
            js("""
                var a = window.editorAPI;
                a.setFootnoteClicks('popover');
                a.load(doc);
                press(document.querySelector('sup.footnote-ref[data-id="3"]'), 'mouse');
                var button = document.querySelector('.note-popover-remove');
                if (button) button.click();
                var result = [!!button, !document.querySelector('.note-popover'), a.getContent()];
                a.setFootnoteClicks('jump');
                result
                """) { r in
                let parts = r as? [Any] ?? []
                check(parts.first as? Bool == true && (parts.count > 1 && parts[1] as? Bool == true), "the open note's Remove closes it (read: \(String(describing: r)))")
                check(parts.last as? String == "A[^1].\n\n[^1]: one\n\nB[^2] and C.\n\n[^2]: two\n\nEnd.", "and takes the footnote out, marker and note (read: \(String(describing: parts.last).debugDescription))")
                reviewMarksOnALastBlock()
            }
        }
    }
}

// A writing that ends in anything but a paragraph: the page keeps an empty
// paragraph after its last block, which the Markdown does not write, and
// that alone must not turn the marks away. Agents' drafts end in their
// footnotes.
func reviewMarksOnALastBlock() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const endings = {
                heading: ['Text.\\n\\n## Heading', 'Text.\\n\\n## \\uE000Heading\\uE001'],
                quote: ['Text.\\n\\n> A quote.', 'Text.\\n\\n> A \\uE000quote\\uE001.'],
                list: ['Text.\\n\\n- one\\n- two', 'Text.\\n\\n- one\\n- \\uE000two\\uE001'],
                rule: ['Text.\\n\\n---', '\\uE000Text\\uE001.\\n\\n---'],
                footnotes: ['Text[^1].\\n\\n[^1]: Note.', '\\uE000Text\\uE001[^1].\\n\\n[^1]: Note.'],
            };
            const drawn = {};
            for (const [name, [text, marked]] of Object.entries(endings)) {
                rv.load(text);
                drawn[name] = rv.setReviewMarks(marked) === true && document.querySelectorAll('.review-mark').length === 1;
            }
            rv.load('Text.\\n\\n## Heading');
            const other = rv.setReviewMarks('Text.\\n\\n## \\uE000Other\\uE001');
            return [drawn, other]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        let drawn = parts.first as? [String: Bool] ?? [:]
        for name in ["heading", "quote", "list", "rule", "footnotes"] {
            check(drawn[name] == true, "marks are drawn in a writing that ends in \(name == "rule" ? "a rule" : name == "footnotes" ? "its footnotes" : "a " + name) (read: \(String(describing: r)))")
        }
        check(parts.last as? Bool == false, "and a different last block is still not the same document")
        reviewMarksInFootnotes()
    }
}

// What the assistant changed in a writing's footnotes: drawn in the notes'
// words, though the footnote block keeps each note's source beside them and
// a marker before a note's label would stop it being read as a note.
func reviewMarksInFootnotes() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const text = 'Body[^1] and more[^2].\\n\\n[^1]: A first note.\\n[^2]: A second note.';
            const cases = {
                inANote: 'Body[^1] and more[^2].\\n\\n[^1]: A \\uE000first\\uE001 note.\\n[^2]: A second note.',
                atALabel: 'Body[^1] and more[^2].\\n\\n[^1]: A first note.\\n\\uE000[^2]: A second\\uE001 note.',
                closingAtALabel: 'Body[^1] and more[^2].\\n\\n[^1]: A first \\uE000note.\\n\\uE001[^2]: A second note.',
                fromTheBody: 'Body[^1] and \\uE000more[^2].\\n\\n[^1]: A first\\uE001 note.\\n[^2]: A second note.',
            };
            const drawn = {};
            for (const [name, marked] of Object.entries(cases)) {
                rv.load(text);
                const placed = rv.setReviewMarks(marked);
                const marks = Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|');
                drawn[name] = [placed, marks];
            }
            // Written A, B, C; referred to A, C, B, so shown A, C, B. A mark
            // written across A and B covers no word of C.
            const reordered = 'One[^a], two[^c], three[^b].\\n\\n[^a]: Note a.\\n[^b]: Note b.\\n[^c]: Note c.';
            rv.load(reordered);
            const across = rv.setReviewMarks('One[^a], two[^c], three[^b].\\n\\n[^a]: Note \\uE000a.\\n[^b]: Note\\uE001 b.\\n[^c]: Note c.');
            drawn.acrossNotes = [across, Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|')];
            // Notes apart: an end before the second's label goes back past
            // the blank line, not onto it.
            const apart = 'Body[^1] and more[^2].\\n\\n[^1]: A first note.\\n\\n[^2]: A second note.';
            rv.load(apart);
            const spaced = rv.setReviewMarks('Body[^1] and more[^2].\\n\\n[^1]: A first \\uE000note.\\n\\n\\uE001[^2]: A second note.');
            drawn.overABlankLine = [spaced, Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|')];
            // A mark from an italic line into the notes ends inside its
            // stars, which still close; and one ends after a note's label.
            const italic = 'Body[^1].\\n\\n*An italic line.*\\n\\n[^1]: A note.\\n[^2]: Another.';
            rv.load(italic);
            const intoNotes = rv.setReviewMarks('Body[^1].\\n\\n*An \\uE000italic line.*\\n\\n[^1]: A\\uE001 note.\\n[^2]: Another.');
            drawn.fromItalics = [intoNotes, Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|')];
            const afterLabel = rv.setReviewMarks('Body[^1].\\n\\n*An italic line.*\\n\\n[^1]: A \\uE000note.\\n[^2]:\\uE001 Another.');
            drawn.afterALabel = [afterLabel, Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|')];
            rv.load('Text.\\n\\n');
            // A point among the empty paragraphs at the end is not placed
            // past the page's document, nor moved where a clear would take
            // it for the last words; the page holds this text, so it says
            // the mark is missing rather than refusing.
            drawn.pastTheEnd = [rv.setReviewMarks('Text.\\n\\n\\uE002'), String(document.querySelectorAll('.review-point').length)];
            rv.load(text);
            const kept = rv.getContent();
            return [drawn, kept]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        let drawn = parts.first as? [String: [Any]] ?? [:]
        func shown(_ name: String) -> String? { drawn[name]?.last as? String }
        func placed(_ name: String) -> Bool { drawn[name]?.first as? Bool == true }
        check(placed("inANote") && shown("inANote") == "first", "a mark in a note's words is drawn there (read: \(String(describing: drawn["inANote"])))")
        check(placed("atALabel") && shown("atALabel") == "A second", "a mark that begins at a note's label is drawn from its first word (read: \(String(describing: drawn["atALabel"])))")
        check(placed("closingAtALabel") && shown("closingAtALabel") == "note.", "a mark that ends at the next note's label ends with the line before (read: \(String(describing: drawn["closingAtALabel"])))")
        check(placed("fromTheBody") && (shown("fromTheBody") ?? "").hasPrefix("more"), "a mark from the body into a note is drawn (read: \(String(describing: drawn["fromTheBody"])))")
        check(placed("acrossNotes") && shown("acrossNotes") == "a.|Note", "a mark across two notes covers no note shown between them (read: \(String(describing: drawn["acrossNotes"])))")
        check(placed("overABlankLine") && shown("overABlankLine") == "note.", "an end before a note's label, past a blank line, keeps the notes together (read: \(String(describing: drawn["overABlankLine"])))")
        check(placed("fromItalics") && shown("fromItalics") == "italic line.|A", "a mark from an italic line into the notes keeps the italics (read: \(String(describing: drawn["fromItalics"])))")
        check(placed("afterALabel") && shown("afterALabel") == "note.", "an end just after a note's label ends with the note before (read: \(String(describing: drawn["afterALabel"])))")
        check((drawn["pastTheEnd"]?.first as? [String: Any])?["unshown"] as? Int == 1 && shown("pastTheEnd") == "0", "a point past the last words is not placed, nor moved onto them, and is said to be missing (read: \(String(describing: drawn["pastTheEnd"])))")
        check(parts.last as? String == "Body[^1] and more[^2].\n\n[^1]: A first note.\n[^2]: A second note.", "and the writing is unchanged (read: \(String(describing: parts.last)))")
        reviewMarksLeavingNotes()
    }
}

// Return on the clear button, focused from the keyboard, is the button's:
// the editor's keymap does not split the block under it, and the press
// that follows clears.
func keyboardClear() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('Keys deux here.');
            rv.setReviewMarks('Keys \\uE000deux\\uE001 here.');
            rv.focus();
            const button = document.querySelector('.review-clear');
            button.focus();
            const press = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
            button.dispatchEvent(press);
            const kept = rv.getContent();
            button.click();
            return [press.defaultPrevented, kept]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        check(parts.first as? Bool == false && parts.last as? String == "Keys deux here.",
              "Return on a focused clear button leaves the text alone and is not taken from it (read: \(String(describing: r)))")
        after(200) {
            check(probe.reviewClears.last == "\u{E000}Keys deux here.\u{E001}", "and the press clears (read: \(probe.reviewClears))")
            autolinkClear()
        }
    }
}

// A clear for a block that ends in an autolink: the markers are text of
// their own, so the link keeps its address as its text, and the marked
// Markdown is the page's own with the markers in it, which the host can
// map; the page's text comes with it.
func autolinkClear() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('Read <https://example.com>');
            const plain = rv.getContent();
            rv.setReviewMarks('\\uE000Read\\uE001 ' + plain.slice(5));
            document.querySelector('.review-clear').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
            return plain
        })()
        """) { r in
        let plain = r as? String ?? ""
        after(200) {
            let marked = probe.reviewClears.last ?? ""
            let unmarked = marked.filter { $0 != "\u{E000}" && $0 != "\u{E001}" && $0 != "\u{E002}" }
            check(!plain.isEmpty && marked.contains("\u{E000}") && marked.contains("\u{E001}") && unmarked == plain && !marked.contains("]("),
                  "an autolink at a block's edge stays as the page writes it under the clear's markers (read: \(marked.debugDescription), page \(plain.debugDescription))")
            check(probe.reviewClearTexts.last == plain, "and the clear brings the page's text (read: \(probe.reviewClearTexts.last.debugDescription))")
            linkSelectionClear()
        }
    }
}

// Markers around links, as the page writes them: for a caret, a selection
// and a ✓ inside an autolink, a ✓ on a paragraph that starts and ends with
// one, and a selection inside a named link, the marked Markdown less its
// markers is the page's own text, and the link is written once, as it was.
let linkCases: [(name: String, markdown: String, select: String?, clear: Bool)] = [
    ("a caret inside an autolink", "See <https://example.org> now.", "", false),
    ("a selection inside an autolink", "See <https://example.org> now.", "example", false),
    ("a ✓ beside an autolink", "See <https://example.org> now.", nil, true),
    ("a ✓ on a paragraph that starts and ends with an autolink", "<https://example.org> and <https://example.net>", nil, true),
    ("a selection inside a named link", "See [alpha beta gamma](https://example.com) now.", "beta", false),
]

// A caret just after a link's label: the whole link is taken, so the
// markers go round its Markdown, where the label is, not after its address.
func linkEdgeCaretClear() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('See [dog](https://example.com) now.');
            rv.setReviewMarks('See [\\uE000dog\\uE001](https://example.com) now.');
            rv.focus();
            return true
        })()
        """) { _ in
        after(100) {
            js("""
                (() => { try {
                    const anchor = document.querySelector('.ProseMirror a');
                    const walker = document.createTreeWalker(anchor, NodeFilter.SHOW_TEXT);
                    let text;
                    while ((text = walker.nextNode()) && text.textContent !== 'dog') {}
                    const range = document.createRange();
                    range.setStart(text, 2);
                    range.setEnd(text, 3);
                    const selection = window.getSelection();
                    selection.removeAllRanges();
                    selection.addRange(range);
                    selection.collapseToEnd();
                    return true
                } catch (e) { return 'error: ' + e.message } })()
                """) { r in
                after(150) {
                    js("window.editorAPI.reviewMarkdownForSelection()") { page in
                        let marked = (page as? [String: Any])?["markdown"] as? String ?? ""
                        check(marked == "See \u{E000}[dog](https://example.com)\u{E001} now.",
                              "a caret just after a link's label takes the whole link (read: \(marked.replacingOccurrences(of: "\u{E000}", with: "<S>").replacingOccurrences(of: "\u{E001}", with: "<E>")), \(String(describing: r)))")
                        boldCaretClear()
                    }
                }
            }
        }
    }
}

func linkSelectionClear(_ index: Int = 0) {
    guard index < linkCases.count else { return linkEdgeCaretClear() }
    let item = linkCases[index]
    let quoted = item.markdown.replacingOccurrences(of: "'", with: "\\'")
    let select = item.select.map { "'\($0)'" } ?? "null"
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('\(quoted)');
            const plain = rv.getContent();
            rv.setReviewMarks('\\uE000' + plain + '\\uE001');
            rv.focus();
            const select = \(select);
            if (select !== null) {
                const walker = document.createTreeWalker(document.querySelector('.ProseMirror'), NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode()) && !node.textContent.includes(select || 'example')) {}
                if (!node) return [plain, false];
                const at = node.textContent.indexOf(select || 'example') + (select ? 0 : 3);
                const range = document.createRange();
                range.setStart(node, at);
                range.setEnd(node, at + select.length);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
            }
            if (\(item.clear ? "true" : "false")) {
                document.querySelector('.review-clear').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
            }
            return [plain, true]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        let plain = parts.first as? String ?? ""
        let read: (@escaping (String, String) -> Void) -> Void = { done in
            if item.clear {
                after(200) { done(probe.reviewClears.last ?? "", probe.reviewClearTexts.last ?? "") }
            } else {
                after(150) {
                    js("window.editorAPI.reviewMarkdownForSelection()") { r in
                        let page = r as? [String: Any]
                        done(page?["markdown"] as? String ?? "", page?["plain"] as? String ?? "")
                    }
                }
            }
        }
        read { marked, sent in
            let unmarked = marked.filter { $0 != "\u{E000}" && $0 != "\u{E001}" && $0 != "\u{E002}" }
            let markers = marked.filter { $0 == "\u{E000}" || $0 == "\u{E001}" || $0 == "\u{E002}" }.count
            check(parts.last as? Bool == true && !plain.isEmpty && markers >= 1 && unmarked == plain && sent == plain,
                  "\(item.name): the marked Markdown less its markers is the page's text (read: \(marked.debugDescription), page \(plain.debugDescription))")
            linkSelectionClear(index + 1)
        }
    }
}

// A caret just after a bold word the assistant changed: its markers stay
// inside the `**`, where the mark is, as typing there would, so Mark
// Selection clears it.
func boldCaretClear() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('One **dog** more');
            rv.setReviewMarks('One **\\uE000dog\\uE001** more');
            rv.focus();
            return true
        })()
        """) { _ in
        after(100) {
            js("""
                (() => { try {
                    const strong = document.querySelector('.ProseMirror strong');
                    if (!strong) return 'no strong';
                    // The mark's own span may wrap the word: the text itself.
                    const walker = document.createTreeWalker(strong, NodeFilter.SHOW_TEXT);
                    let text;
                    while ((text = walker.nextNode()) && text.textContent !== 'dog') {}
                    if (!text) return 'no text';
                    const range = document.createRange();
                    range.setStart(text, 2);
                    range.setEnd(text, 3);
                    const selection = window.getSelection();
                    selection.removeAllRanges();
                    selection.addRange(range);
                    selection.collapseToEnd();
                    return strong.outerHTML
                } catch (e) { return 'error: ' + e.message } })()
                """) { r in
                after(150) {
                    js("window.editorAPI.reviewMarkdownForSelection()") { page in
                        let marked = (page as? [String: Any])?["markdown"] as? String ?? ""
                        check(marked == "One **dog\u{E000}\u{E001}** more",
                              "a caret just after a bold word stays inside its markup (read: \(marked.replacingOccurrences(of: "\u{E000}", with: "<S>").replacingOccurrences(of: "\u{E001}", with: "<E>")), \(String(describing: r)))")
                        pageTextCases()
                    }
                }
            }
        }
    }
}

// More selections whose marked Markdown, less its markers, must be the
// page's text: a caret in a formatted link's label, whose markers go round
// the link outside its `**`; and a selection in a table cell that runs into
// its trailing breaks, which the page leaves off.
let pageTextSelections: [(name: String, markdown: String, select: String)] = [
    ("a caret in a bold link's label", "one [**alpha beta**](https://example.org) three", """
        (() => {
            const strong = document.querySelector('.ProseMirror a strong') || document.querySelector('.ProseMirror strong');
            const walker = document.createTreeWalker(strong, NodeFilter.SHOW_TEXT);
            let text;
            while ((text = walker.nextNode()) && !text.textContent.includes('alpha')) {}
            const range = document.createRange();
            range.setStart(text, 2);
            range.setEnd(text, 2);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true
        })()
        """),
    ("a caret in an italic link's label", "one [*alpha beta*](https://example.org) three", """
        (() => {
            const em = document.querySelector('.ProseMirror em');
            const walker = document.createTreeWalker(em, NodeFilter.SHOW_TEXT);
            let text;
            while ((text = walker.nextNode()) && !text.textContent.includes('alpha')) {}
            const range = document.createRange();
            range.setStart(text, 2);
            range.setEnd(text, 2);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true
        })()
        """),
    ("a caret in a link that emphasis encloses", "***abc [label](https://example.org)***!", """
        (() => {
            const anchor = document.querySelector('.ProseMirror a');
            const walker = document.createTreeWalker(anchor, NodeFilter.SHOW_TEXT);
            let text;
            while ((text = walker.nextNode()) && !text.textContent.includes('label')) {}
            const range = document.createRange();
            range.setStart(text, 2);
            range.setEnd(text, 2);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true
        })()
        """),
    ("a caret in a link followed by a bold break", "[label](https://example.org)<strong><br></strong>more", """
        (() => {
            const anchor = document.querySelector('.ProseMirror a');
            const walker = document.createTreeWalker(anchor, NodeFilter.SHOW_TEXT);
            let text;
            while ((text = walker.nextNode()) && !text.textContent.includes('label')) {}
            const range = document.createRange();
            range.setStart(text, 2);
            range.setEnd(text, 2);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true
        })()
        """),
    ("a selection from a bold link into bold text after it", "left [**alpha**](https://example.org)**right**", """
        (() => {
            const anchor = document.querySelector('.ProseMirror a');
            const walker = document.createTreeWalker(anchor.parentNode.closest('p') || anchor.parentNode, NodeFilter.SHOW_TEXT);
            let start, end;
            for (let text; (text = walker.nextNode());) {
                if (!start && text.textContent.includes('alpha')) start = text;
                if (text.textContent.includes('right')) end = text;
            }
            if (!start || !end) return 'missing text';
            const range = document.createRange();
            range.setStart(start, 2);
            range.setEnd(end, end.textContent.length);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true
        })()
        """),
    ("a selection into a table cell's trailing breaks", "| head |\n| --- |\n| alpha beta<br><br> |", """
        (() => {
            const cells = document.querySelectorAll('.ProseMirror td');
            const cell = cells[cells.length - 1];
            if (!cell) return 'no cell';
            const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
            let text;
            while ((text = walker.nextNode()) && !text.textContent.includes('alpha')) {}
            const br = cell.querySelector('br');
            if (!text || !br) return 'no text or break: ' + cell.innerHTML;
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEndAfter(br);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true
        })()
        """),
]

func pageTextCases(_ index: Int = 0) {
    guard index < pageTextSelections.count else { return longManuscriptClear() }
    let item = pageTextSelections[index]
    let quoted = item.markdown.replacingOccurrences(of: "\n", with: "\\n")
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('\(quoted)');
            const plain = rv.getContent();
            rv.setReviewMarks('\\uE000' + plain + '\\uE001');
            rv.focus();
            return plain
        })()
        """) { p in
        let plain = p as? String ?? ""
        after(100) {
            js(item.select) { r in
                after(150) {
                    js("window.editorAPI.reviewMarkdownForSelection()") { page in
                        let marked = (page as? [String: Any])?["markdown"] as? String ?? ""
                        let unmarked = marked.filter { $0 != "\u{E000}" && $0 != "\u{E001}" && $0 != "\u{E002}" }
                        let shown = marked.replacingOccurrences(of: "\u{E000}", with: "<S>").replacingOccurrences(of: "\u{E001}", with: "<E>")
                        check(r as? Bool == true && !plain.isEmpty && marked.contains("\u{E000}") && unmarked == plain,
                              "\(item.name): the marked Markdown less its markers is the page's text (read: \(shown.debugDescription), page \(plain.debugDescription), \(String(describing: r)))")
                        pageTextCases(index + 1)
                    }
                }
            }
        }
    }
}

// A clear in a book-length writing, at the formatting that takes the most
// tries: the tries are made on the block the markers are in, and the whole
// written once to check, so the page doesn't stop for seconds.
func longManuscriptClear() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            const words = 'and the shepherd calls his own sheep by name and leads them out when he has brought out all his own he goes before them and the sheep follow him for they know his voice';
            const paragraphs = [];
            for (let index = 0; index < 2000; index++) paragraphs.push('Paragraph ' + index + ' ' + words + ' ' + words);
            paragraphs.push('<strong>left </strong><a href="https://example.org"><em>middle</em></a><strong><em> right</em></strong>');
            rv.load(paragraphs.join('\\n\\n'));
            rv.focus();
            return rv.getContent().length
        })()
        """) { _ in
        after(300) {
            js("""
                (() => {
                    const anchor = Array.from(document.querySelectorAll('.ProseMirror a')).pop();
                    const walker = document.createTreeWalker(anchor, NodeFilter.SHOW_TEXT);
                    let text;
                    while ((text = walker.nextNode()) && !text.textContent.includes('middle')) {}
                    const range = document.createRange();
                    range.setStart(text, 3);
                    range.setEnd(text, 3);
                    const selection = window.getSelection();
                    selection.removeAllRanges();
                    selection.addRange(range);
                    return true
                })()
                """) { _ in
                after(200) {
                    js("""
                        (() => {
                            const once = performance.now();
                            const plain = window.editorAPI.getContent();
                            const written = performance.now() - once;
                            const started = performance.now();
                            const page = window.editorAPI.reviewMarkdownForSelection();
                            const took = performance.now() - started;
                            const unmarked = page.markdown.replace(/[\\uE000\\uE001\\uE002]/g, '');
                            return [took, unmarked === plain, page.markdown.includes('\\uE000'), written]
                        })()
                        """) { r in
                        let parts = r as? [Any] ?? []
                        let took = parts.first as? Double ?? -1
                        let written = parts.count > 3 ? parts[3] as? Double ?? -1 : -1
                        print("  a clear in 2,000 paragraphs took \(Int(took)) ms; writing the whole once takes \(Int(written)) ms")
                        check(parts.count == 4 && parts[1] as? Bool == true && parts[2] as? Bool == true,
                              "a clear in a book-length writing maps to the page's text (read: \(String(describing: r)))")
                        check(took >= 0 && written > 0 && took < written * 3.5 + 150,
                              "and costs a few writings of the whole, not one for each try (\(Int(took)) ms against \(Int(written)) ms for one)")
                        longListClears()
                    }
                }
            }
        }
    }
}

// Clears in a list as long as a book, numbered and bulleted, plain and in
// the formatting that takes the most tries: never dearer than trying each
// choice on the whole, and the marked Markdown is the page's.
let longLists: [(name: String, item: String, last: String, word: String)] = [
    ("a numbered list", "1. ", "four plain words here", "plain"),
    ("a numbered list, mixed formatting", "1. ", "<strong>left </strong><a href=\"https://example.org\"><em>middle</em></a><strong><em> right</em></strong>", "middle"),
    ("a bulleted list, mixed formatting", "- ", "<strong>left </strong><a href=\"https://example.org\"><em>middle</em></a><strong><em> right</em></strong>", "middle"),
]

func longListClears(_ index: Int = 0) {
    guard index < longLists.count else { return restoreButton() }
    let item = longLists[index]
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            const words = 'and the shepherd calls his own sheep by name and leads them out when he has brought out all his own he goes before them';
            const items = [];
            for (let index = 0; index < 2000; index++) items.push('\(item.item)Item ' + index + ' ' + words);
            items.push('\(item.item)' + '\(item.last.replacingOccurrences(of: "'", with: "\\'"))');
            rv.load(items.join('\\n'));
            rv.focus();
            return true
        })()
        """) { _ in
        after(300) {
            js("""
                (() => {
                    const items = document.querySelectorAll('.ProseMirror li');
                    const last = items[items.length - 1];
                    const walker = document.createTreeWalker(last, NodeFilter.SHOW_TEXT);
                    let text;
                    while ((text = walker.nextNode()) && !text.textContent.includes('\(item.word)')) {}
                    if (!text) return 'no text';
                    const at = text.textContent.indexOf('\(item.word)');
                    const range = document.createRange();
                    range.setStart(text, at + 1);
                    range.setEnd(text, at + 3);
                    const selection = window.getSelection();
                    selection.removeAllRanges();
                    selection.addRange(range);
                    return true
                })()
                """) { selected in
                after(200) {
                    js("""
                        (() => {
                            const once = performance.now();
                            const plain = window.editorAPI.getContent();
                            const written = performance.now() - once;
                            const started = performance.now();
                            const page = window.editorAPI.reviewMarkdownForSelection();
                            const took = performance.now() - started;
                            const unmarked = page.markdown.replace(/[\\uE000\\uE001\\uE002]/g, '');
                            return [took, unmarked === plain, page.markdown.includes('\\uE000'), written]
                        })()
                        """) { r in
                        let parts = r as? [Any] ?? []
                        let took = parts.first as? Double ?? -1
                        let written = parts.count > 3 ? parts[3] as? Double ?? -1 : -1
                        print("  a clear in \(item.name) of 2,000 items took \(Int(took)) ms; writing the whole once takes \(Int(written)) ms")
                        check(selected as? Bool == true && parts.count == 4 && parts[1] as? Bool == true && parts[2] as? Bool == true,
                              "a clear in \(item.name) of 2,000 items maps to the page's text (read: \(String(describing: r)))")
                        check(took >= 0 && written > 0 && took < written * 3.5 + 150,
                              "and costs a few writings of the whole (\(Int(took)) ms against \(Int(written)) ms for one)")
                        longListClears(index + 1)
                    }
                }
            }
        }
    }
}

// Codex's second round on footnote marks: a mark out of the notes into the
// body, markers among a note's indent, an escaped star where a mark is
// ended, and the clear button beside a footnote block.
func reviewMarksLeavingNotes() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const marks = () => Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|');
            const drawn = {};
            const mid = 'One[^a], two[^c], three[^b].\\n\\n[^a]: Note a.\\n[^b]: Note b.\\n[^c]: Note c.\\n\\nAfter the notes.';
            rv.load(mid);
            drawn.intoTheBody = [rv.setReviewMarks('One[^a], two[^c], three[^b].\\n\\n[^a]: Note a.\\n[^b]: Note b.\\n[^c]: Note \\uE000c.\\n\\nAfter\\uE001 the notes.'), marks()];
            const indented = 'Body[^a].\\n\\n  [^a]: First line\\n    second line.';
            rv.load(indented);
            drawn.inTheIndent = [rv.setReviewMarks('Body[^a].\\n\\n \\uE000 [^a]: First\\uE001 line\\n\\uE002    second line.'), marks()];
            const escaped = 'Body[^1] with literal\\\\*\\n\\n[^1]: A note.';
            rv.load(escaped);
            drawn.escapedStar = [rv.setReviewMarks('Body[^1] with \\uE000literal\\\\*\\n\\n[^1]: A\\uE001 note.'), marks()];
            const notes = 'Body[^1] and more[^2].\\n\\n[^1]: A first note.\\n[^2]: A second note.';
            rv.setMode('edit');
            rv.load(notes);
            rv.setReviewMarks('Body[^1] and more[^2].\\n\\n[^1]: A \\uE000first\\uE001 note.\\n[^2]: A second note.');
            const buttons = document.querySelectorAll('.review-clear');
            const button = buttons[buttons.length - 1];
            if (button) button.click();
            return [drawn, buttons.length]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        let drawn = parts.first as? [String: [Any]] ?? [:]
        func shown(_ name: String) -> String? { drawn[name]?.last as? String }
        func placed(_ name: String) -> Bool { drawn[name]?.first as? Bool == true }
        check(placed("intoTheBody") && shown("intoTheBody") == "c.|After", "a mark out of the notes into the body covers no note between (read: \(String(describing: drawn["intoTheBody"])))")
        check(placed("inTheIndent"), "markers among a note's indent leave it a note (read: \(String(describing: drawn["inTheIndent"])))")
        check(placed("escapedStar") && (shown("escapedStar") ?? "").hasPrefix("literal*"), "a mark ended after an escaped star keeps it escaped (read: \(String(describing: drawn["escapedStar"])))")
        after(200) {
            let sent = probe.reviewClears.last ?? ""
            let plain = sent.replacingOccurrences(of: "\u{E000}", with: "").replacingOccurrences(of: "\u{E001}", with: "")
            check(plain == "Body[^1] and more[^2].\n\n[^1]: A first note.\n[^2]: A second note." && sent.contains("[^1]: \u{E000}"),
                  "the clear beside a footnote block sends every note, the mark from the first note's words (read: \(sent.debugDescription))")
            reviewMarksRareSyntax()
        }
    }
}

// Codex's third round: a mark out of the notes into syntax it cannot stand
// before, markers alone on a blank line among notes, italics over two lines,
// and a selection of nothing but a note's number.
func reviewMarksRareSyntax() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const marks = () => Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|');
            const drawn = {};
            const ending = (name, body, markedBody) => {
                const text = 'One[^a].\\n\\n[^a]: Note a.\\n\\n' + body;
                rv.load(text);
                drawn[name] = [rv.setReviewMarks('One[^a].\\n\\n[^a]: Note \\uE000a.\\n\\n' + markedBody), marks()];
            };
            ending('nestedQuote', '>  > Nested quote.', '>  > Nested\\uE001 quote.');
            ending('fence', '```\\ncode line\\n```\\n\\nAfter.', '```\\ncode\\uE001 line\\n```\\n\\nAfter.');
            ending('table', '| A | B |\\n|---|---|\\n| 1 | 2 |', '| A\\uE001 | B |\\n|---|---|\\n| 1 | 2 |');
            const notes = 'Body[^1] and more[^2].\\n\\n[^1]: A first note.\\n\\n[^2]: Another.';
            rv.load(notes);
            drawn.pointAlone = [rv.setReviewMarks('Body[^1] and more[^2].\\n\\n[^1]: A first note.\\n\\uE002\\n[^2]: Another.'), document.querySelectorAll('.review-point').length];
            const continued = 'Body[^1].\\n\\n[^1]: A first note\\n\\n    carried on.';
            rv.load(continued);
            drawn.beforeIndent = [rv.setReviewMarks('Body[^1].\\n\\n[^1]: A first note\\n\\uE002    \\n    carried on.'.replace('\\uE002    \\n', '\\uE002\\n')), document.querySelectorAll('.review-point').length];
            const italics = 'Body[^1].\\n\\n*First\\nlast.*\\n\\n[^1]: A note.';
            rv.load(italics);
            drawn.italicsOverLines = [rv.setReviewMarks('Body[^1].\\n\\n*First\\n\\uE000last.*\\n\\n[^1]: A\\uE001 note.'), marks()];
            // A selection of nothing but a note's number.
            rv.setMode('edit');
            rv.load(notes);
            rv.setReviewMarks('Body[^1] and more[^2].\\n\\n[^1]: A \\uE000first\\uE001 note.\\n[^2]: Another.');
            const block = document.querySelector('.footnote-definition');
            const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
            let node = walker.nextNode();
            while (node && !node.textContent.includes('[1]')) node = walker.nextNode();
            const range = document.createRange();
            const at = node ? node.textContent.indexOf('[1]') : 0;
            if (node) { range.setStart(node, at); range.setEnd(node, at + 3); }
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return [drawn, !!node]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        let drawn = parts.first as? [String: [Any]] ?? [:]
        func shown(_ name: String) -> String? { drawn[name]?.last as? String }
        func placed(_ name: String) -> Bool { drawn[name]?.first as? Bool == true }
        check(placed("nestedQuote") && shown("nestedQuote") == "a.|Nested", "a mark out of the notes into a nested quote (read: \(String(describing: drawn["nestedQuote"])))")
        check(placed("fence") && (shown("fence") ?? "").hasPrefix("a.|code"), "a mark out of the notes into a code fence (read: \(String(describing: drawn["fence"])))")
        check(placed("table") && shown("table") == "a.|A", "a mark out of the notes into a table (read: \(String(describing: drawn["table"])))")
        check(placed("pointAlone"), "a point alone on the blank line between notes leaves them one run (read: \(String(describing: drawn["pointAlone"])))")
        check(placed("beforeIndent"), "a point on a blank line inside a note leaves it a note (read: \(String(describing: drawn["beforeIndent"])))")
        check(placed("italicsOverLines") && shown("italicsOverLines") == "last.|A", "a mark from italics over two lines into a note keeps the italics (read: \(String(describing: drawn["italicsOverLines"])))")
        after(150) {
            js("window.editorAPI.reviewMarkdownForSelection()") { r in
                check(r == nil || r is NSNull, "a selection of nothing but a note's number clears nothing (read: \(String(describing: r)))")
                reviewMarksBesideEmphasis()
            }
        }
    }
}

// Codex's fourth round: a marker carried onto emphasis or into a table cell
// that opens with it, a point in an empty code block, a mark begun and
// ended on blank lines, and a caret inside a note's number.
func reviewMarksBesideEmphasis() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const marks = () => Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|');
            const points = () => document.querySelectorAll('.review-point').length;
            const drawn = {};
            rv.setMode('read');
            rv.load('First.\\n\\n_Quoted words._');
            drawn.beforeItalics = [rv.setReviewMarks('First.\\n\\uE002\\n_Quoted words._'), String(points())];
            rv.load('One[^a].\\n\\n[^a]: Note a.\\n\\n| _A_ | B |\\n|---|---|\\n| 1 | 2 |');
            drawn.intoAnItalicCell = [rv.setReviewMarks('One[^a].\\n\\n[^a]: Note \\uE000a.\\n\\n| _A\\uE001_ | B |\\n|---|---|\\n| 1 | 2 |'), marks()];
            rv.load('Before.\\n\\n~~~\\n\\n~~~\\n\\nAfter.');
            drawn.emptyFence = [rv.setReviewMarks('Before.\\n\\n~~~\\n\\uE002\\n~~~\\n\\nAfter.'), String(points())];
            rv.load('First.\\n\\nLast.');
            drawn.emptyMark = [rv.setReviewMarks('First.\\n\\uE000\\n\\uE001\\nLast.'), marks()];
            rv.setMode('edit');
            const notes = 'Body[^1] and more[^2].\\n\\n[^1]: A first note.\\n[^2]: Another.';
            rv.load(notes);
            rv.setReviewMarks('Body[^1] and more[^2].\\n\\n[^1]: \\uE000A\\uE001 first note.\\n[^2]: Another.');
            const block = document.querySelector('.footnote-definition');
            const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
            let node = walker.nextNode();
            while (node && !node.textContent.includes('[1]')) node = walker.nextNode();
            const range = document.createRange();
            const at = node ? node.textContent.indexOf('[1]') + 1 : 0;
            if (node) { range.setStart(node, at); range.setEnd(node, at); }
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return drawn
        })()
        """) { r in
        let drawn = r as? [String: [Any]] ?? [:]
        func shown(_ name: String) -> String? { drawn[name]?.last as? String }
        func placed(_ name: String) -> Bool { drawn[name]?.first as? Bool == true }
        check(placed("beforeItalics") && shown("beforeItalics") == "1", "a point before an italic paragraph leaves it italic (read: \(String(describing: drawn["beforeItalics"])))")
        check(placed("intoAnItalicCell") && shown("intoAnItalicCell") == "a.|A", "a mark out of the notes into a table cell that opens in italics (read: \(String(describing: drawn["intoAnItalicCell"])))")
        check(placed("emptyFence") && shown("emptyFence") == "1", "a point in an empty code block stays there (read: \(String(describing: drawn["emptyFence"])))")
        check(placed("emptyMark") && shown("emptyMark") == "", "a mark begun and ended on blank lines marks nothing (read: \(String(describing: drawn["emptyMark"])))")
        after(150) {
            js("window.editorAPI.reviewMarkdownForSelection()") { r in
                check(r == nil || r is NSNull, "a caret inside a note's number clears nothing (read: \(String(describing: r)))")
                reviewMarksInGroups()
            }
        }
    }
}

// Marks drawn as the writer reads them: a paragraph the assistant went over
// word by word, many marks with a space between each, is one wash; three
// turns that each took words out at one place are one bar, and none where a
// wash reaches it; a place apart from any wash keeps its bar.
func reviewMarksDrawnAsRead() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('read');
            rv.load('One two three four five.\\n\\nSix seven eight.\\n\\nNine ten.');
            const placed = rv.setReviewMarks('\\uE000One\\uE001 \\uE000two\\uE001 \\uE000three\\uE001 \\uE000four five\\uE001.\\n\\n\\uE002\\uE002\\uE002\\uE000Six\\uE001 seven \\uE000eight\\uE001.\\n\\nNine\\uE002\\uE002 ten.', []);
            const washes = Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent);
            return [placed, washes.join('|'), document.querySelectorAll('.review-point').length]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        check(parts.count == 3 && parts[1] as? String == "One two three four five|Six|eight",
              "a paragraph marked word by word is drawn as one wash, broken only by unmarked words (read: \(String(describing: r)))")
        check(parts.count == 3 && parts[2] as? Int == 1, "places words were taken out are drawn once, and not where a wash reaches them (read: \(String(describing: r)))")
        reviewMarksTraced()
    }
}

// Codex's review of the traced placement (1a85e77): each case it found.
func reviewMarksTraced() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const marks = () => Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|');
            const found = {};
            // Emphasis inside a word, in a note.
            rv.setMode('read');
            rv.load('Body[^a].\\n\\n[^a]: An un*happy* note.\\n[^b]: Next.');
            found.inWordEmphasis = [rv.setReviewMarks('Body[^a].\\n\\n[^a]: An un*\\uE000happy\\uE001* note.\\n[^b]: Next.', []), marks()];
            // The writer's own escape of a `!` before a link, which the page
            // now asks of the last characters rather than the whole output.
            rv.load('Wow\\\\![a link](https://example.com) here.');
            found.bangBeforeLink = [true, rv.getContent()];
            // A page behind the host: the host has words the page lacks.
            rv.load('one');
            found.pageBehind = [rv.setReviewMarks('one \\uE000two\\uE001', []), marks()];
            // Clears, while editing.
            rv.setMode('edit');
            rv.load('first\\n\\nsecond');
            rv.setReviewMarks('\\uE000first\\uE001\\n\\nsecond', []);
            return found
        })()
        """) { r in
        let found = r as? [String: [Any]] ?? [:]
        func shown(_ name: String) -> String? { found[name]?.last as? String }
        check(found["inWordEmphasis"]?.first as? Bool == true && shown("inWordEmphasis") == "happy", "a mark on part of a word, emphasised in a note, is drawn on that part (read: \(String(describing: found["inWordEmphasis"])))")
        check(shown("bangBeforeLink") == "Wow\\![a link](https://example.com) here.", "a `!` before a link is still written escaped (read: \(String(describing: found["bangBeforeLink"])))")
        check(found["pageBehind"]?.first as? Bool == false, "a page holding less than the host's text is refused (read: \(String(describing: found["pageBehind"])))")
        // A caret at the start of the second paragraph.
        js("""
            (() => {
                const paragraphs = document.querySelectorAll('.ProseMirror > p');
                const text = paragraphs[1].firstChild;
                const range = document.createRange();
                range.setStart(text, 0);
                range.collapse(true);
                const selection = window.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
                document.dispatchEvent(new Event('selectionchange'));
                return true
            })()
            """) { _ in
            after(150) {
                js("window.editorAPI.reviewMarkdownForSelection()") { r in
                    let marked = (r as? [String: Any])?["markdown"] as? String ?? ""
                    check(marked == "first\n\n\u{E000}\u{E001}second", "a caret at a paragraph's start is not the end of the one before (read: \(marked.debugDescription))")
                    // A link whose address alone was changed, cleared from its ✓.
                    js("""
                        (() => {
                            const rv = window.editorAPI;
                            rv.load('See [link](https://new.example) now.');
                            rv.setReviewMarks('See [link](https://\\uE000new\\uE001.example) now.', []);
                            document.querySelector('.review-clear').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
                            return true
                        })()
                        """) { _ in
                        after(150) {
                            let sent = probe.reviewClears.last ?? ""
                            check(sent == "\u{E000}See [link](https://new.example) now.\u{E001}", "a block's clear takes in a link's address at its end (read: \(sent.debugDescription))")
                            reviewMarksOnBlocksAndPresses()
                        }
                    }
                }
            }
        }
    }
}

// A rule the assistant put in, which has no words: washed whole, with a clear
// beside it that clears the `---`. And a clear pressed with no pointer, as an
// accessibility press sends it, a click with a count of 1 and no pointerdown.
func reviewMarksOnBlocksAndPresses() {
    let before = probe.reviewClears.count
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('Above.\\n\\n---\\n\\nBelow.');
            const placed = rv.setReviewMarks('Above.\\n\\n\\uE000---\\uE001\\n\\nBelow.', []);
            const block = document.querySelectorAll('.review-mark-block').length;
            const clears = document.querySelectorAll('.review-clear');
            if (clears[0]) clears[0].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, detail: 1 }));
            return [placed, block, clears.length]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        check(parts.count == 3 && parts[0] as? Bool == true && parts[1] as? Int == 1 && parts[2] as? Int == 1,
              "a rule the assistant put in is washed whole, with a clear beside it (read: \(String(describing: r)))")
        after(150) {
            let sent = probe.reviewClears.count > before ? probe.reviewClears.last ?? "" : ""
            check(sent == "Above.\n\n\u{E000}---\u{E001}\n\nBelow.", "and a press with no pointer before it clears the rule (read: \(sent.debugDescription))")
            reviewMarksAroundBlocks()
        }
    }
}

// Blocks with no text, around edits: a rule's clear found where the rule is
// now, a point at the edge of what typing redraws keeping its buttons, and
// two rules in one change each marked.
func reviewMarksAroundBlocks() {
    let before = probe.reviewClears.count
    js("""
        (() => {
            const rv = window.editorAPI;
            const ed = () => document.querySelector('.ProseMirror').editor;
            rv.setMode('edit');
            // Typing above a marked rule moves it; its clear goes with it.
            rv.load('A\\n\\nB\\n\\n---');
            rv.setReviewMarks('\\uE000A\\uE001\\n\\nB\\n\\n\\uE000---\\uE001', []);
            ed().commands.insertContentAt(1, 'xxxxx');
            const clears = document.querySelectorAll('.review-clear');
            clears[clears.length - 1]?.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
            // A place words were taken out, just before a rule, kept with
            // its buttons when the paragraph above is typed in.
            rv.load('A\\n\\n---\\n\\nB');
            const pointPlaced = rv.setReviewMarks('A\\n\\n\\uE002---\\n\\nB', []);
            const buttonsBefore = document.querySelectorAll('.review-clear').length;
            ed().commands.insertContentAt(2, 'y');
            const buttonsAfter = document.querySelectorAll('.review-clear').length;
            // The same just after the rule.
            rv.load('A\\n\\n---\\n\\nB');
            rv.setReviewMarks('A\\n\\n---\\uE002\\n\\nB', []);
            const afterRuleBefore = document.querySelectorAll('.review-clear').length;
            ed().commands.insertContentAt(2, 'y');
            const afterRuleAfter = document.querySelectorAll('.review-clear').length;
            // A change from a rule into a paragraph keeps one restore, on
            // its first block, when the rule after the first is deleted
            // and the paragraph typed in: what a full redraw draws.
            rv.load('---\\n\\n---\\n\\nABC');
            rv.setReviewMarks('---\\n\\n\\uE000---\\n\\nAB\\uE001C', [{ id: 'r', now: '---\\n\\nAB', before: 'Old' }]);
            ed().commands.deleteRange({ from: 1, to: 2 });
            ed().commands.insertContentAt(4, 'x');
            const restoresTyped = document.querySelectorAll('.review-restore').length;
            rv.goToReviewMark(true);
            const restoresWhole = document.querySelectorAll('.review-restore').length;
            // Two rules the assistant put in at once.
            rv.load('Above.\\n\\n---\\n\\n---\\n\\nBelow.');
            rv.setReviewMarks('Above.\\n\\n\\uE000---\\n\\n---\\uE001\\n\\nBelow.', []);
            const rules = document.querySelectorAll('.review-mark-block').length;
            return [pointPlaced, buttonsBefore, buttonsAfter, rules, afterRuleBefore, afterRuleAfter, restoresTyped, restoresWhole]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 8 else { check(false, "blocks around edits read (read: \(String(describing: r)))"); exit(1) }
        check(parts[0] as? Bool == true && (parts[1] as? Int ?? 0) >= 1 && parts[2] as? Int == parts[1] as? Int,
              "a place taken out just before a rule keeps its buttons when the block above is typed in (read: \(parts[0]), \(parts[1]) then \(parts[2]))")
        check(parts[3] as? Int == 2, "two rules put in at once are each marked (read: \(parts[3]))")
        check((parts[4] as? Int ?? 0) >= 1 && parts[5] as? Int == parts[4] as? Int,
              "and one just after a rule keeps them too (read: \(parts[4]) then \(parts[5]))")
        check(parts[6] as? Int == parts[7] as? Int,
              "a redraw after typing gives a restore to the blocks a full one does (read: \(parts[6]) typed, \(parts[7]) whole)")
        after(150) {
            let sent = probe.reviewClears.count > before ? probe.reviewClears.last ?? "" : ""
            check(sent.contains("\u{E000}---\u{E001}") && sent.hasPrefix("xxxxxA") == true,
                  "a rule's clear, after typing above it, clears the rule where it now is (read: \(sent.debugDescription))")
            reviewRedrawFuzz()
        }
    }
}

// Typing redraws only what it touched; what it draws must be what drawing
// every mark again would. Random writings of paragraphs, rules and list
// items, random marks and places taken out, random typing and deleting.
func reviewRedrawFuzz() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const ed = document.querySelector('.ProseMirror').editor;
            rv.setMode('edit');
            // mulberry32: exact in 32-bit integer arithmetic.
            let seed = 7;
            const random = n => {
                seed = (seed + 0x6D2B79F5) | 0;
                let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
                t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
                return (((t ^ (t >>> 14)) >>> 0) % n);
            };
            const seen = { paragraphs: 0, rules: 0, items: 0, restores: 0 };
            const S = '\\uE000', E = '\\uE001', P = '\\uE002';
            const words = ['one', 'two', 'three', 'four', 'five'];
            const failures = [];
            let edits = 0;
            let withMarks = 0;
            for (let trial = 0; trial < 150 && failures.length < 3; trial++) {
                const blocks = [];
                for (let i = 0, n = 2 + random(5); i < n; i++) {
                    const kind = random(4);
                    if (kind === 0) { blocks.push(['---']); seen.rules++; }
                    else {
                        if (kind === 1) seen.items++; else seen.paragraphs++;
                        const text = Array.from({ length: 1 + random(4) }, () => words[random(5)]);
                        blocks.push(kind === 1 ? ['- ', text] : ['', text]);
                    }
                }
                // Marks: a whole block, a word, or a place before a block.
                let open = false;
                const marked = blocks.map((block, b) => {
                    let out = '';
                    if (random(5) === 0 && !open) out += P;
                    if (block.length === 1) {
                        if (!open && random(3) === 0) { open = true; out += S + '---'; if (random(2) === 0) { out += E; open = false; } return out; }
                        out += '---';
                        if (open && random(2) === 0) { out += E; open = false; }
                        return out;
                    }
                    out += block[0];
                    out += block[1].map((w, i) => {
                        let piece = i > 0 ? ' ' : '';
                        if (!open && random(4) === 0) { open = true; piece += S; }
                        piece += w;
                        if (open && random(3) === 0) { piece += E; open = false; }
                        return piece;
                    }).join('');
                    return out;
                });
                if (open) marked[marked.length - 1] += E;
                const plain = blocks.map(block => block.length === 1 ? '---' : block[0] + block[1].join(' ')).join('\\n\\n');
                rv.load(plain);
                const changes = (marked.join('').match(new RegExp(S + '|' + P, 'g')) || []).map((_, i) => random(2) ? { id: 'c' + i, now: 'x', before: 'y' } : null);
                if (!rv.setReviewMarks(marked.join('\\n\\n'), changes)) continue;
                for (let step = 0; step < 4; step++) {
                    const size = ed.state.doc.content.size;
                    const at = 1 + random(Math.max(1, size - 1));
                    try {
                        if (random(3) === 0) ed.commands.deleteRange({ from: at, to: Math.min(size, at + 1 + random(4)) });
                        else ed.commands.insertContentAt(at, 'z');
                    } catch (e) { continue; }
                    edits++;
                    if (document.querySelector('.review-clear')) withMarks++;
                    seen.restores += document.querySelectorAll('.review-restore').length;
                    const differs = rv.reviewRedrawDiffers();
                    if (differs) { failures.push({ marked: marked.join('\\n\\n'), step, now: rv.getContent(), differs }); break; }
                }
            }
            return JSON.stringify({ edits, withMarks, seen, failures });
        })()
        """) { r in
        let text = r as? String ?? ""
        let read = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let edits = read?["edits"] as? Int ?? 0
        let marked = read?["withMarks"] as? Int ?? 0
        let failures = read?["failures"] as? [Any] ?? [1]
        let seen = read?["seen"] as? [String: Int] ?? [:]
        check(["paragraphs", "rules", "items"].allSatisfy { (seen[$0] ?? 0) > 100 } && (seen["restores"] ?? 0) > 100,
              "and those writings hold paragraphs, rules and list items, with restores drawn (read: \(seen))")
        check(marked > 150 && failures.isEmpty, "typing redraws what a whole redraw would, over \(marked) random edits with marks drawn of \(edits) (read: \(failures.isEmpty ? "agreed" : text.prefix(900).description))")
        reviewMarksCost()
    }
}

// What review marks cost, pinned so a change cannot add lag unseen. Counts
// first, which a busy machine cannot throw off: typing in a marked writing
// builds no trace, and drawing the same marks again uses the one it has.
// Then the trace against the page's own writing of the same document, a
// ratio that holds when the whole machine is slow.
func reviewMarksCost() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            const paragraphs = [];
            const marked = [];
            for (let i = 0; i < 1300; i++) {
                const place = String(i).split('').map(d => String.fromCharCode(0xE010 + Number(d))).join('');
                paragraphs.push('Paragraph ' + i + ' has *some* words in it, and [a link](https://example.com/' + i + ').');
                marked.push('Paragraph ' + i + ' has *\\uE000' + place + '\\uE01Asome\\uE001* words in it, and [a link](https://example.com/' + i + ').');
            }
            rv.load(paragraphs.join('\\n\\n'));
            // Editing with no marks, timed, for the same edits with them.
            const edit = n => { rv.setSearch('Paragraph ' + n + ' has', {}); rv.replaceCurrent('Paragraph ' + n + ' now has'); };
            let t = performance.now();
            for (let i = 0; i < 20; i++) edit(200 + i);
            const editingBare = performance.now() - t;
            rv.load(paragraphs.join('\\n\\n'));
            const before = rv.reviewTraceBuilds();
            const firstDraw = rv.setReviewMarks(marked.join('\\n\\n'), []);
            const drawn = document.querySelectorAll('.review-mark').length;
            const afterDraw = rv.reviewTraceBuilds();
            rv.setReviewMarks(null, []);
            rv.setReviewMarks(marked.join('\\n\\n'), []);
            const afterRedraw = rv.reviewTraceBuilds();
            t = performance.now();
            for (let i = 0; i < 20; i++) edit(300 + i);
            const editingMarked = performance.now() - t;
            rv.clearSearch();
            // Editing with the marks shown, as transactions the page takes:
            // line breaks through its own keymap, and words put in by
            // find and replace.
            rv.focus();
            const view = document.querySelector('.ProseMirror');
            const lengthBefore = rv.getContent().length;
            const buildsBeforeTyping = rv.reviewTraceBuilds();
            for (let i = 0; i < 20; i++) {
                view.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', shiftKey: true, bubbles: true, cancelable: true }));
            }
            for (let i = 0; i < 20; i++) {
                rv.setSearch('Paragraph ' + (100 + i) + ' has', {});
                rv.replaceCurrent('Paragraph ' + (100 + i) + ' now has');
            }
            rv.clearSearch();
            const afterTyping = rv.reviewTraceBuilds() - buildsBeforeTyping + afterRedraw;
            const typed = rv.getContent().length - lengthBefore;
            // The trace against the stock writer, each the median of five.
            const median = f => {
                const times = [];
                for (let i = 0; i < 5; i++) { const t = performance.now(); f(); times.push(performance.now() - t); }
                return times.sort((a, b) => a - b)[2];
            };
            // Each write of a document just loaded, so none is the page's
            // kept writing; the loading is not timed.
            const writes = [];
            for (let i = 0; i < 5; i++) {
                rv.load(paragraphs.join('\\n\\n'));
                const w = performance.now();
                rv.getContent();
                writes.push(performance.now() - w);
            }
            const writing = writes.sort((a, b) => a - b)[2];
            // Each draw on a document just loaded, so each traces afresh;
            // the loading is not timed.
            const beforeTimed = rv.reviewTraceBuilds();
            const draws = [];
            for (let i = 0; i < 5; i++) {
                rv.load(paragraphs.join('\\n\\n'));
                const t = performance.now();
                rv.setReviewMarks(marked.join('\\n\\n'), []);
                draws.push(performance.now() - t);
            }
            const tracing = draws.sort((a, b) => a - b)[2];
            const timedBuilds = rv.reviewTraceBuilds() - beforeTimed;
            // The same draw with the trace already built: what is left is
            // drawing the marks, so the difference is what tracing costs.
            const redraws = [];
            for (let i = 0; i < 5; i++) {
                rv.setReviewMarks(null, []);
                const r = performance.now();
                rv.setReviewMarks(marked.join('\\n\\n'), []);
                redraws.push(performance.now() - r);
            }
            const drawing = redraws.sort((a, b) => a - b)[2];
            const lastDrawn = document.querySelectorAll('.review-mark').length;
            return [afterDraw - before, afterRedraw - afterDraw, afterTyping - afterRedraw, writing, tracing, typed, timedBuilds, firstDraw === true ? drawn : -1, lastDrawn, editingBare, editingMarked, drawing]
        })()
        """) { r in
        let parts = (r as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        guard parts.count == 12 else { check(false, "the cost checks ran (read: \(String(describing: r)))"); savesAfterATrailingBreak(); return }
        check(parts[7] == 1300 && parts[8] == 1300, "the draws being timed drew every mark (read: \(Int(parts[7])), then \(Int(parts[8])))")
        print("  20 edits took \(Int(parts[9])) ms with no marks, \(Int(parts[10])) ms with 1,300 shown")
        check(parts[10] <= 3 * parts[9] + 60, "and editing with 1,300 marks shown costs at most three times editing with none and 3 ms an edit (read: \(Int(parts[10])) ms against \(Int(parts[9])) ms; it was 913 before only the edited blocks were redrawn)")
        check(parts[0] == 1, "drawing marks builds the trace once (read: \(Int(parts[0])))")
        check(parts[1] == 0, "drawing the same marks again uses the trace it has (read: \(Int(parts[1])))")
        check(parts[5] >= 20 * 4, "the edits reached the document (read: \(Int(parts[5])) characters added)")
        check(parts[2] == 0, "editing a marked writing builds no trace (read: \(Int(parts[2])))")
        check(parts[6] == 5, "and each timed draw traced the document afresh (read: \(Int(parts[6])) builds)")
        print("  writing 1,300 paragraphs took \(Int(parts[3])) ms; a draw that traces them \(Int(parts[4])) ms, one with the trace built \(Int(parts[11])) ms")
        check(parts[4] - parts[11] <= 3 * parts[3] + 5, "and tracing costs at most three writings of the same document (read: \(Int(parts[4] - parts[11])) ms against \(Int(parts[3])) ms)")
        savesAfterATrailingBreak()
    }
}

// prosemirror-markdown 1.13.3 threw writing a paragraph of bold, a line
// break, a line and a line break at its end, and no edit was saved while it
// stayed so. Typed as a writer types it: Shift-Return at the end.
func savesAfterATrailingBreak() {
    let before = probe.changes.count
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('**Title**\\\\\\nline');
            rv.focus();
            const view = document.querySelector('.ProseMirror');
            const walker = document.createTreeWalker(view, NodeFilter.SHOW_TEXT);
            let last = null, node;
            while ((node = walker.nextNode())) last = node;
            const range = document.createRange();
            range.setStart(last, last.textContent.length);
            range.collapse(true);
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            document.dispatchEvent(new Event('selectionchange'));
            return true
        })()
        """) { _ in
        after(150) {
            js("""
                (() => {
                    document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', shiftKey: true, bubbles: true, cancelable: true }));
                    try { return window.editorAPI.getContent() } catch (e) { return 'threw: ' + e.message }
                })()
                """) { r in
                check(r as? String == "**Title**\\\nline", "a line break typed at the end of a line after bold can be written (read: \(String(describing: r)))")
                after(500) {
                    check(probe.changes.count > before && probe.changes.last == "**Title**\\\nline", "and the edit is reported (read: \(probe.changes.suffix(2)))")
                    reviewMarks()
                }
            }
        }
    }
}

// The safety net: where one mark's markers make the document another, the
// rest are still drawn, and the page says how many were not.
func reviewMarksInGroups() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('read');
            const marks = () => Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent).join('|');
            const text = 'One two three [link](https://example.com) four.';
            rv.load(text);
            // The second mark is a change to the link's address alone,
            // which the page shows no text for: drawn as a point beside it.
            const partly = rv.setReviewMarks('One \\uE000\\uE010\\uE01Atwo\\uE001 three [link](https://ex\\uE000\\uE011\\uE01Aample.com\\uE001) four.', []);
            const partlyShown = marks() + '+' + document.querySelectorAll('.review-point').length;
            // Unnumbered, the first left out (a point before the first
            // words, across a blank line from them, which has nowhere to
            // stand): the second is not offered the first's restore.
            rv.setMode('edit');
            rv.load(text);
            const unnumbered = rv.setReviewMarks('\\uE002\\n\\nOne two three [link](https://example.com) \\uE000four\\uE001.',
                [{ id: 'first', now: '', before: 'old' }, { id: 'second', now: 'four', before: 'five' }]);
            const offered = document.querySelectorAll('.review-restore').length;
            rv.setMode('read');
            rv.load(text);
            // Another document entirely: still refused, as a whole.
            const other = rv.setReviewMarks('Another \\uE000\\uE010\\uE01Adocument\\uE001.', []);
            // A long writing: 1,300 marked paragraphs, one of them unplaceable.
            const paragraphs = [];
            const marked = [];
            for (let i = 0; i < 1300; i++) {
                paragraphs.push('Paragraph ' + i + ' has some words in it.');
                const place = String(i).split('').map(d => String.fromCharCode(0xE010 + Number(d))).join('');
                marked.push(i === 700
                    ? 'Paragraph ' + i + ' has [some](https://ex\\uE000' + place + '\\uE01Aample.com\\uE001) words in it.'
                    : 'Paragraph ' + i + ' has \\uE000' + place + '\\uE01Asome\\uE001 words in it.');
            }
            paragraphs[700] = 'Paragraph 700 has [some](https://example.com) words in it.';
            rv.load(paragraphs.join('\\n\\n'));
            const started = performance.now();
            const long = rv.setReviewMarks(marked.join('\\n\\n'), []);
            const took = Math.round(performance.now() - started);
            return [partly, partlyShown, other, long, document.querySelectorAll('.review-mark').length, took, unnumbered, offered]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 8 else { check(false, "the safety net ran (read: \(String(describing: r)))"); reviewMarks(); return }
        let partly = parts[0] as? [String: Any]
        check(parts[0] as? Bool == true && parts[1] as? String == "two+1",
              "a change to a link's address alone is drawn as a point beside it, and the other mark too (read: \(String(describing: parts[0])), \(String(describing: parts[1])))")
        _ = partly
        check((parts[6] as? [String: Any])?["unshown"] as? Int == 1 && parts[7] as? Int == 1,
              "an unnumbered mark keeps its own restore when one before it is left out (read: \(String(describing: parts[6])), \(String(describing: parts[7])) offered)")
        check(parts[2] as? Bool == false, "another document is still refused whole (read: \(String(describing: parts[2])))")
        let long = parts[3] as? [String: Any]
        let took = parts[5] as? Int ?? -1
        print("  1,300 marks took \(took) ms")
        check(parts[3] as? Bool == true && parts[4] as? Int == 1299,
              "in a long writing, every mark is drawn, the address change as a point (read: \(String(describing: parts[3])), \(String(describing: parts[4])) drawn)")
        check(took >= 0 && took < 300, "and drawing 1,300 marks takes under 300 ms (read: \(took) ms; about 80 when written)")
        _ = long
        reviewMarksDrawnAsRead()
    }
}

// The assistant's changes the writer has not yet read: the host's Markdown
// with markers at each edge, placed in the document shown, drawn, carried
// through typing, and sent back for a clear the same way.
func reviewMarks() {
    js("""
        (() => {
        const rv = window.editorAPI;
        rv.load('One deux three.\\n\\nFour **bold** five.\\n\\nSix seven.');
        const placed = rv.setReviewMarks('One \\uE000deux\\uE001 three.\\n\\nFour **\\uE000bold\\uE001** five.\\n\\nSix\\uE002 seven.');
        return [placed, document.querySelectorAll('.review-mark').length, document.querySelectorAll('.review-point').length,
         document.querySelectorAll('.review-clear').length, rv.getContent()]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        check(parts.first as? Bool == true, "review marks are placed (read: \(String(describing: r)))")
        check(parts.count > 4 && parts[1] as? Int == 2 && parts[2] as? Int == 1, "a mark in plain text and one in bold are drawn, and the point")
        check(parts.count > 4 && parts[3] as? Int == 3, "a clear button beside each block with marks in it")
        check(parts.count > 4 && parts[4] as? String == "One deux three.\n\nFour **bold** five.\n\nSix seven.", "and the content has no markers in it")
        js("""
        (() => {
            const rv = window.editorAPI;
            return [rv.setReviewMarks('Another \\uE000document\\uE001.'), document.querySelectorAll('.review-mark').length]
        })()
        """) { r in
            let parts = r as? [Any] ?? []
            check(parts.first as? Bool == false && parts.last as? Int == 2, "marks for another document are not drawn, and those shown stay (read: \(String(describing: r)))")
            js("""
        (() => {
                const rv = window.editorAPI;
                rv.load('One alpha beta three.');
                rv.setReviewMarks('One \\uE000alpha beta\\uE001 three.');
                window.editorAPI.focus();
                const view = document.querySelector('.ProseMirror');
                document.querySelector('.ProseMirror').dispatchEvent(new Event('focus'));
                return [document.querySelectorAll('.review-mark').length]
        })()
        """) { _ in
                js("""
        (() => {
                    const ed = document.querySelector('.ProseMirror').editor;
                    let marked = null;
                    if (ed) {
                        ed.commands.insertContentAt(10, 'mine ');
                        marked = Array.from(document.querySelectorAll('.review-mark')).map(e => e.textContent);
                    }
                    return marked
        })()
        """) { r in
                    if let marked = r as? [String] {
                        check(marked.count == 2 && !marked.contains { $0.contains("mine") }, "what is typed inside a mark is left out of it, and the mark goes on either side (read: \(marked))")
                    } else {
                        print("note: the editor instance is not reachable from the page, so typing into a mark is not driven here")
                    }
                    js("""
        (() => {
                        const rv = window.editorAPI;
                        rv.load('One deux three.');
                        rv.setReviewMarks('One \\uE000deux\\uE001 three.');
                        document.querySelector('.review-clear').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
                        return rv.reviewMarkdownForSelection()
        })()
        """) { r in
                        let selected = r as? [String: Any]
                        let selectedMarkdown = selected?["markdown"] as? String
                        check(selectedMarkdown?.contains("\u{E000}") == true && selectedMarkdown?.contains("\u{E001}") == true
                              && selected?["plain"] as? String == "One deux three.",
                              "the selection comes back as Markdown with its markers, and the page's text beside it (read: \(String(describing: r).debugDescription))")
                        after(200) {
                            let clears = probe.reviewClears
                            check(clears.last == "\u{E000}One deux three.\u{E001}", "the clear button sends its block's Markdown, marked at its edges (read: \(clears))")
                            js("""
                            (() => {
                                const rv = window.editorAPI;
                                rv.setMode('read');
                                rv.load('Read deux here.');
                                rv.setReviewMarks('Read \\uE000deux\\uE001 here.');
                                document.querySelector('.review-clear').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
                                const reading = document.querySelectorAll('.review-mark').length;
                                document.querySelector('.review-clear').click();
                                rv.setMode('present');
                                const shown = getComputedStyle(document.querySelector('.review-clear')).display;
                                rv.setMode('edit');
                                return [reading, shown]
                            })()
                            """) { r in
                                let parts = r as? [Any] ?? []
                                check(parts.first as? Int == 1, "marks are drawn in read mode (read: \(String(describing: r)))")
                                check(parts.last as? String == "none", "and not while presenting")
                                after(200) {
                                    check(probe.reviewClears.last == "\u{E000}Read deux here.\u{E001}", "a clear works in read mode (read: \(probe.reviewClears))")
                                    check(probe.reviewClears.suffix(2).count == 2 && probe.reviewClears.suffix(2).allSatisfy { $0 == "\u{E000}Read deux here.\u{E001}" }, "and pressed with no pointer, as VoiceOver presses it")
                                    keyboardClear()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// Putting the assistant's change back: a restore button beside the clear
// where the host says a change can be put back, a preview of both wordings,
// the passage sent back as a clear sends it, and the host's text taken in
// as one edit that undoes.
func restoreButton() {
    print("-- restoring wording")
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('One deux three.\\n\\nFour five.');
            const placed = rv.setReviewMarks('One \\uE000deux\\uE001 three.\\n\\nFour\\uE002 five.', [{ id: 'm1', now: 'deux', before: '**two**' }, null]);
            const buttons = Array.from(document.querySelectorAll('.review-clear, .review-restore')).map(b => b.classList[0]);
            const restore = document.querySelector('.review-restore');
            restore.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
            const panel = document.querySelector('.review-popover');
            const texts = panel ? Array.from(panel.querySelectorAll('.review-popover-text')).map(t => t.innerHTML) : [];
            const labels = panel ? Array.from(panel.querySelectorAll('.review-popover-label')).map(t => t.textContent) : [];
            panel?.querySelector('.review-popover-restore')?.click();
            return [placed, buttons, labels, texts, !document.querySelector('.review-popover'), rv.getContent()]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 6 else { check(false, "restore read (read: \(String(describing: r)))"); exit(1) }
        check(parts[0] as? Bool == true, "marks with what they'd put back are placed")
        check((parts[1] as? [String]) == ["review-clear", "review-restore", "review-clear"], "a restore button beside the clear only where a change can be put back (read: \(String(describing: parts[1])))")
        check((parts[2] as? [String]) == ["Now", "Original"], "the preview names both (read: \(String(describing: parts[2])))")
        check((parts[3] as? [String]) == ["<p>deux</p>", "<p><strong>two</strong></p>"], "and shows each as the page shows it (read: \(String(describing: parts[3])))")
        check(parts[4] as? Bool == true && parts[5] as? String == "One deux three.\n\nFour five.", "pressed, it closes and leaves the text to the host (read: \(String(describing: parts[5])))")
        after(100) {
            let sent = probe.reviewRestores.last
            check(sent?.id == "m1" && sent?.plain == "One deux three.\n\nFour five.",
                  "the change goes back by its id, with the page's text (read: \(String(describing: sent)))")
            restorePlaced()
        }
    }
}

// A host that moved markers out of syntax the parser drops writes each
// passage's place after its marker: the passages are paired with the host's
// changes by place, not by the order they stand in, and the places are taken
// out with the markers.
func restorePlaced() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.load('Two passages: alpha and beta.');
            const placed = rv.setReviewMarks(
                'Two passages: \\uE000\\uE011\\uE01Aalpha\\uE001 and \\uE000\\uE010\\uE01Abeta\\uE001.',
                [{ id: 'b', now: 'beta', before: 'B' }, { id: 'a', now: 'alpha', before: 'A' }]
            );
            const marks = Array.from(document.querySelectorAll('.review-mark')).map(m => m.textContent);
            document.querySelector('.review-restore').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
            const panel = document.querySelector('.review-popover');
            const texts = panel ? Array.from(panel.querySelectorAll('.review-popover-text')).map(t => t.textContent) : [];
            rv.load('One deux three.\\n\\nFour five.');
            return [placed, marks, texts]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        check(parts.first as? Bool == true, "placed markers are placed, their places taken out (read: \(String(describing: r)))")
        check((parts.count > 1 ? parts[1] as? [String] : nil) == ["alpha", "beta"], "both passages drawn (read: \(String(describing: parts.count > 1 ? parts[1] : nil)))")
        check((parts.count > 2 ? parts[2] as? [String] : nil) == ["alpha", "A", "beta", "B"],
              "each offered its own change, by place (read: \(String(describing: parts.count > 2 ? parts[2] : nil)))")
        copiedText()
    }
}

// What's copied as plain text is the words as they read, not their
// Markdown: nothing serialises the clipboard's text but the editor itself.
func copiedText() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            const dom = document.querySelector('.ProseMirror');
            const copied = markdown => {
                rv.load(markdown);
                dom.focus();
                dom.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true, cancelable: true }));
                const data = new DataTransfer();
                dom.dispatchEvent(new ClipboardEvent('copy', { clipboardData: data, bubbles: true, cancelable: true }));
                return data.getData('text/plain');
            };
            const plain = [copied('*The Bible in English*'), copied('One **two**\\n\\nThree')];
            rv.load('One deux three.\\n\\nFour five.');
            return plain
        })()
        """) { r in
        check((r as? [String]) == ["The Bible in English", "One two\n\nThree"], "a copy's plain text is the words, not Markdown, a paragraph to a block (read: \(String(describing: r)))")
        restoreWording()
    }
}

func restoreWording() {
    js("""
        (() => {
            const rv = window.editorAPI;
            const before = rv.getContent();
            const refused = rv.restoreWording('One **two** three.\\n\\nFour five.', 'Something else.');
            const unchanged = rv.getContent();
            const made = rv.restoreWording('One **two** three.\\n\\nFour five.', before);
            const marks = document.querySelectorAll('.review-mark').length;
            return [refused, unchanged, made, rv.getContent(), marks]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        check(parts.first is NSNull && parts.count > 1 && parts[1] as? String == "One deux three.\n\nFour five.", "a restore for text that has moved on is refused and changes nothing (read: \(String(describing: r)))")
        check(parts.count > 3 && parts[2] as? String == "One **two** three.\n\nFour five." && parts[3] as? String == "One **two** three.\n\nFour five.", "the host's text is taken in, and the page says what it holds")
        check(parts.count > 4 && parts[4] as? Int == 0, "and the mark put back is no longer drawn (read: \(String(describing: parts.last)))")
        js("\(undo); window.editorAPI.getContent()") { undone in
            check(undone as? String == "One deux three.\n\nFour five.", "Undo brings the assistant's wording back (read: \(String(describing: undone)))")
            restoreBlocks()
        }
    }
}

// A paragraph the assistant put in goes whole, and one it took out comes
// back; read mode offers no restore; typing into a change takes its offer
// away; and the changes can be stepped through.
func restoreBlocks() {
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.load('A.\\n\\nNew para.\\n\\nB.');
            const gone = rv.restoreWording('A.\\n\\nB.', 'A.\\n\\nNew para.\\n\\nB.');
            const back = rv.restoreWording('A.\\n\\nOld para.\\n\\nB.', 'A.\\n\\nB.');
            rv.load('One deux three.');
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'm2', now: 'deux', before: 'two' }]);
            rv.setMode('read');
            const reading = getComputedStyle(document.querySelector('.review-restore')).display;
            const notEditing = rv.restoreWording('One two three.', 'One deux three.');
            rv.setMode('edit');
            const editing = getComputedStyle(document.querySelector('.review-restore')).display;
            const ed = document.querySelector('.ProseMirror').editor;
            let typed = null;
            if (ed) {
                ed.commands.insertContentAt(9, 's');
                typed = [document.querySelectorAll('.review-restore').length, document.querySelectorAll('.review-clear').length];
                document.querySelector('.review-restore').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
                const panel = document.querySelector('.review-popover');
                typed.push(panel ? panel.querySelector('.review-popover-reason')?.textContent ?? '' : 'no panel');
                typed.push(panel ? panel.querySelectorAll('.review-popover-restore').length : -1);
                rv.setMode('edit');
            }
            rv.load('One deux three four.');
            rv.setReviewMarks('One \\uE000deux\\uE001 three \\uE000four\\uE001.', [null, { id: 'm3', now: 'four', before: '4' }]);
            const ranges = [];
            for (let i = 0; i < 3; i++) {
                rv.goToReviewMark(true);
                ranges.push(rv.reviewMarkdownForSelection().markdown);
            }
            rv.goToReviewMark(false);
            ranges.push(rv.reviewMarkdownForSelection().markdown);
            const current = Array.from(document.querySelectorAll('.review-current')).map(e => e.textContent);
            let moved = null;
            const again = document.querySelector('.ProseMirror').editor;
            if (again) {
                again.commands.setTextSelection(2);
                moved = document.querySelectorAll('.review-current').length;
            }
            return [gone, back, reading, notEditing, editing, typed, ranges, current, moved]
        })()
        """) { r in
        let parts = r as? [Any] ?? []
        guard parts.count == 9 else { check(false, "restore blocks read (read: \(String(describing: r)))"); exit(1) }
        check(parts[0] as? String == "A.\n\nB." && parts[1] as? String == "A.\n\nOld para.\n\nB.", "a paragraph put in goes whole, and one taken out comes back (read: \(String(describing: parts[0])), \(String(describing: parts[1])))")
        check(parts[2] as? String == "none" && parts[3] is NSNull && parts[4] as? String != "none", "reading offers no restore, and makes none (read: \(String(describing: parts[2])), \(String(describing: parts[3])), \(String(describing: parts[4])))")
        if let typed = parts[5] as? [Any] {
            check(typed.count == 4 && typed[0] as? Int == 1 && typed[1] as? Int == 1 && typed[2] as? String == "Can’t be put back: you’ve edited this since" && typed[3] as? Int == 0,
                  "typed into, a change is no longer offered, and says why (read: \(typed))")
        } else {
            print("note: the editor instance is not reachable from the page, so typing into a change is not driven here")
        }
        let steps = parts[6] as? [String] ?? []
        check(steps == [
            "One \u{E000}deux\u{E001} three four.",
            "One deux three \u{E000}four\u{E001}.",
            "One \u{E000}deux\u{E001} three four.",
            "One deux three \u{E000}four\u{E001}.",
        ], "the changes are stepped through, round at either end (read: \(steps))")
        check((parts[7] as? [String]) == ["four"], "and the one landed on is drawn as such (read: \(String(describing: parts[7])))")
        if let moved = parts[8] as? Int {
            check(moved == 0, "until the caret moves on (read: \(moved))")
        }
        restoreEdges()
    }
}

// What codex found: a deletion inside a change takes its offer; the host
// saying a change can't be put back is said; marks sent again at the same
// places are what a press sends; and a restore leaves what the page holds
// beyond its Markdown (empty paragraphs at the end) where it was.
func restoreEdges() {
    let staleAtStart = probe.reviewStale
    js("""
        (() => {
            const rv = window.editorAPI;
            rv.setMode('edit');
            rv.load('One deux three.');
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'm4', now: 'deux', before: 'two' }]);
            const ed = document.querySelector('.ProseMirror').editor;
            if (!ed) return null;
            ed.commands.deleteRange({ from: 6, to: 7 });
            const pressed = () => {
                document.querySelector('.review-restore').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
                const panel = document.querySelector('.review-popover');
                const read = panel ? [panel.querySelectorAll('.review-popover-reason').length, panel.querySelectorAll('.review-popover-restore').length] : null;
                panel?.querySelector('.review-popover-restore')?.click();
                document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
                return read;
            };
            const deleted = pressed();
            rv.load('One deux three.');
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'm5', now: 'deux', reason: 'edited' }]);
            const hostSays = pressed();
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'm6', now: 'deux', before: 'two' }]);
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'm7', now: 'deux', before: 'two' }]);
            const resent = pressed();
            rv.load('One deux three.\\n\\nEnd.');
            ed.commands.insertContentAt(ed.state.doc.content.size, [{ type: 'paragraph' }, { type: 'paragraph' }]);
            const blocks = ed.state.doc.childCount;
            const made = rv.restoreWording('One two three.\\n\\nEnd.', rv.getContent());
            const blocksAfter = ed.state.doc.childCount;
            // A trailing break in an earlier paragraph too: two places the page
            // holds what its text doesn't, either side of the change.
            rv.load('A.\\n\\nOne deux three.\\n\\nEnd.');
            ed.commands.insertContentAt(3, { type: 'hardBreak' });
            ed.commands.insertContentAt(ed.state.doc.content.size, [{ type: 'paragraph' }, { type: 'paragraph' }]);
            const apart = rv.getContent();
            const both = rv.restoreWording(apart.replace('deux', 'two'), apart);
            const kept = [ed.state.doc.childCount, ed.state.doc.child(0).childCount];
            ed.commands.insertContentAt(ed.state.doc.child(0).nodeSize + 8, 'X');
            const typedAfter = rv.getContent();
            document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown', {key: 'z', code: 'KeyZ', metaKey: true, bubbles: true, cancelable: true}));
            const undoneOnce = rv.getContent();
            // Two equal paragraphs, empty ones before them only the page has:
            // the second is the one changed.
            rv.load('X.\\n\\nX.');
            ed.commands.insertContentAt(0, [{ type: 'paragraph' }, { type: 'paragraph' }, { type: 'paragraph' }]);
            const twin = rv.restoreWording('X.\\n\\nY.', rv.getContent());
            const twins = [];
            ed.state.doc.forEach(node => twins.push(node.textContent));
            // A link in a preview is shown, not followed.
            rv.load('See deux.');
            rv.setReviewMarks('See \\uE000deux\\uE001.', [{ id: 'm8', now: 'deux', before: '[two](https://example.com)' }]);
            document.querySelector('.review-restore').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
            const link = document.querySelector('.review-popover a');
            rv.setMode('edit');
            const stays = !!document.querySelector('.review-popover');
            const preview = link ? [link.textContent, link.hasAttribute('href'), stays] : null;
            document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
            // Typed beside a change and undone: the host is asked again.
            rv.load('One deux three.');
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'm9', now: 'deux', before: 'two' }]);
            ed.commands.insertContentAt(9, 's');
            document.querySelector('.ProseMirror').dispatchEvent(new KeyboardEvent('keydown', {key: 'z', code: 'KeyZ', metaKey: true, bubbles: true, cancelable: true}));
            const undoneTyping = rv.getContent();
            // Wording the page can't hold is refused, not reported as put back.
            rv.load('One two.');
            const dropped = rv.restoreWording('One<!-- note --> two.', 'One two.');
            // In a quotation of two paragraphs, which its own text writes as one.
            rv.load('> A.\\n>\\n> One deux.');
            const quoted = rv.getContent();
            const inQuote = rv.restoreWording(quoted.replace('deux', 'two'), quoted);
            const quote = ed.state.doc.child(0);
            const quoteKept = [quote.type.name, quote.childCount, quote.textContent];
            // The same words outside the quotation, in a paragraph with a break:
            // the quotation's are the ones changed.
            rv.load('> A.\\n>\\n> One deux.\\n\\nA.  \\nOne deux.');
            const twice = rv.getContent();
            rv.restoreWording(twice.replace('deux', 'two'), twice);
            const outside = [ed.state.doc.child(0).textContent, ed.state.doc.child(1).textContent];
            quoteKept.push(outside);
            // Across two cells of a table: refused, the table as it was.
            rv.load('| A | B |\\n| --- | --- |\\n| One deux. | Other quatre. |');
            const table = rv.getContent();
            const acrossCells = [rv.restoreWording(table.replace('deux', 'two').replace('quatre', 'four'), table), rv.getContent() === table];
            // Two changes in one link, the first selected: only its id.
            rv.load('See [deux and quatre](https://example.com).');
            rv.setReviewMarks('See [\\uE000deux\\uE001 and \\uE000quatre\\uE001](https://example.com).',
                [{ id: 'a', now: 'deux', before: 'two' }, { id: 'b', now: 'quatre', before: 'four' }]);
            rv.goToReviewMark(true);
            const chosen = rv.reviewChangesForSelection();
            // Two lists an emptied paragraph stood between, written as one: the
            // same words in each, the second's changed, and nothing made.
            rv.load('- one\\n- deux\\n\\nGap.\\n\\n- one\\n- deux');
            const gap = ed.state.doc.child(1);
            ed.commands.deleteRange({ from: ed.state.doc.child(0).nodeSize + 1, to: ed.state.doc.child(0).nodeSize + 1 + gap.content.size });
            const lists = rv.getContent();
            const lastAt = lists.lastIndexOf('deux');
            const merged = rv.restoreWording(lists.slice(0, lastAt) + 'two' + lists.slice(lastAt + 4), lists);
            const listTexts = [];
            ed.state.doc.forEach(node => listTexts.push(node.textContent));
            // A quotation whose first two paragraphs its text writes as one,
            // and a third holding both lines with a break: the first is changed.
            rv.load('> Before deux\\n>\\n> after words\\n>\\n> Before deux  \\n> after words');
            const quotes = rv.getContent();
            const at = quotes.indexOf('deux');
            const firstQuote = rv.restoreWording(quotes.slice(0, at) + 'two' + quotes.slice(at + 4), quotes);
            const quoteTexts = [];
            ed.state.doc.child(0).forEach(node => quoteTexts.push(node.textContent));
            // The same, with a long line before, so the words beside the change
            // are the same at both places: still the first, or nothing.
            rv.load('> A long line of context that runs on for a while\\n>\\n> Before deux\\n>\\n> after words\\n>\\n> A long line of context that runs on for a while  \\n> Before deux  \\n> after words');
            const longQuotes = rv.getContent();
            const longAt = longQuotes.indexOf('deux');
            const firstLong = rv.restoreWording(longQuotes.slice(0, longAt) + 'two' + longQuotes.slice(longAt + 4), longQuotes);
            const longTexts = [];
            ed.state.doc.child(0).forEach(node => longTexts.push(node.textContent));
            // A quotation of three paragraphs, then one outside it.
            rv.load('> One.\\n>\\n> Two deux.\\n>\\n> Three.\\n\\nAfter.');
            const three = rv.getContent();
            const threeAt = three.indexOf('deux');
            const inThree = rv.restoreWording(three.slice(0, threeAt) + 'two' + three.slice(threeAt + 4), three);
            // Markdown editing closes a preview left open.
            rv.load('One deux three.');
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'md', now: 'deux', before: 'two' }]);
            document.querySelector('.review-restore').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
            const openBefore = !!document.querySelector('.review-popover');
            rv.switchToMarkdown();
            const openInMarkdown = !!document.querySelector('.review-popover');
            rv.switchToRichText();
            // Typing while a preview is open closes it. (Back from Markdown the
            // page has no marks until the host sends them again.)
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'md', now: 'deux', before: 'two' }]);
            document.querySelector('.review-restore').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
            const openToType = !!document.querySelector('.review-popover');
            ed.commands.insertContentAt(7, 'x');
            const openAfterTyping = !!document.querySelector('.review-popover');
            // A selection in words unchanged, in a link with a change elsewhere.
            rv.load('See [deux and unchanged](https://example.com).');
            rv.setReviewMarks('See [\\uE000deux\\uE001 and unchanged](https://example.com).', [{ id: 'c', now: 'deux', before: 'two' }]);
            ed.commands.setTextSelection({ from: 15, to: 24 });
            const unchanged = rv.reviewChangesForSelection();
            // The only mark deleted, then undone: the host is asked again.
            rv.load('One deux three.');
            rv.setReviewMarks('One \\uE000deux\\uE001 three.', [{ id: 'm10', now: 'deux', before: 'two' }]);
            ed.commands.deleteRange({ from: 5, to: 9 });
            const leftMarks = document.querySelectorAll('.review-mark').length;
            return [deleted, hostSays, resent, blocks, blocksAfter, made, both, kept, typedAfter, undoneOnce, twin, twins, preview, undoneTyping, dropped, inQuote, quoteKept, leftMarks, acrossCells, [chosen.ids, chosen.unnamed], [merged, listTexts], [firstQuote, quoteTexts], [unchanged.ids, unchanged.unnamed, unchanged.caret], [firstLong, longTexts], [inThree, openBefore, openInMarkdown, openToType, openAfterTyping]]
        })()
        """) { r in
        guard let parts = r as? [Any], parts.count == 25 else {
            // Null is the page saying it can't reach the editor; anything else
            // (nothing, from an exception) is a failure, not a skip.
            if r is NSNull {
                print("note: the editor instance is not reachable from the page, so the restore edges are not driven here")
                exit(failed ? 1 : 0)
            }
            check(false, "restore edges read (read: \(String(describing: r)))")
            exit(1)
        }
        check((parts[0] as? [Int]) == [1, 0], "a deletion inside a change takes its offer and says why (read: \(String(describing: parts[0])))")
        check((parts[1] as? [Int]) == [1, 0], "a change the host says can't be put back says why, with nothing to press (read: \(String(describing: parts[1])))")
        check((parts[2] as? [Int]) == [0, 1], "marks sent again at the same places are offered (read: \(String(describing: parts[2])))")
        check(parts[3] as? Int == 4 && parts[4] as? Int == 4 && parts[5] as? String == "One two three.\n\nEnd.",
              "a restore leaves the empty paragraphs the page holds beyond its Markdown (read: \(String(describing: parts[3])) → \(String(describing: parts[4])), \(String(describing: parts[5])))")
        check(parts[6] as? String == "A.\n\nOne two three.\n\nEnd." && (parts[7] as? [Int]) == [5, 2],
              "and with a trailing break before it too, keeps both (read: \(String(describing: parts[6])), \(String(describing: parts[7])))")
        check((parts[8] as? String)?.contains("X") == true && parts[9] as? String == "A.\n\nOne two three.\n\nEnd.",
              "typing straight after a restore undoes alone (read: \(String(describing: parts[8])) → \(String(describing: parts[9])))")
        check((parts[10] as? String)?.hasSuffix("X.\n\nY.") == true && (parts[11] as? [String]) == ["", "", "", "X.", "Y."],
              "of two equal paragraphs, the one changed is the one restored (read: \(String(describing: parts[10])), \(String(describing: parts[11])))")
        check((parts[12] as? [Any]).map { $0.count == 3 && $0[0] as? String == "two" && $0[1] as? Bool == false } == true,
              "a link in a preview is shown, not followed (read: \(String(describing: parts[12])))")
        check((parts[12] as? [Any]).map { $0.count == 3 && $0[2] as? Bool == true } == true,
              "and the preview stays open when the host sends the same mode again")
        check(parts[14] is NSNull, "wording the page can't hold is refused, not reported as put back (read: \(String(describing: parts[14])))")
        check((parts[15] as? String)?.contains("One two.") == true && (parts[16] as? [Any]).map { $0[0] as? String == "blockquote" && $0[1] as? Int == 2 } == true,
              "a change in a quotation of two paragraphs is put back, both kept (read: \(String(describing: parts[15])), \(String(describing: parts[16])))")
        check((parts[16] as? [Any]).flatMap { $0.last as? [String] }.map { $0[0].contains("One two.") && $0[1].contains("deux") } == true,
              "and the same words outside the quotation are left alone (read: \(String(describing: parts[16])))")
        check(parts[17] as? Int == 0, "deleting the only mark leaves none drawn")
        check((parts[18] as? [Any]).map { $0[0] is NSNull && $0[1] as? Bool == true } == true,
              "a restore across a table's cells is refused, the table as it was (read: \(String(describing: parts[18])))")
        check((parts[19] as? [Any]).map { $0[0] as? String == "a" && $0[1] as? Bool == false } == true,
              "a change selected in a link is the only one the selection names (read: \(String(describing: parts[19])))")
        check((parts[20] as? [Any]).map { $0[0] is NSNull && ($0[1] as? [String])?.allSatisfy { !$0.contains("two") } == true } == true,
              "two lists written as one aren't told apart, and nothing is changed (read: \(String(describing: parts[20])))")
        let quotes = (parts[21] as? [Any]).flatMap { $0.last as? [String] } ?? []
        check(quotes.count == 3 && quotes[2].contains("deux") && ((parts[21] as? [Any])?.first is NSNull || quotes[0].contains("two")),
              "a change in a quotation never lands in a later paragraph with the same words (read: \(String(describing: parts[21])))")
        check((parts[22] as? [Any]).map { $0[0] as? String == "" && $0[1] as? Bool == false && $0[2] as? Bool == false } == true,
              "a selection in unchanged words names no change (read: \(String(describing: parts[22])))")
        let long = (parts[23] as? [Any]).flatMap { $0.last as? [String] } ?? []
        check(long.count == 4 && long[3].contains("deux") && ((parts[23] as? [Any])?.first is NSNull || long[1].contains("two")),
              "and with the same words beside both places, never the later one (read: \(String(describing: parts[23])))")
        check((parts[24] as? [Any]).map { ($0[0] as? String)?.contains("Two two.") == true } == true,
              "a change in a quotation of three paragraphs, with one after it, is put back (read: \(String(describing: parts[24])))")
        check((parts[24] as? [Any]).map { $0[1] as? Bool == true && $0[2] as? Bool == false } == true,
              "and Markdown editing closes a preview left open")
        check((parts[24] as? [Any]).map { $0.count == 5 && $0[3] as? Bool == true && $0[4] as? Bool == false } == true,
              "and typing while a preview is open closes it (read: \(String(describing: parts[24])))")
        let asksBeforeUndo = probe.reviewStale
        after(100) {
            js("\(undo); window.editorAPI.getContent()") { undone in
                after(100) {
                    check(undone as? String == "One deux three." && probe.reviewStale > asksBeforeUndo,
                          "and undoing it asks the host for the marks again (read: \(String(describing: undone)), \(probe.reviewStale) asks, \(asksBeforeUndo) before)")
                    finishEdges(parts: parts, staleAtStart: staleAtStart)
                }
            }
        }
    }
}

func finishEdges(parts: [Any], staleAtStart: Int) {
        after(0) {
            check(parts[13] as? String == "One deux three." && probe.reviewStale > staleAtStart,
                  "an undo with marks shown asks the host for them again (read: \(String(describing: parts[13])), \(probe.reviewStale) asks, \(staleAtStart) before)")
            check(probe.reviewRestores.last?.id == "m7", "and a press sends the change as last sent (read: \(String(describing: probe.reviewRestores.last)))")
            exit(failed ? 1 : 0)
        }
}

probe.onReady = {
    js("typeof window.editorAPI.load") { kind in
        let hasLoad = (kind as? String) == "function"
        print("load() present: \(hasLoad)")
        trial("control, setContent", replace: "window.editorAPI.setContent", leaks: true) {
            guard hasLoad else { exit(0) }
            trial("load", replace: "window.editorAPI.load") {
                js("window.editorAPI.setPlaceholder('Add your notes...'); window.editorAPI.load(''); document.querySelector('.ProseMirror p').getAttribute('data-placeholder')") { p in
                    check((p as? String) == "Add your notes...", "setPlaceholder shows on an empty document (read: \(String(describing: p)))")
                    echo()
                }
            }
        }
    }
}
view.loadFileURL(bundle, allowingReadAccessTo: bundle.deletingLastPathComponent())
// Long enough for the review-mark cost checks, which draw and edit a
// 1,300-paragraph writing several times, on a machine shared with builds.
DispatchQueue.main.asyncAfter(deadline: .now() + 45) { print("timed out"); exit(2) }
app.run()
