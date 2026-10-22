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
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        tokens[type, default: []].append(body["token"] as? String)
        if type == "ready" { onReady?() }
        if type == "contentChanged" { changes.append(body["markdown"] as? String ?? "") }
        if type == "contentHeight" { heights.append(body["height"] as? Int ?? -1) }
        if type == "caret" { carets.append((body["top"] as? Int ?? -1, body["bottom"] as? Int ?? -1)) }
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
            exit(failed ? 1 : 0)
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
