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
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        tokens[type, default: []].append(body["token"] as? String)
        if type == "ready" { onReady?() }
        if type == "contentChanged" { changes.append(body["markdown"] as? String ?? "") }
        if type == "contentHeight" { heights.append(body["height"] as? Int ?? -1) }
        if type == "caret" { carets.append((body["top"] as? Int ?? -1, body["bottom"] as? Int ?? -1)) }
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
        check(md == "Body[^1].\n\nAfter the footnotes.\n\n[^1]: note\n    [sic] more", "what follows the footnotes stays in the body, and a later line beginning [sic] stays in its footnote (read: \(md.debugDescription))")
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
            check(parts.last == "Body[^1].\n\nAfter the footnotes.\n\n[^1]: *note*\n    \\[sic\\] more", "a later line beginning [sic] is still one when its footnote is changed (read: \(String(describing: parts.last).debugDescription))")
            js("""
                var a = window.editorAPI;
                a.load('One[^1].\\n\\n[^1]: first');
                a.focus();
                a.insertFootnote('2', 'added *here*');
                1
                """) { _ in
                // The page's own edit reaches the document as the editor
                // observes it, a moment later.
                after(150) {
                    js("window.editorAPI.getContent()") { r in
                        // Its reference goes in at the caret, here the start.
                        check(r as? String == "[^2]One[^1].\n\n[^1]: first\n\n[^2]: added \\*here\\*", "a footnote the phone adds is written beneath the others (read: \(String(describing: r).debugDescription))")
                        exit(failed ? 1 : 0)
                    }
                }
            }
        }
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
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timed out"); exit(2) }
app.run()
