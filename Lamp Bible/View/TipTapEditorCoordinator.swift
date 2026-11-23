//
//  TipTapEditorCoordinator.swift
//  Lamp Bible
//

import LampCore
import WebKit
import SwiftUI

/// Bridge between Swift/SwiftUI and the TipTap editor running in a WKWebView.
/// Handles JS→Swift messages and provides Swift→JS methods for the formatting toolbar.
class TipTapEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    // MARK: - Properties

    weak var webView: WKWebView?
    private var isReady = false
    private var pendingContent: String?
    private var pendingMediaMap: [String: String]?
    private var pendingMode: String?
    private var pendingViewMode: String?
    private var pendingTheme: Bool?
    private var pendingFontSize: CGFloat?
    private var pendingPresentPadding: CGFloat?
    private var pendingReadPadding: CGFloat?
    /// The header padding the page last took, so a host update that measures
    /// the same header again costs no script.
    private var appliedReadPadding: Int?

    /// Called when editor content changes (debounced from JS)
    var onContentChanged: ((String) -> Void)?

    /// Called when selection state changes (for toolbar button highlighting)
    var onSelectionChanged: ((_ bold: Bool, _ italic: Bool, _ heading: Int, _ blockquote: Bool, _ bulletList: Bool, _ orderedList: Bool, _ link: Bool, _ table: Bool) -> Void)?

    /// Called when an image is tapped
    var onImageTapped: ((String) -> Void)?

    /// Called when an audio block is tapped
    var onAudioBlockTapped: ((String) -> Void)?

    /// Called when editor focus changes
    var onFocusChanged: ((Bool) -> Void)?

    /// Called when a link is tapped in non-editable mode
    var onLinkTapped: ((String) -> Void)?

    /// Called when a footnote reference is tapped in non-editable mode
    var onFootnoteTapped: ((String) -> Void)?

    /// Called when editor is ready
    var onReady: (() -> Void)?

    /// A paragraph's ✓ was pressed: the document's Markdown with markers at
    /// the paragraph's edges, for the host to clear what of the review marks
    /// fall there (`LampWritingReview.markedRange`), and the page's own text
    /// as it reports edits, for a host whose copy is a moment behind.
    var onReviewClear: ((_ marked: String, _ pageText: String?) -> Void)?

    /// The page couldn't place the review marks it was sent: its text was a
    /// moment ahead of the host's. The host sends them again once it settles.
    var onReviewMarksRejected: (() -> Void)?

    /// An undo or redo moved the page's text, perhaps back to words a
    /// change can be put back from: the host sends the marks again.
    var onReviewMarksStale: (() -> Void)?

    /// A change's Restore Original Wording was pressed: the change's id, as
    /// the host sent it with the marks, and the page's own text. The host
    /// works out the text with the old wording back and hands it to
    /// `restoreWording`.
    var onReviewRestore: ((_ changeID: String, _ pageText: String?) -> Void)?

    /// The review marks last sent: sent again once the page is ready, and
    /// after its document is replaced, which takes them off.
    private var reviewMarks: String?
    /// What each of those marked ranges would put back, in their order.
    private var reviewChanges: [LampWritingReview.Change?] = []
    /// The page is in Markdown editing, as last asked: only coming back from
    /// it rebuilds the rich-text document, and takes the marks off.
    private var inMarkdown = false

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "contentChanged":
            if let markdown = body["markdown"] as? String {
                onContentChanged?(markdown)
            }

        case "selectionChanged":
            let bold = body["bold"] as? Bool ?? false
            let italic = body["italic"] as? Bool ?? false
            let heading = body["heading"] as? Int ?? 0
            let blockquote = body["blockquote"] as? Bool ?? false
            let bulletList = body["bulletList"] as? Bool ?? false
            let orderedList = body["orderedList"] as? Bool ?? false
            let link = body["link"] as? Bool ?? false
            let table = body["table"] as? Bool ?? false
            onSelectionChanged?(bold, italic, heading, blockquote, bulletList, orderedList, link, table)

        case "imageTapped":
            if let mediaId = body["mediaId"] as? String {
                onImageTapped?(mediaId)
            }

        case "audioBlockTapped":
            if let mediaId = body["mediaId"] as? String {
                onAudioBlockTapped?(mediaId)
            }

        case "linkTapped":
            if let url = body["url"] as? String {
                onLinkTapped?(url)
            }

        case "footnoteTapped":
            if let id = body["id"] as? String {
                onFootnoteTapped?(id)
            }

        case "ready":
            isReady = true
            // A page that has just loaded holds none of what was sent before.
            appliedReadPadding = nil
            // Apply any pending state
            if let content = pendingContent {
                pendingContent = nil
                setContent(content)
            }
            if let map = pendingMediaMap {
                pendingMediaMap = nil
                setMediaMap(map)
            }
            if let mode = pendingMode {
                pendingMode = nil
                if mode == "markdown" { switchToMarkdown() } else { switchToRichText() }
            }
            if let isDark = pendingTheme {
                pendingTheme = nil
                setTheme(isDark: isDark)
            }
            if let size = pendingFontSize {
                pendingFontSize = nil
                setFontSize(size)
            }
            if let viewMode = pendingViewMode {
                pendingViewMode = nil
                setMode(viewMode)
            }
            if let padding = pendingPresentPadding {
                pendingPresentPadding = nil
                setPresentPadding(bottom: padding)
            }
            if let readPadding = pendingReadPadding {
                pendingReadPadding = nil
                setReadPadding(top: readPadding)
            }
            if reviewMarks != nil { sendReviewMarks() }
            onReady?()

        case "reviewClear":
            if let markdown = body["markdown"] as? String {
                onReviewClear?(markdown, body["plain"] as? String)
            }

        case "reviewMarksStale":
            onReviewMarksStale?()

        case "reviewRestore":
            if let id = body["id"] as? String {
                onReviewRestore?(id, body["plain"] as? String)
            }

        case "focusChanged":
            if let focused = body["focused"] as? Bool {
                onFocusChanged?(focused)
            }

        default:
            print("[TipTapCoordinator] Unknown message type: \(type)")
        }
    }

    // MARK: - WKNavigationDelegate

    /// Called when WebView finishes loading (for reapplying header insets)
    var onPageLoaded: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded, editor JS will call ready when TipTap is initialized
        onPageLoaded?()
    }

    // MARK: - Swift → JS Methods

    private func evaluateJS(_ js: String, completion: ((Any?) -> Void)? = nil) {
        // Answered still, with nothing, so a caller waiting on it goes on.
        guard let webView = webView else {
            completion?(nil)
            return
        }
        webView.evaluateJavaScript(js) { result, error in
            if let error = error {
                print("[TipTapCoordinator] JS error: \(error.localizedDescription)")
            }
            completion?(result)
        }
    }

    func setContent(_ markdown: String) {
        guard isReady else {
            pendingContent = markdown
            return
        }
        let escaped = markdown.jsEscaped()
        evaluateJS("window.editorAPI.setContent(\"\(escaped)\")")
        // Marks for the text replaced: refused if they aren't this one's,
        // which has the host draw them for it.
        if reviewMarks != nil { sendReviewMarks() }
    }

    /// Loads a document as the page's own, as opened: no undo goes back
    /// past it, as `setContent`'s replacement would let one.
    func load(_ markdown: String) {
        guard isReady else {
            pendingContent = markdown
            return
        }
        evaluateJS("window.editorAPI.load(\"\(markdown.jsEscaped())\")")
        if reviewMarks != nil { sendReviewMarks() }
    }

    /// Loads `markdown` only if the page still holds one of `expected`,
    /// checked and loaded as one step in the page, so nothing typed between
    /// the check and the load is lost. Answers with the page's Markdown just
    /// after the load, read in the same step, or nil where it didn't load.
    func load(_ markdown: String, ifHolding expected: [String], completion: @escaping (String?) -> Void) {
        guard isReady else { return completion(nil) }
        let wanted = expected.map { "\"\($0.jsEscaped())\"" }.joined(separator: ",")
        evaluateJS("""
        (function () {
          const now = window.editorAPI.getContent();
          if (![\(wanted)].includes(now)) return null;
          window.editorAPI.load("\(markdown.jsEscaped())");
          return window.editorAPI.getContent();
        })()
        """) { [weak self] result in
            let loaded = result as? String
            if loaded != nil, let self, self.reviewMarks != nil { self.sendReviewMarks() }
            completion(loaded)
        }
    }

    // MARK: - Review marks

    /// Shows the writing assistant's changes still to read: the document's
    /// Markdown with markers at each edge (`LampWritingReview.markedMarkdown`),
    /// or nil for none. Kept through typing by the page itself. `changes`
    /// says for each marked range, in order, what restoring it would put
    /// back, nil where nothing can be.
    func setReviewMarks(_ marked: String?, changes: [LampWritingReview.Change?] = []) {
        reviewMarks = marked
        reviewChanges = marked == nil ? [] : changes
        guard isReady else { return }
        sendReviewMarks()
    }

    private func sendReviewMarks() {
        let argument = reviewMarks.map { "\"\($0.jsEscaped())\"" } ?? "null"
        let changes = (try? JSONEncoder().encode(reviewChanges)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        evaluateJS("window.editorAPI.setReviewMarks(\(argument), \(changes))") { [weak self] result in
            if (result as? Bool) == false { self?.onReviewMarksRejected?() }
        }
    }

    /// Takes in the text a restore worked out, as one edit the page makes
    /// and can undo, if the page still holds `expected`. Answers with the
    /// page's Markdown afterwards, or nil where nothing was changed.
    func restoreWording(_ markdown: String, expecting expected: String, completion: @escaping (String?) -> Void) {
        guard isReady else { return completion(nil) }
        evaluateJS("window.editorAPI.restoreWording(\"\(markdown.jsEscaped())\", \"\(expected.jsEscaped())\")") { result in
            completion(result as? String)
        }
    }

    /// Selects the next change still to read after the caret, or the one
    /// before, and brings it into view.
    func goToReviewMark(forward: Bool) {
        guard isReady else { return }
        evaluateJS("window.editorAPI.goToReviewMark(\(forward))")
    }

    /// The selection as the document's Markdown with markers at its edges,
    /// for clearing what of the marks it covers, with the page's own text;
    /// nil outside the visual editor. A page built before it sent its text
    /// answers with the Markdown alone.
    func reviewMarkdownForSelection(completion: @escaping (_ marked: String?, _ pageText: String?) -> Void) {
        guard isReady else { return completion(nil, nil) }
        evaluateJS("window.editorAPI.reviewMarkdownForSelection()") { result in
            if let page = result as? [String: Any] {
                completion(page["markdown"] as? String, page["plain"] as? String)
            } else {
                completion(result as? String, nil)
            }
        }
    }

    /// The changes the selection stands in, by the ids the host sent them
    /// with, and whether it touches a passage sent with none; with the
    /// selection's marked Markdown and the page's text, as
    /// `reviewMarkdownForSelection` gives them. Nil outside the visual editor.
    func reviewChangesForSelection(
        completion: @escaping (
            _ ids: String, _ unnamed: Bool, _ caret: Bool, _ marked: String?, _ pageText: String?
        ) -> Void
    ) {
        guard isReady else { return completion("", false, true, nil, nil) }
        evaluateJS("window.editorAPI.reviewChangesForSelection()") { result in
            guard let page = result as? [String: Any] else { return completion("", false, true, nil, nil) }
            completion(
                page["ids"] as? String ?? "", page["unnamed"] as? Bool ?? false, page["caret"] as? Bool ?? true,
                page["markdown"] as? String, page["plain"] as? String
            )
        }
    }

    /// The document as it stands, including what the editor has not yet
    /// reported as an edit. Nil when the page could not answer, which is not
    /// an empty document.
    func getContent(completion: @escaping (String?) -> Void) {
        evaluateJS("window.editorAPI.getContent()") { result in
            completion(result as? String)
        }
    }

    // MARK: - Formatting

    func applyStyle(_ style: TipTapTextStyle) {
        guard isReady else { return }
        switch style {
        case .paragraph:
            evaluateJS("window.editorAPI.setParagraph()")
        case .heading1:
            evaluateJS("window.editorAPI.setHeading(1)")
        case .heading2:
            evaluateJS("window.editorAPI.setHeading(2)")
        case .heading3:
            evaluateJS("window.editorAPI.setHeading(3)")
        case .bold:
            evaluateJS("window.editorAPI.toggleBold()")
        case .italic:
            evaluateJS("window.editorAPI.toggleItalic()")
        case .quote:
            evaluateJS("window.editorAPI.toggleBlockquote()")
        case .bullet:
            evaluateJS("window.editorAPI.toggleBulletList()")
        case .numberedList:
            evaluateJS("window.editorAPI.toggleOrderedList()")
        case .indent:
            evaluateJS("window.editorAPI.indent()")
        case .outdent:
            evaluateJS("window.editorAPI.outdent()")
        }
    }

    func insertLink(url: String) {
        guard isReady else { return }
        let escaped = url.jsEscaped()
        evaluateJS("window.editorAPI.insertLink(\"\(escaped)\")")
    }

    func removeLink() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.removeLink()")
    }

    func insertFootnote(id: String, content: String) {
        guard isReady else { return }
        let escapedId = id.jsEscaped()
        let escapedContent = content.jsEscaped()
        evaluateJS("window.editorAPI.insertFootnote(\"\(escapedId)\", \"\(escapedContent)\")")
    }

    func insertScriptureQuote(citation: String, quotation: String) {
        guard isReady else { return }
        let escapedCitation = citation.jsEscaped()
        let escapedQuotation = quotation.jsEscaped()
        evaluateJS("window.editorAPI.insertScriptureQuote(\"\(escapedCitation)\", \"\(escapedQuotation)\")")
    }

    func insertImage(mediaId: String, caption: String, localURL: String) {
        guard isReady else { return }
        let escapedId = mediaId.jsEscaped()
        let escapedCaption = caption.jsEscaped()
        let escapedURL = localURL.jsEscaped()
        evaluateJS("window.editorAPI.insertImage(\"\(escapedId)\", \"\(escapedCaption)\", \"\(escapedURL)\")")
    }

    func insertAudioBlock(mediaId: String, caption: String) {
        guard isReady else { return }
        let escapedId = mediaId.jsEscaped()
        let escapedCaption = caption.jsEscaped()
        evaluateJS("window.editorAPI.insertAudioBlock(\"\(escapedId)\", \"\(escapedCaption)\")")
    }

    func insertHorizontalRule() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.insertHorizontalRule()")
    }

    func insertTable(rows: Int, cols: Int, withHeaderRow: Bool = true) {
        guard isReady else { return }
        evaluateJS("window.editorAPI.insertTable(\(rows), \(cols), \(withHeaderRow))")
    }

    func addRowAfter() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.addRowAfter()")
    }

    func addColumnAfter() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.addColumnAfter()")
    }

    func deleteRow() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.deleteRow()")
    }

    func deleteColumn() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.deleteColumn()")
    }

    func deleteTable() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.deleteTable()")
    }

    // MARK: - View Mode

    func setMode(_ mode: String) {
        guard isReady else {
            pendingViewMode = mode
            return
        }
        let escaped = mode.jsEscaped()
        evaluateJS("window.editorAPI.setMode(\"\(escaped)\")")
    }

    func scrollToFootnote(_ id: String) {
        guard isReady else { return }
        let escaped = id.jsEscaped()
        evaluateJS("window.editorAPI.scrollToFootnote(\"\(escaped)\")")
    }

    func setPresentPadding(bottom: CGFloat) {
        guard isReady else {
            pendingPresentPadding = bottom
            return
        }
        evaluateJS("window.editorAPI.setPresentPadding(\(Int(bottom)))")
    }

    func setReadPadding(top: CGFloat) {
        guard isReady else {
            pendingReadPadding = top
            return
        }
        guard appliedReadPadding != Int(top) else { return }
        appliedReadPadding = Int(top)
        // The same header tops the page while writing, over the editor's
        // own top padding (editor.css, body.mode-edit).
        evaluateJS("document.documentElement.style.setProperty(\"--read-top-padding\", \"\(Int(top))px\"); document.documentElement.style.setProperty(\"--edit-top-padding\", \"\(Int(top))px\")")
    }

    // MARK: - Mode Switching

    func switchToRichText() {
        guard isReady else {
            pendingMode = "richtext"
            return
        }
        let rebuilt = inMarkdown
        inMarkdown = false
        evaluateJS("window.editorAPI.switchToRichText()")
        // Back from Markdown, the page's document is made again without the
        // marks; refused if the text moved, which has the host redraw them.
        if rebuilt, reviewMarks != nil { sendReviewMarks() }
    }

    func switchToMarkdown() {
        guard isReady else {
            pendingMode = "markdown"
            return
        }
        inMarkdown = true
        evaluateJS("window.editorAPI.switchToMarkdown()")
    }

    // MARK: - Appearance

    func setTheme(isDark: Bool) {
        guard isReady else {
            pendingTheme = isDark
            return
        }
        evaluateJS("window.editorAPI.setTheme(\(isDark))")
    }

    func setFontSize(_ size: CGFloat) {
        guard isReady else {
            pendingFontSize = size
            return
        }
        evaluateJS("window.editorAPI.setFontSize(\(Int(size)))")
    }

    func setMediaMap(_ map: [String: String]) {
        guard isReady else {
            pendingMediaMap = map
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: map),
           let json = String(data: data, encoding: .utf8) {
            evaluateJS("window.editorAPI.setMediaMap(\(json))")
        }
    }

    // MARK: - Focus

    func focus() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.focus()")
    }

    func blur() {
        guard isReady else { return }
        evaluateJS("window.editorAPI.blur()")
    }

    func resignFirstResponder() {
        blur()
    }

    func getSelectedText(completion: @escaping (String) -> Void) {
        // Save selection before returning, so it can be restored after sheet dismissal
        evaluateJS("window.editorAPI.saveSelection(); window.editorAPI.getSelectedText()") { result in
            completion(result as? String ?? "")
        }
    }

    /// The words chosen on the page, in any mode. Reading, the editor isn't
    /// editable and its own selection doesn't follow what is highlighted, so
    /// this asks the page.
    func getChosenWords(completion: @escaping (String) -> Void) {
        evaluateJS("(window.getSelection && window.getSelection().toString()) || window.editorAPI.getSelectedText() || ''") { result in
            completion(result as? String ?? "")
        }
    }
}

// MARK: - Text Style Enum

enum TipTapTextStyle {
    case paragraph, heading1, heading2, heading3
    case bold, italic
    case quote, bullet, numberedList
    case indent, outdent
}

// MARK: - String Extension for JS Escaping

private extension String {
    func jsEscaped() -> String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
