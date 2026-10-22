//
//  TipTapPage.swift
//  Lamp Bible
//

import ObjectiveC
import SwiftUI
import UIKit
import WebKit

/// A TipTap editor loaded once and handed from document to document with
/// `editorAPI.load`. Making a web view costs far more than the editor in it
/// (a few hundred milliseconds cold, tens of megabytes), and handing one to
/// the next document costs about a millisecond, so the app keeps one warm
/// for each kind of editor and reuses it.
@MainActor
final class TipTapPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate {
    enum Kind {
        /// Sized to its text among other views, a note typed as plain text.
        case note
    }

    let kind: Kind
    let webView: WKWebView
    private(set) var isReady = false
    private(set) var isDead = false
    private var queued: [(js: String, done: ((Any?) -> Void)?)] = []

    /// Names the document loaded last. Every message about it carries this,
    /// so one the previous document sent just before the page changed hands
    /// is dropped rather than read as the new document's.
    private var token = ""
    /// What the host called the document loaded last, so a host given the
    /// page back for the same document can carry on without reloading it.
    private(set) var documentKey: String?

    /// Messages about the current document, by type, for whoever holds it.
    var onMessage: ((String, [String: Any]) -> Void)?

    /// The translation whose verses the editor marks references by.
    private var verseCatalogTranslation: String?

    /// The formatting bar shown on the keyboard while a note is typed, and
    /// whether it could be put there (`NoteKeyboardBar`).
    private var keyboardBar: UIHostingController<AnyView>?
    private(set) var hasKeyboardBar = false

    init(kind: Kind) {
        self.kind = kind
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(WeakMessageHandler(self), name: "tiptapBridge")

        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // A note is as tall as its text; the list around it scrolls.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.delegate = self

        // Made with the page, so the note that takes it finds the bar there,
        // however soon after the page is ready that is.
        let bar = UIHostingController(rootView: AnyView(EmptyView()))
        bar.view.backgroundColor = .clear
        let holder = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        bar.view.frame = holder.bounds
        bar.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        holder.addSubview(bar.view)
        keyboardBar = bar
        hasKeyboardBar = NoteKeyboardBar.install(holder, in: webView)

        guard let html = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "TipTapEditor") else {
            print("[TipTapPage] TipTapEditor/index.html is not in the bundle")
            isDead = true
            return
        }
        webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    // MARK: Driving the page

    /// Runs once the editor is ready, in the order asked.
    func run(_ js: String, then done: ((Any?) -> Void)? = nil) {
        guard isReady else {
            queued.append((js, done))
            return
        }
        webView.evaluateJavaScript(js) { result, error in
            if let error { print("[TipTapPage] \(error.localizedDescription) running \(js.prefix(60))") }
            done?(result)
        }
    }

    /// Hands the page to another document. `then` runs once it is in place.
    func load(_ markdown: String, key: String?, then done: (() -> Void)? = nil) {
        token = UUID().uuidString
        documentKey = key
        run("window.editorAPI.load(\(Self.literal(markdown)), \(Self.literal(token)))") { _ in done?() }
    }

    /// Marks verse references as the app finds them where it draws a note,
    /// by the books and verses of the reader's translation.
    func useVerseCatalog(translationId: String) {
        guard verseCatalogTranslation != translationId else { return }
        verseCatalogTranslation = translationId
        Task { @MainActor in
            guard let json = await VerseCatalog.json(for: translationId),
                  verseCatalogTranslation == translationId else { return }
            run("window.editorAPI.setVerseCatalog(\(json))")
        }
    }

    /// Points the keyboard's formatting bar at the note open now.
    func showKeyboardBar(for handle: NoteEditorHandle) {
        keyboardBar?.rootView = AnyView(
            NoteFormattingBar(handle: handle, onFootnote: { [weak handle] in handle?.onFootnote?() })
                .padding(.horizontal, 8)
        )
    }

    /// The document as it stands, including what the editor has not yet
    /// reported as an edit.
    func content(_ done: @escaping (String?) -> Void) {
        run("window.editorAPI.getContent()") { done($0 as? String) }
    }

    static func literal(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" {
            becomeReady()
            return
        }
        guard (body["token"] as? String) == token else { return }
        onMessage?(type, body)
    }

    private func becomeReady() {
        guard !isReady else { return }
        isReady = true
        switch kind {
        case .note:
            webView.evaluateJavaScript("""
                window.editorAPI.setReportsHeight(true);
                window.editorAPI.setLineBreaks(true);
                window.editorAPI.setPlaceholder('Add your notes...');
                window.editorAPI.setBackgroundColor('transparent');
                """)
        }
        let waiting = queued
        queued = []
        for (js, done) in waiting { run(js, then: done) }
    }

    // MARK: UIScrollViewDelegate

    /// The page is as tall as its text and never scrolls: WebKit and the
    /// editor both scroll it to bring the caret into view, which while the
    /// page is shorter than the text, just after it is given more, slides the
    /// text up out of sight. The list around it brings the caret into view.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.contentOffset != .zero { scrollView.contentOffset = .zero }
    }

    // MARK: WKNavigationDelegate

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isDead = true
        onMessage?("terminated", [:])
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page is the editor and nothing else: a link is the host's to open.
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

/// Holds the page weakly: a content controller keeps its handlers alive, and
/// the page keeps the controller.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// WebKit raises the keyboard only for a focus it saw the person ask for, a
/// tap in the page itself. A note section is tapped in its native drawing and
/// only then opens in the editor, so the editor's focus would arrive with no
/// keyboard, and the person would have to tap again. For a focus the app
/// asks for in the moment after such a tap, WebKit is told the person is
/// interacting, which they are.
///
/// This replaces a private WebKit method, as Capacitor and Ionic apps do.
/// If an iOS release renames it, nothing is replaced and a second tap raises
/// the keyboard as before (`NoteEditorKeyboardTests` notices).
@MainActor
enum TipTapKeyboard {
    private static let selector = sel_getUid(
        "_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:"
    )
    private static var allowedUntil = Date.distantPast
    private static var installed = false

    /// Whether this iOS has the method, so a focus can raise the keyboard.
    static var isAvailable: Bool {
        NSClassFromString("WKContentView").flatMap { class_getInstanceMethod($0, selector) } != nil
    }

    /// The next focus the app asks for, within a second, raises the keyboard.
    static func allowFocus() {
        install()
        allowedUntil = Date().addingTimeInterval(1)
    }

    private static func takeAllowance() -> Bool {
        guard Date() < allowedUntil else { return false }
        allowedUntil = .distantPast
        return true
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        guard let cls = NSClassFromString("WKContentView"),
              let method = class_getInstanceMethod(cls, selector) else { return }
        // (self, _cmd, const FocusedElementInformation&, BOOL userIsInteracting,
        //  BOOL blurPreviousNode, OptionSet<ActivityState> (16 bits), id userObject)
        typealias Focus = @convention(c) (AnyObject, Selector, UnsafeRawPointer?, Bool, Bool, UInt16, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Focus.self)
        let selector = selector
        let replacement: @convention(block) (AnyObject, UnsafeRawPointer?, Bool, Bool, UInt16, AnyObject?) -> Void = {
            view, information, userIsInteracting, blurPrevious, changes, userObject in
            let allowed = MainActor.assumeIsolated { takeAllowance() }
            original(view, selector, information, userIsInteracting || allowed, blurPrevious, changes, userObject)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

/// The note editor's formatting, on the keyboard while a note is typed, in
/// place of WebKit's bar for stepping between form fields, which a note has
/// none of. Given to the note page's own content view only, as a subclass of
/// that one view that answers `inputAccessoryView`: every other web view
/// keeps WebKit's bar. If the content view is not where WebKit keeps it, or
/// not a plain WebKit class, nothing is changed and the bar shows in the note.
@MainActor
enum NoteKeyboardBar {
    private static let subclassName = "LampNoteEditorContentView"
    private static var subclass: AnyClass?

    static func install(_ bar: UIView, in webView: WKWebView) -> Bool {
        guard let content = webView.scrollView.subviews.first(where: {
            let name = NSStringFromClass(type(of: $0))
            return name == "WKContentView" || name == subclassName
        }) else { return false }
        objc_setAssociatedObject(content, &noteKeyboardBarKey, bar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if NSStringFromClass(type(of: content)) == subclassName { return true }
        guard let subclass = subclass(of: type(of: content)) else { return false }
        object_setClass(content, subclass)
        return true
    }

    private static func subclass(of base: AnyClass) -> AnyClass? {
        if let subclass { return subclass }
        if let existing = NSClassFromString(subclassName) {
            subclass = existing
            return existing
        }
        guard let made = objc_allocateClassPair(base, subclassName, 0) else { return nil }
        let accessory: @convention(block) (AnyObject) -> UIView? = { view in
            objc_getAssociatedObject(view, &noteKeyboardBarKey) as? UIView
        }
        class_addMethod(
            made, #selector(getter: UIResponder.inputAccessoryView),
            imp_implementationWithBlock(accessory), "@@:"
        )
        objc_registerClassPair(made)
        subclass = made
        return made
    }
}

nonisolated(unsafe) private var noteKeyboardBarKey: UInt8 = 0

/// The verse catalog for each translation, made once, away from the main
/// thread: a count of every chapter's verses is some twelve hundred reads.
@MainActor
enum VerseCatalog {
    private static var made: [String: String] = [:]

    static func json(for translationId: String) async -> String? {
        if let json = made[translationId] { return json }
        let json = await Task.detached(priority: .utility) { () -> String? in
            let catalog = VerseReferenceParser.shared.editorCatalog(translationId: translationId)
            guard let data = try? JSONSerialization.data(withJSONObject: catalog) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
        if let json { made[translationId] = json }
        return json
    }
}

/// Keeps one warm page of each kind. A second is made only while two
/// editors of a kind are on screen at once, and let go when handed back.
@MainActor
final class TipTapPagePool {
    static let shared = TipTapPagePool()
    private var idle: [TipTapPage.Kind: TipTapPage] = [:]

    /// Loads a page ahead of need, so the first editor opened is warm.
    func warmUp(_ kind: TipTapPage.Kind) {
        if idle[kind]?.isDead != false { idle[kind] = TipTapPage(kind: kind) }
        idle[kind]?.useVerseCatalog(translationId: UserDatabase.shared.getSettings().readerTranslationId)
    }

    func take(_ kind: TipTapPage.Kind) -> TipTapPage {
        if let page = idle[kind], !page.isDead {
            idle[kind] = nil
            return page
        }
        idle[kind] = nil
        return TipTapPage(kind: kind)
    }

    func giveBack(_ page: TipTapPage) {
        page.onMessage = nil
        guard !page.isDead, idle[page.kind] == nil else { return }
        idle[page.kind] = page
    }
}

// MARK: - The note editor

/// Whether a note is being typed in, for the layout around the panes.
@MainActor
final class NoteEditorFocus: ObservableObject {
    static let shared = NoteEditorFocus()
    @Published var isEditing = false
    /// The note that stopped being typed in last, by its editor key, so the
    /// one closed is that one, not the one opening as it hands over.
    var lastBlurredKey: String?
    /// A sheet opened from the note has the keyboard for now, and the note
    /// carries on when it closes: the space stays the note's meanwhile.
    @Published var isAwaitingSheet = false
}

/// What the formatting bar shows as on, from the editor's selection.
struct NoteFormatting: Equatable {
    var bold = false
    var italic = false
    var bulletList = false
    var orderedList = false
    var blockquote = false
    var link = false
}

/// The editor open on a note section, for the controls around it: its
/// formatting bar and the footnote picker.
@MainActor
final class NoteEditorHandle: ObservableObject {
    @Published fileprivate(set) var formatting = NoteFormatting()
    fileprivate weak var host: NoteEditorHostView?

    /// Where the section was tapped to open it, in its drawing, which lays
    /// its text out where the editor will: the caret goes there.
    var focusOnOpen: CGPoint?

    /// The formatting bar is on the keyboard rather than in the note.
    @Published fileprivate(set) var barIsOnKeyboard = false
    /// Asks for a footnote from the keyboard's bar.
    var onFootnote: (() -> Void)?

    func run(_ command: String) { host?.page?.run("window.editorAPI.\(command)") }

    /// Keeps the caret's place while a sheet takes the focus.
    func saveSelection() { run("saveSelection()") }

    /// Puts the reference at the caret kept by `saveSelection`, and brings
    /// the keyboard back to carry on typing after the footnote sheet.
    func insertFootnoteRef(_ id: String) {
        TipTapKeyboard.allowFocus()
        run("insertFootnoteRef(\(TipTapPage.literal(id)))")
    }

    func dismissKeyboard() { run("blur()") }

    /// Back to typing where the caret was before a sheet took the focus.
    func resumeTyping() {
        TipTapKeyboard.allowFocus()
        run("restoreSelection(); window.editorAPI.focus()")
    }

    #if DEBUG
    func attachForTesting(_ view: NoteEditorHostView) { host = view }
    #endif
}

/// Lays the borrowed page out at the height of its text, keeps the caret
/// above the keyboard, and hands back what the person typed.
final class NoteEditorHostView: UIView {
    fileprivate var page: TipTapPage?
    private var key = ""
    private var lastReported = ""
    private var caret: CGRect?
    private var editorHasFocus = false
    private static var keyboardFrame: CGRect = .null

    var onContent: ((String) -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    var onFormatting: ((NoteFormatting) -> Void)?

    /// The section's text is in the page and the page is showing it.
    var isShowingDocument: Bool { (page?.webView.alpha ?? 0) == 1 && page?.webView.superview === self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Takes the warm page for this section's text. The page is shown once the
    /// text is in it, so the last document on it is never seen here.
    @MainActor
    func attach(
        key: String, markdown: String, fontSize: CGFloat, focusAt point: CGPoint? = nil,
        handle: NoteEditorHandle? = nil
    ) {
        let page = TipTapPagePool.shared.take(.note)
        self.page = page
        page.useVerseCatalog(translationId: UserDatabase.shared.getSettings().readerTranslationId)
        if let handle {
            page.showKeyboardBar(for: handle)
            handle.barIsOnKeyboard = page.hasKeyboardBar
        }
        self.key = key
        lastReported = markdown
        page.onMessage = { [weak self] type, body in self?.handle(type, body) }
        page.webView.frame = bounds
        page.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(page.webView)
        applyAppearance(fontSize: fontSize)
        if page.documentKey == key {
            // Given back the page for this same section, as when the list is
            // rebuilt around it: carry on where it was, undo and all.
            page.run("window.editorAPI.getContent()") { [weak self] text in
                if let text = text as? String, text != markdown { self?.report(text) }
            }
            focus(at: point)
        } else {
            page.webView.alpha = 0
            page.load(markdown, key: key) { [weak self, weak page] in
                page?.webView.alpha = 1
                self?.focus(at: point)
            }
        }
    }

    /// Puts the caret at a point and raises the keyboard, for the tap that
    /// opened the section.
    @MainActor
    private func focus(at point: CGPoint?) {
        guard let point, let page else { return }
        TipTapKeyboard.allowFocus()
        page.run("window.editorAPI.focusAt(\(Double(point.x)), \(Double(point.y)))")
    }

    /// Hands the page back, with whatever the person typed since its last
    /// report: a page reports edits a moment after them.
    @MainActor
    func detach() {
        guard let page else { return }
        if editorHasFocus {
            editorHasFocus = false
            NoteEditorFocus.shared.lastBlurredKey = key
            NoteEditorFocus.shared.isEditing = false
        }
        let onContent = onContent
        let reported = lastReported
        page.content { text in
            if let text, text != reported { onContent?(text) }
        }
        // Not left focused for the next note, whose focus must be its own.
        page.run("window.editorAPI.blur()")
        page.webView.removeFromSuperview()
        TipTapPagePool.shared.giveBack(page)
        self.page = nil
    }

    /// The section's text changed from outside the editor, as when a footnote
    /// is deleted and the others renumbered: the editor takes it in.
    @MainActor
    func replace(with markdown: String) {
        guard let page, markdown != lastReported else { return }
        lastReported = markdown
        page.load(markdown, key: key)
    }

    @MainActor
    func applyAppearance(fontSize: CGFloat) {
        let isDark = traitCollection.userInterfaceStyle == .dark
        page?.run("window.editorAPI.setTheme(\(isDark)); window.editorAPI.setFontSize(\(Int(fontSize)))")
    }

    private func report(_ markdown: String) {
        lastReported = markdown
        onContent?(markdown)
    }

    @MainActor
    private func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "contentChanged":
            if let markdown = body["markdown"] as? String, markdown != lastReported { report(markdown) }
        case "contentHeight":
            if let height = body["height"] as? Double { onHeight?(CGFloat(height)) }
        case "caret":
            if let top = body["top"] as? Double, let bottom = body["bottom"] as? Double {
                caret = CGRect(x: 0, y: top, width: bounds.width, height: max(bottom - top, 1))
                keepCaretInSight()
            }
        case "focusChanged":
            editorHasFocus = body["focused"] as? Bool ?? false
            if !editorHasFocus { NoteEditorFocus.shared.lastBlurredKey = key }
            NoteEditorFocus.shared.isEditing = editorHasFocus
            if editorHasFocus { keepCaretInSight() }
        case "selectionChanged":
            onFormatting?(NoteFormatting(
                bold: body["bold"] as? Bool ?? false,
                italic: body["italic"] as? Bool ?? false,
                bulletList: body["bulletList"] as? Bool ?? false,
                orderedList: body["orderedList"] as? Bool ?? false,
                blockquote: body["blockquote"] as? Bool ?? false,
                link: body["link"] as? Bool ?? false
            ))
        case "terminated":
            // The page's process was ended, by the system most likely. A new
            // page takes the text the person last had.
            let text = lastReported
            page?.webView.removeFromSuperview()
            page = nil
            attach(key: key, markdown: text, fontSize: 16)
        default:
            break
        }
    }

    // MARK: Keeping the caret in sight

    @objc private func keyboardChanged(_ note: Notification) {
        if note.name == UIResponder.keyboardWillHideNotification {
            Self.keyboardFrame = .null
        } else if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            Self.keyboardFrame = frame
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.keepCaretInSight() }
    }

    /// The list scrolled to show the top of the section, its heading and the
    /// passage above it, which is where the list is best left while it is
    /// written, so far as the caret allows.
    private var sectionTopOffset: CGFloat? {
        guard let list = enclosingList,
              let cell = sequence(first: superview, next: { $0?.superview })
                .first(where: { $0 is UICollectionViewCell }) ?? nil
        else { return nil }
        return cell.convert(cell.bounds, to: list).minY - list.adjustedContentInset.top
    }

    private var enclosingList: UIScrollView? {
        sequence(first: superview, next: { $0?.superview }).compactMap { $0 as? UIScrollView }.first
    }

    /// The page cannot scroll itself, being as tall as its text, so the list
    /// it sits in is scrolled to keep the caret clear of the keyboard and of
    /// the panel's header: as near to showing the top of the section as that
    /// allows, so its heading and passage stay in view while the note fits.
    private func keepCaretInSight() {
        guard editorHasFocus, let caret, let window, let list = enclosingList else { return }
        let inList = convert(caret, to: list)
        let top = list.adjustedContentInset.top
        var height = list.bounds.height
        if !Self.keyboardFrame.isNull {
            let keyboard = list.convert(window.convert(Self.keyboardFrame, from: nil), from: nil)
            height = max(0, min(list.bounds.maxY, keyboard.minY) - list.bounds.minY)
        }
        let margin: CGFloat = 12
        // The offsets that show the caret, between the header and the keyboard.
        let lowest = inList.maxY + margin - height
        let highest = inList.minY - margin - top
        let wanted = sectionTopOffset ?? list.contentOffset.y
        var target = lowest > highest ? lowest : min(max(wanted, lowest), highest)
        let maxOffset = max(-top, list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height)
        target = min(max(target, -top), maxOffset)
        guard abs(target - list.contentOffset.y) > 0.5 else { return }
        list.setContentOffset(CGPoint(x: list.contentOffset.x, y: target), animated: true)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            let isDark = traitCollection.userInterfaceStyle == .dark
            page?.run("window.editorAPI.setTheme(\(isDark))")
        }
    }
}

/// The section being edited, in the warm note page.
struct PooledNoteEditor: UIViewRepresentable {
    /// Which section this is, across rebuilds of the list around it.
    let key: String
    let markdown: String
    let fontSize: CGFloat
    let handle: NoteEditorHandle
    let onContent: (String) -> Void
    let onHeight: (CGFloat) -> Void
    let onFootnote: () -> Void

    func makeUIView(context: Context) -> NoteEditorHostView {
        let view = NoteEditorHostView()
        wire(view)
        let point = handle.focusOnOpen
        handle.focusOnOpen = nil
        handle.host = view
        handle.onFootnote = onFootnote
        // A section opens as another closes, and SwiftUI makes the new editor
        // before it takes down the old: one turn later the old has given the
        // warm page back, so the new one takes it rather than starting cold.
        DispatchQueue.main.async { [key, markdown, fontSize, handle] in
            view.attach(key: key, markdown: markdown, fontSize: fontSize, focusAt: point, handle: handle)
        }
        return view
    }

    func updateUIView(_ view: NoteEditorHostView, context: Context) {
        wire(view)
        handle.host = view
        handle.onFootnote = onFootnote
        // Only a change from outside the editor: its own edits come back the
        // same as what it last reported.
        view.replace(with: markdown)
        if context.coordinator.fontSize != fontSize {
            context.coordinator.fontSize = fontSize
            view.applyAppearance(fontSize: fontSize)
        }
    }

    static func dismantleUIView(_ view: NoteEditorHostView, coordinator: Coordinator) {
        view.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(fontSize: fontSize) }

    final class Coordinator {
        var fontSize: CGFloat
        init(fontSize: CGFloat) { self.fontSize = fontSize }
    }

    private func wire(_ view: NoteEditorHostView) {
        view.onContent = onContent
        view.onHeight = onHeight
        view.onFormatting = { [weak handle] formatting in
            if handle?.formatting != formatting { handle?.formatting = formatting }
        }
    }
}

/// A note section open in the editor: its formatting bar, and the editor at
/// the height of its text.
struct NoteSectionEditor: View {
    let key: String
    let content: String
    let fontSize: CGFloat
    @ObservedObject var handle: NoteEditorHandle
    let onContent: (String) -> Void
    let onFootnote: () -> Void

    @State private var height: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !handle.barIsOnKeyboard {
                NoteFormattingBar(handle: handle, onFootnote: onFootnote)
            }
            PooledNoteEditor(
                key: key, markdown: content, fontSize: fontSize, handle: handle,
                onContent: onContent,
                onHeight: { newHeight in
                    let fitted = max(newHeight, 44)
                    if abs(fitted - height) > 0.5 { height = fitted }
                },
                onFootnote: onFootnote
            )
            .frame(height: height)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The note editor's formatting, as the Mac's note editor offers it.
struct NoteFormattingBar: View {
    @ObservedObject var handle: NoteEditorHandle
    let onFootnote: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            toggle("bold", "Bold", on: handle.formatting.bold) { handle.run("toggleBold()") }
            toggle("italic", "Italic", on: handle.formatting.italic) { handle.run("toggleItalic()") }
            toggle("list.bullet", "Bulleted list", on: handle.formatting.bulletList) { handle.run("toggleBulletList()") }
            toggle("list.number", "Numbered list", on: handle.formatting.orderedList) { handle.run("toggleOrderedList()") }
            toggle("text.quote", "Quote", on: handle.formatting.blockquote) { handle.run("toggleBlockquote()") }
            if handle.formatting.link {
                toggle("link.badge.minus", "Remove link", on: false) { handle.run("removeLink()") }
            }
            // Footnotes are not offered in notes for now; ones already written
            // are still shown, and open to edit, below the note.
            Spacer(minLength: 0)
            toggle("keyboard.chevron.compact.down", "Dismiss keyboard", on: false) { handle.dismissKeyboard() }
        }
        .font(.system(size: 15))
    }

    private func toggle(_ icon: String, _ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 34, height: 30)
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .background(on ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
