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
    var onHeaderHeightChange: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        updateHeaderFrame()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }


    func setHeader<Content: View>(_ content: Content?, for viewMode: DevotionalViewMode) {
        let modeChanged = currentViewMode != viewMode
        currentViewMode = viewMode

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

        if viewMode == .read {
            headerContainerView?.isHidden = false
            if modeChanged {
                webView.scrollView.contentOffset = .zero
            }
            setNeedsLayout()
        } else {
            headerContainerView?.isHidden = true
            headerHeight = 0
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateHeaderPosition()
    }

    func updateHeaderFrame() {
        guard currentViewMode == .read,
              let headerView = headerHostingController?.view,
              bounds.width > 0 else { return }

        let safeTop = safeAreaInsets.top

        headerView.setNeedsLayout()
        headerView.layoutIfNeeded()

        let targetSize = CGSize(width: bounds.width - 32, height: .greatestFiniteMagnitude)
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
        headerView.frame = CGRect(x: 16, y: 8, width: bounds.width - 32, height: headerSize.height)
        onHeaderHeightChange?(safeTop + headerHeight)
        updateHeaderPosition()
    }

    private func updateHeaderPosition() {
        guard let container = headerContainerView, headerHeight > 0 else { return }

        let scrollY = webView.scrollView.contentOffset.y
        let safeTop = safeAreaInsets.top
        // Header position tracks scroll - at scroll 0, header is below the safe area
        container.frame = CGRect(x: 0, y: safeTop - scrollY, width: bounds.width, height: headerHeight)
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

        // Register message handler
        webView.configuration.userContentController.add(coordinator, name: "tiptapBridge")
        webView.navigationDelegate = coordinator
        coordinator.webView = webView

        // Set up onReady callback - capture binding directly
        let contentBinding = $markdownContent
        let initialContent = markdownContent
        let mediaMap = buildMediaMap()
        let initialEditMode = editMode
        let initialFontSize = fontSize
        let initialViewMode = viewMode
        let readyCallback = onCoordinatorReady

        coordinator.onReady = { [weak container] in
            DispatchQueue.main.async {
                coordinator.setContent(initialContent)
                coordinator.setMediaMap(mediaMap)
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
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let editorDir = documentsDir.appendingPathComponent("TipTapEditorCache", isDirectory: true)
        let destHTML = editorDir.appendingPathComponent("index.html")

        if let bundleHTML = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "TipTapEditor") {
            try? FileManager.default.createDirectory(at: editorDir, withIntermediateDirectories: true)

            var shouldCopy = true
            if FileManager.default.fileExists(atPath: destHTML.path) {
                if let bundleDate = try? FileManager.default.attributesOfItem(atPath: bundleHTML.path)[.modificationDate] as? Date,
                   let destDate = try? FileManager.default.attributesOfItem(atPath: destHTML.path)[.modificationDate] as? Date {
                    shouldCopy = bundleDate > destDate
                }
            }

            if shouldCopy {
                try? FileManager.default.removeItem(at: destHTML)
                try? FileManager.default.copyItem(at: bundleHTML, to: destHTML)
            }

            webView.loadFileURL(destHTML, allowingReadAccessTo: documentsDir)
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
        coordinator.setMediaMap(buildMediaMap())

        // Update header
        container.setHeader(header, for: viewMode)
    }

    static func dismantleUIView(_ container: TipTapWebViewContainer, coordinator: TipTapEditorCoordinator) {
        container.webView.configuration.userContentController.removeScriptMessageHandler(forName: "tiptapBridge")
    }

    // MARK: - Helpers

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
