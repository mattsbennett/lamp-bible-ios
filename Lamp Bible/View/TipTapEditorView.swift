//
//  TipTapEditorView.swift
//  Lamp Bible
//

import SwiftUI
import UIKit
import WebKit

/// Container that holds WKWebView and can embed a SwiftUI header
class TipTapWebViewContainer: UIView, UIScrollViewDelegate {
    let webView: WKWebView
    private var headerHostingController: UIHostingController<AnyView>?
    private var headerContainerView: UIView?
    private var headerHeight: CGFloat = 0
    private var currentViewMode: DevotionalViewMode?
    private var showsHeader = false
    private var headerScrolledAway = false
    var onHeaderHeightChange: ((CGFloat) -> Void)?
    /// Below the writing while it's read: the host's own section, a
    /// writing's other files. Kept inside the page's scroll view, where it
    /// scrolls with the page and a drag on it scrolls the page, in space the
    /// page leaves for it at its foot (`onFooterHeightChange`).
    private var footerHostingController: UIHostingController<AnyView>?
    private var footerContainerView: UIView?
    private var footerHeight: CGFloat = 0
    private var showsFooter = false
    private var contentSizeObservation: NSKeyValueObservation?
    var onFooterHeightChange: ((CGFloat) -> Void)?
    /// Told when the header scrolls up out of sight and back, so the host
    /// can put the title in its bar while the header is hidden.
    var onHeaderScrolledAway: ((Bool) -> Void)?
    /// The media refs the editor's map was last built from, and the map: an
    /// update comes with every keystroke, and building the map looks for
    /// each file on disk. A map missing a file is built again next update,
    /// so a file that arrives late still shows.
    var mediaMapKey: String?
    var mediaMap: [String: String] = [:]
    var mediaMapComplete = false

    override init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        // Apple's Writing Tools only with the AI features on, fixed when the
        // editor opens.
        config.writingToolsBehavior = AIFeatures.shared.writingTools

        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)

        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.scrollView.delegate = self

        clipsToBounds = true
        addSubview(webView)
        contentSizeObservation = webView.scrollView.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateFooterPosition() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        updateHeaderFrame()
        updateFooterFrame()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }


    /// `shows` is whether the header is drawn at all: in reading, and while
    /// writing in the visual editor, where the title tops the page as it will
    /// read.
    func setHeader<Content: View>(_ content: Content?, for viewMode: DevotionalViewMode, shows: Bool) {
        let modeChanged = currentViewMode != viewMode
        currentViewMode = viewMode
        showsHeader = shows && content != nil

        // Create the hosting controller once and reuse it across mode switches.
        // Destroying and recreating it caused inconsistent sizeThatFits measurements
        // because the new controller's safe area state varied depending on web view
        // state at creation time (e.g. after switchToRichText DOM changes).
        if let content = content {
            if headerHostingController == nil {
                let container = UIView()
                addSubview(container)
                headerContainerView = container

                let hostingController = UIHostingController(rootView: AnyView(content.ignoresSafeArea()))
                if #available(iOS 16.0, *) {
                    hostingController.safeAreaRegions = []
                }
                hostingController.view.backgroundColor = .clear
                hostingController.view.insetsLayoutMarginsFromSafeArea = false
                hostingController.view.layoutMargins = .zero
                hostingController.view.preservesSuperviewLayoutMargins = false
                container.addSubview(hostingController.view)
                headerHostingController = hostingController
            } else {
                headerHostingController?.rootView = AnyView(content.ignoresSafeArea())
                headerHostingController?.view.invalidateIntrinsicContentSize()
            }
        }

        if showsHeader {
            headerContainerView?.isHidden = false
            if modeChanged && viewMode == .read {
                webView.scrollView.contentOffset = .zero
            }
            setNeedsLayout()
        } else {
            headerContainerView?.isHidden = true
            headerHeight = 0
            reportHeaderScrolledAway(false)
        }
    }

    /// `shows` is whether the footer is drawn: only in reading.
    func setFooter(_ content: AnyView?, shows: Bool) {
        showsFooter = shows && content != nil
        if let content {
            // Its own height, said whenever it changes: a section folded or
            // opened inside it changes it without the host updating.
            let content = AnyView(
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] _ in
                        self?.setNeedsLayout()
                    }
                    .ignoresSafeArea()
            )
            if footerHostingController == nil {
                let container = UIView()
                webView.scrollView.addSubview(container)
                footerContainerView = container
                let hostingController = UIHostingController(rootView: content)
                hostingController.safeAreaRegions = []
                hostingController.view.backgroundColor = .clear
                container.addSubview(hostingController.view)
                footerHostingController = hostingController
            } else {
                footerHostingController?.rootView = content
                footerHostingController?.view.invalidateIntrinsicContentSize()
            }
        }
        footerContainerView?.isHidden = !showsFooter
        if showsFooter {
            setNeedsLayout()
        } else if footerHeight != 0 {
            footerHeight = 0
            onFooterHeightChange?(0)
        }
    }

    /// Between the writing's end and the footer.
    static let footerGap: CGFloat = 24
    /// Below the footer, so its last line scrolls clear of the floating
    /// bottom bar.
    static let footerClearance: CGFloat = 120
    /// Where the writing ends on the page, as the page last said.
    private var proseEnd: CGFloat?

    func setProseEnd(_ y: CGFloat) {
        guard y != proseEnd else { return }
        proseEnd = y
        updateFooterPosition()
    }

    private func updateFooterFrame() {
        guard showsFooter, let footerView = footerHostingController?.view, bounds.width > 0 else { return }
        footerView.setNeedsLayout()
        footerView.layoutIfNeeded()
        let targetSize = CGSize(width: bounds.width - 40, height: .greatestFiniteMagnitude)
        let size = footerHostingController?.sizeThatFits(in: targetSize) ?? .zero
        let frame = CGRect(x: 20, y: 0, width: bounds.width - 40, height: size.height)
        if footerView.frame != frame { footerView.frame = frame }
        let height = ceil(size.height)
        if height != footerHeight {
            footerHeight = height
            onFooterHeightChange?(height)
        }
        updateFooterPosition()
    }

    private func updateFooterPosition() {
        guard showsFooter, let container = footerContainerView, footerHeight > 0 else { return }
        let contentHeight = webView.scrollView.contentSize.height
        let top = proseEnd.map { $0 + Self.footerGap }
            ?? contentHeight - Self.footerClearance - footerHeight
        // Only when it moves: the scroll view answers a subview's change by
        // working out its content again, which calls back here.
        let frame = CGRect(x: 0, y: max(0, top), width: bounds.width, height: footerHeight)
        if container.frame != frame { container.frame = frame }
        if webView.scrollView.subviews.last !== container { webView.scrollView.bringSubviewToFront(container) }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateHeaderPosition()
    }

    private func reportHeaderScrolledAway(_ away: Bool) {
        guard away != headerScrolledAway else { return }
        headerScrolledAway = away
        onHeaderScrolledAway?(away)
    }

    func updateHeaderFrame() {
        guard showsHeader,
              let headerView = headerHostingController?.view,
              bounds.width > 0 else { return }

        let safeTop = safeAreaInsets.top

        headerView.setNeedsLayout()
        headerView.layoutIfNeeded()

        let targetSize = CGSize(width: bounds.width - 40, height: .greatestFiniteMagnitude)
        let headerSize: CGSize
        if #available(iOS 16.0, *) {
            headerSize = headerHostingController?.sizeThatFits(in: targetSize) ?? .zero
        } else {
            headerSize = headerView.systemLayoutSizeFitting(
                targetSize,
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
        }

        headerHeight = headerSize.height + 24
        headerView.frame = CGRect(x: 20, y: 8, width: bounds.width - 40, height: headerSize.height)
        onHeaderHeightChange?(safeTop + headerHeight)
        updateHeaderPosition()
    }

    private func updateHeaderPosition() {
        guard let container = headerContainerView, headerHeight > 0 else { return }

        let scrollY = webView.scrollView.contentOffset.y
        let safeTop = safeAreaInsets.top
        // Header position tracks scroll - at scroll 0, header is below the safe area
        container.frame = CGRect(x: 0, y: safeTop - scrollY, width: bounds.width, height: headerHeight)
        // Away once the title line itself has gone under the bar.
        reportHeaderScrolledAway(scrollY > max(headerHeight - 40, 40))
    }
}

/// SwiftUI wrapper for the TipTap editor running inside a WKWebView.
struct TipTapEditorView<Header: View>: UIViewRepresentable {
    @Binding var markdownContent: String
    var fontSize: CGFloat
    var editMode: DevotionalEditMode
    var viewMode: DevotionalViewMode
    var mediaRefs: [DevotionalMediaReference]?
    var devotionalId: String?
    var moduleId: String?
    var header: Header?
    var showsHeader: Bool = false
    var footer: AnyView?
    var showsFooter: Bool = false
    var onHeaderScrolledAway: ((Bool) -> Void)?
    var onCoordinatorReady: ((TipTapEditorCoordinator) -> Void)?

    init(
        markdownContent: Binding<String>,
        fontSize: CGFloat,
        editMode: DevotionalEditMode,
        viewMode: DevotionalViewMode,
        mediaRefs: [DevotionalMediaReference]? = nil,
        devotionalId: String? = nil,
        moduleId: String? = nil,
        header: Header?,
        showsHeader: Bool,
        footer: AnyView? = nil,
        showsFooter: Bool = false,
        onHeaderScrolledAway: ((Bool) -> Void)? = nil,
        onCoordinatorReady: ((TipTapEditorCoordinator) -> Void)? = nil
    ) {
        self._markdownContent = markdownContent
        self.fontSize = fontSize
        self.editMode = editMode
        self.viewMode = viewMode
        self.mediaRefs = mediaRefs
        self.devotionalId = devotionalId
        self.moduleId = moduleId
        self.header = header
        self.showsHeader = showsHeader
        self.footer = footer
        self.showsFooter = showsFooter
        self.onHeaderScrolledAway = onHeaderScrolledAway
        self.onCoordinatorReady = onCoordinatorReady
    }

    func makeCoordinator() -> TipTapEditorCoordinator {
        TipTapEditorCoordinator()
    }

    func makeUIView(context: Context) -> TipTapWebViewContainer {
        let container = TipTapWebViewContainer()
        let webView = container.webView
        let coordinator = context.coordinator

        container.onHeaderHeightChange = { [weak coordinator] padding in
            coordinator?.setReadPadding(top: padding)
        }
        container.onFooterHeightChange = { [weak coordinator] height in
            coordinator?.setFooterSpace(height)
        }
        coordinator.onProseEnd = { [weak container] y in container?.setProseEnd(y) }

        // Register message handler
        webView.configuration.userContentController.add(coordinator, name: "tiptapBridge")
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        // Set up onReady callback - capture binding directly
        let contentBinding = $markdownContent
        let initialContent = markdownContent
        let mediaMap = buildMediaMap()
        container.mediaMapKey = mediaMapKey
        container.mediaMap = mediaMap
        container.mediaMapComplete = mediaMap.count == (mediaRefs?.count ?? 0)
        let initialEditMode = editMode
        let initialFontSize = fontSize
        let initialViewMode = viewMode
        let readyCallback = onCoordinatorReady

        coordinator.onReady = { [weak container] in
            DispatchQueue.main.async {
                coordinator.setContent(initialContent)
                // The latest map: a page loaded again holds none of it.
                coordinator.setMediaMap(container?.mediaMap ?? mediaMap)
                if initialEditMode == .markdown {
                    coordinator.switchToMarkdown()
                }
                let isDark = UITraitCollection.current.userInterfaceStyle == .dark
                coordinator.setTheme(isDark: isDark)
                coordinator.setFontSize(initialFontSize)
                coordinator.setMode(initialViewMode.rawValue)
                readyCallback?(coordinator)

                // Update header after content is set - with delay to let layout settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    container?.updateHeaderFrame()
                }
            }
        }

        // Set up content changed callback - use binding's wrappedValue setter
        coordinator.onContentChanged = { markdown in
            DispatchQueue.main.async {
                contentBinding.wrappedValue = markdown
            }
        }

        // Load the editor HTML
        if let page = TipTapPage.editorPage() {
            webView.loadFileURL(page.url, allowingReadAccessTo: page.readable)
        } else {
            print("[TipTapEditorView] ERROR: TipTapEditor/index.html not found in bundle!")
        }

        return container
    }

    func updateUIView(_ container: TipTapWebViewContainer, context: Context) {
        let coordinator = context.coordinator

        container.onHeaderHeightChange = { [weak coordinator] padding in
            coordinator?.setReadPadding(top: padding)
        }
        container.onHeaderScrolledAway = onHeaderScrolledAway
        container.onFooterHeightChange = { [weak coordinator] height in
            coordinator?.setFooterSpace(height)
        }
        coordinator.onProseEnd = { [weak container] y in container?.setProseEnd(y) }

        // Update the content changed callback with fresh binding reference
        let contentBinding = $markdownContent
        coordinator.onContentChanged = { markdown in
            DispatchQueue.main.async {
                contentBinding.wrappedValue = markdown
            }
        }

        // Update font size if changed
        coordinator.setFontSize(fontSize)

        // Update theme
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
        coordinator.setTheme(isDark: isDark)

        // Ensure richtext mode before leaving edit, so markdown is converted
        // back to HTML before the mode-read CSS class is applied.
        if viewMode != .edit {
            coordinator.switchToRichText()
        }

        // Sync view mode
        coordinator.setMode(viewMode.rawValue)

        // Sync edit mode (only relevant in edit view mode)
        if viewMode == .edit {
            if editMode == .markdown {
                coordinator.switchToMarkdown()
            } else {
                coordinator.switchToRichText()
            }
        }

        // Update media map when refs change
        let key = mediaMapKey
        if key != container.mediaMapKey || !container.mediaMapComplete {
            let map = buildMediaMap()
            let changed = key != container.mediaMapKey || map != container.mediaMap
            container.mediaMapKey = key
            container.mediaMap = map
            container.mediaMapComplete = map.count == (mediaRefs?.count ?? 0)
            if changed { coordinator.setMediaMap(map) }
        }

        // Update header
        container.setHeader(header, for: viewMode, shows: showsHeader)
        container.setFooter(footer, shows: showsFooter && viewMode == .read)
    }

    static func dismantleUIView(_ container: TipTapWebViewContainer, coordinator: TipTapEditorCoordinator) {
        container.webView.configuration.userContentController.removeScriptMessageHandler(forName: "tiptapBridge")
    }

    // MARK: - Helpers

    /// What the media map is built from: the writing, its module, and each
    /// ref's id and file.
    private var mediaMapKey: String {
        let refs = (mediaRefs ?? []).map { "\($0.id)=\($0.filename)" }.joined(separator: ",")
        return "\(devotionalId ?? "")|\(moduleId ?? "")|\(refs)"
    }

    private func buildMediaMap() -> [String: String] {
        guard let refs = mediaRefs,
              let devId = devotionalId,
              let modId = moduleId else { return [:] }

        var map: [String: String] = [:]
        for ref in refs {
            if let url = DevotionalMediaStorage.shared.getMediaURL(for: ref, devotionalId: devId, moduleId: modId) {
                map[ref.id] = url.absoluteString
            }
        }
        return map
    }
}

// Convenience initializer without header
extension TipTapEditorView where Header == EmptyView {
    init(
        markdownContent: Binding<String>,
        fontSize: CGFloat,
        editMode: DevotionalEditMode,
        viewMode: DevotionalViewMode,
        mediaRefs: [DevotionalMediaReference]? = nil,
        devotionalId: String? = nil,
        moduleId: String? = nil,
        onCoordinatorReady: ((TipTapEditorCoordinator) -> Void)? = nil
    ) {
        self._markdownContent = markdownContent
        self.fontSize = fontSize
        self.editMode = editMode
        self.viewMode = viewMode
        self.mediaRefs = mediaRefs
        self.devotionalId = devotionalId
        self.moduleId = moduleId
        self.header = nil
        self.onCoordinatorReady = onCoordinatorReady
    }
}
