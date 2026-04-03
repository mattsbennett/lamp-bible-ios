//
//  TipTapEditorCoordinator.swift
//  Lamp Bible
//

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
            onReady?()

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
        guard let webView = webView else { return }
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
    }

    func getContent(completion: @escaping (String) -> Void) {
        evaluateJS("window.editorAPI.getContent()") { result in
            completion(result as? String ?? "")
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
        evaluateJS("document.documentElement.style.setProperty(\"--read-top-padding\", \"\(Int(top))px\")")
    }

    // MARK: - Mode Switching

    func switchToRichText() {
        guard isReady else {
            pendingMode = "richtext"
            return
        }
        evaluateJS("window.editorAPI.switchToRichText()")
    }

    func switchToMarkdown() {
        guard isReady else {
            pendingMode = "markdown"
            return
        }
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
