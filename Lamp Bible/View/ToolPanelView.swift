//
//  ToolPanelView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import GRDB
import RealmSwift
import SwiftUI
import UIKit

// MARK: - Scroll Sync Coordinator

/// Direct coordinator for scroll sync - bypasses SwiftUI state entirely
class ScrollSyncCoordinator {
    static let shared = ScrollSyncCoordinator()

    // Registered scroll controllers
    private weak var toolPanelController: (any ToolPanelScrollable)?

    // Direct reader scroll view reference for UIKit-based scrolling
    weak var readerScrollView: UIScrollView?
    // Raw verseId -> yPosition (set by ReaderScrollSpyView)
    private var readerVersePositions: [Int: CGFloat] = [:]
    // Cached verseNumber -> yPosition for fast lookup
    private var readerVerseNumberPositions: [Int: CGFloat] = [:]
    // Cached sorted verseNumbers for closest-preceding search
    private var sortedReaderVerseNumbers: [Int] = []

    // Current state
    private(set) var currentVerse: Int = 1
    private(set) var activeScroller: ScrollSource = .none
    private var lastReportedReaderVerse: Int = 0

    // Throttle reader scrolling driven by tool panel (avoids hammering setContentOffset)
    private var lastReaderScrollTime: CFTimeInterval = 0
    private let minReaderScrollInterval: CFTimeInterval = 1.0 / 60.0 // ~60 Hz

    // Check if scroll linking is enabled (reads from UserDefaults, defaults to true)
    private var isScrollLinked: Bool {
        // AppStorage defaults to true, so we need to match that behavior
        if UserDefaults.standard.object(forKey: "toolPanelScrollLinked") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "toolPanelScrollLinked")
    }

    enum ScrollSource {
        case none
        case reader
        case toolPanel
    }

    private init() {}

    func updateReaderVersePositions(_ positions: [Int: CGFloat]) {
        readerVersePositions = positions

        // Build verse-number caches (chapter-local) once, not during scrolling.
        var verseNumToY: [Int: CGFloat] = [:]
        verseNumToY.reserveCapacity(positions.count)

        for (verseId, y) in positions {
            let v = verseId % 1000
            // If duplicates exist (unlikely), keep the smallest y (earliest in scroll).
            if let existing = verseNumToY[v] {
                verseNumToY[v] = min(existing, y)
            } else {
                verseNumToY[v] = y
            }
        }

        readerVerseNumberPositions = verseNumToY
        sortedReaderVerseNumbers = verseNumToY.keys.sorted()
    }

    func registerToolPanel(_ controller: any ToolPanelScrollable) {
        toolPanelController = controller
    }

    /// Called by reader when user scrolls - direct from UIKit
    func readerDidScrollToVerse(_ verse: Int) {
        guard isScrollLinked else { return }
        guard activeScroller != .toolPanel else { return }
        // Update currentVerse for state tracking
        currentVerse = verse
        activeScroller = .reader
        // Direct call - no throttling since we're using lightweight setContentOffset
        toolPanelController?.scrollToVerse(verse, animated: false)
    }

    /// Called by tool panel when user scrolls
    func toolPanelDidScrollToVerse(_ verse: Int) {
        guard isScrollLinked else { return }
        guard activeScroller != .reader else { return }
        // Update currentVerse for state tracking
        currentVerse = verse
        activeScroller = .toolPanel

        // Direct UIKit scroll - no SwiftUI state involved
        scrollReaderToVerse(verse)
    }

    /// Scroll the reader directly via UIKit
    private func scrollReaderToVerse(_ verse: Int) {
        guard let scrollView = readerScrollView else { return }

        // Rate-limit setContentOffset calls.
        let now = CACurrentMediaTime()
        if now - lastReaderScrollTime < minReaderScrollInterval {
            return
        }
        lastReaderScrollTime = now

        // Find matching y or closest preceding verse number using cached lookup.
        var targetY: CGFloat? = readerVerseNumberPositions[verse]
        if targetY == nil, !sortedReaderVerseNumbers.isEmpty {
            // Binary search for last verseNumber <= verse
            var low = 0
            var high = sortedReaderVerseNumbers.count - 1
            var best: Int? = nil
            while low <= high {
                let mid = (low + high) / 2
                let v = sortedReaderVerseNumbers[mid]
                if v <= verse {
                    best = v
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            if let best, let y = readerVerseNumberPositions[best] {
                targetY = y
            }
        }

        if let y = targetY {
            // Account for safe area (notch) plus SwiftUI navigation toolbar (~44pt)
            let topOffset = scrollView.safeAreaInsets.top + 44
            let adjustedY = y - topOffset

            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let clampedY = min(max(0, adjustedY), maxY)

            // Skip tiny adjustments to avoid churn.
            if abs(scrollView.contentOffset.y - clampedY) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
            }
        }
    }

    /// Called when drag ends to reset active scroller
    func scrollEnded(from source: ScrollSource) {
        // Reset active scroller when scroll ends
        activeScroller = .none
    }

    /// Called when drag begins
    func readerBeganScrolling() {
        activeScroller = .reader
    }

    func toolPanelBeganScrolling() {
        activeScroller = .toolPanel
    }
}

protocol ToolPanelScrollable: AnyObject {
    func scrollToVerse(_ verse: Int, animated: Bool)
}

// MARK: - Reader Scroll Spy

/// Invisible UIView that intercepts scroll events from the parent SwiftUI ScrollView
class ReaderScrollSpyView: UIView, UIScrollViewDelegate {
    private weak var scrollView: UIScrollView?
    private var originalDelegate: UIScrollViewDelegate?
    private let coordinator = ScrollSyncCoordinator.shared
    private var lastReportedVerseId: Int = 0
    private var lastProcessedOffset: CGFloat = 0
    private var isReady: Bool = false // Prevents sync during initial load
    private var isUserScrolling: Bool = false // Track if user is actively scrolling

    // Cached sorted positions for fast lookup during scrolling
    private var sortedVersePositions: [(verseId: Int, yPos: CGFloat)] = []

    // Optional callback for SwiftUI to observe verse changes without doing expensive geometry tracking
    var onVerseIdChange: ((Int) -> Void)?

    // Optional callback fired when user scroll ends (drag end without decel, or decel end)
    // Provides the last reported verseId (full id, not just verse number).
    var onUserScrollEndedAtVerseId: ((Int) -> Void)?

    // Optional callback fired when user scroll completely stops (including deceleration)
    var onScrollFullyStopped: (() -> Void)?

    // Verse position lookup - set by ReaderView
    var versePositions: [Int: CGFloat] = [:] {
        didSet {
            coordinator.updateReaderVersePositions(versePositions)
            // Pre-sort once when positions update (positions can be large; don't sort during scroll)
            sortedVersePositions = versePositions
                .map { (verseId: $0.key, yPos: $0.value) }
                .sorted { $0.yPos < $1.yPos }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Find and intercept the parent scroll view
            DispatchQueue.main.async { [weak self] in
                self?.findAndInterceptScrollView()
            }
            // Enable sync after initial load settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.isReady = true
            }
        }
    }

    private func findAndInterceptScrollView() {
        guard scrollView == nil else { return }

        // Walk up the view hierarchy to find UIScrollView
        var view: UIView? = self.superview
        while let v = view {
            if let sv = v as? UIScrollView {
                scrollView = sv
                coordinator.readerScrollView = sv
                originalDelegate = sv.delegate
                sv.delegate = self
                return
            }
            view = v.superview
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Forward to original delegate
        originalDelegate?.scrollViewDidScroll?(scrollView)

        // Skip during initial load
        guard isReady else { return }

        // Skip if tool panel is in control
        guard coordinator.activeScroller != .toolPanel else { return }

        // Calculate which verse is at the top of the visible area
        let offset = scrollView.contentOffset.y + scrollView.safeAreaInsets.top

        if let verseId = findVerseIdAtOffset(offset) {
            let verseNumber = verseId % 1000
            let lastReportedVerseNumber = lastReportedVerseId % 1000

            // Only sync if verse NUMBER changed (not full ID)
            if verseNumber != lastReportedVerseNumber {
                lastReportedVerseId = verseId
                lastProcessedOffset = offset
                // Direct sync - no throttling
                coordinator.readerDidScrollToVerse(verseNumber)
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        originalDelegate?.scrollViewWillBeginDragging?(scrollView)
        isUserScrolling = true
        coordinator.readerBeganScrolling()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        originalDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        if !decelerate {
            // Scroll stopped immediately - sync tool panel now
            isUserScrolling = false
            coordinator.scrollEnded(from: .reader)
            coordinator.readerDidScrollToVerse(lastReportedVerseId % 1000)
            onUserScrollEndedAtVerseId?(lastReportedVerseId)
            onScrollFullyStopped?()
            onVerseIdChange?(lastReportedVerseId)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        originalDelegate?.scrollViewDidEndDecelerating?(scrollView)
        // Deceleration finished - sync tool panel now
        isUserScrolling = false
        coordinator.scrollEnded(from: .reader)
        coordinator.readerDidScrollToVerse(lastReportedVerseId % 1000)
        onUserScrollEndedAtVerseId?(lastReportedVerseId)
        onScrollFullyStopped?()
        onVerseIdChange?(lastReportedVerseId)
    }

    // Forward other delegate methods
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        return originalDelegate?.scrollViewShouldScrollToTop?(scrollView) ?? true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        originalDelegate?.scrollViewDidScrollToTop?(scrollView)
    }

    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        originalDelegate?.scrollViewWillBeginDecelerating?(scrollView)
    }

    private func findVerseIdAtOffset(_ offset: CGFloat) -> Int? {
        guard !sortedVersePositions.isEmpty else { return nil }

        // We want the last verse whose yPos <= offset + 50
        let target = offset + 50
        var low = 0
        var high = sortedVersePositions.count - 1
        var bestIndex: Int? = nil

        while low <= high {
            let mid = (low + high) / 2
            if sortedVersePositions[mid].yPos <= target {
                bestIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard let idx = bestIndex else { return nil }
        return sortedVersePositions[idx].verseId
    }
}

/// SwiftUI wrapper for the scroll spy
struct ReaderScrollSpy: UIViewRepresentable {
    let versePositions: [Int: CGFloat]
    var onVerseIdChange: ((Int) -> Void)? = nil
    var onUserScrollEndedAtVerseId: ((Int) -> Void)? = nil
    var onScrollFullyStopped: (() -> Void)? = nil

    func makeUIView(context: Context) -> ReaderScrollSpyView {
        let view = ReaderScrollSpyView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: ReaderScrollSpyView, context: Context) {
        uiView.versePositions = versePositions
        uiView.onVerseIdChange = onVerseIdChange
        uiView.onUserScrollEndedAtVerseId = onUserScrollEndedAtVerseId
        uiView.onScrollFullyStopped = onScrollFullyStopped
    }
}

// MARK: - UIKit Collection View for Scroll Sync

/// Item type for verse-based content in the collection view
struct VerseItem: Hashable {
    let verse: Int
    let id: String // Unique identifier for diffable data source
}

/// SwiftUI wrapper for UIKit collection view - scroll sync handled by coordinator
struct UIKitVerseList<ItemData, CellContent: View>: UIViewControllerRepresentable {
    let items: [(verse: Int, data: ItemData)]
    let cellContent: (ItemData) -> CellContent
    let listId: String // Force recreation when this changes

    class Coordinator {
        var lastListId: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIKitVerseListController<ItemData, CellContent> {
        let vc = UIKitVerseListController<ItemData, CellContent>()
        vc.cellContent = cellContent
        return vc
    }

    func updateUIViewController(_ uiViewController: UIKitVerseListController<ItemData, CellContent>, context: Context) {
        uiViewController.cellContent = cellContent

        // Check if list changed (book/chapter change)
        let listChanged = context.coordinator.lastListId != listId
        context.coordinator.lastListId = listId

        let verseItems = items.enumerated().map { index, item in
            VerseItem(verse: item.verse, id: "\(listId)_\(index)_\(item.verse)")
        }
        uiViewController.updateItems(verseItems, rawData: items.map { $0.data })

        // Scroll to current verse on list change
        if listChanged {
            let currentVerse = ScrollSyncCoordinator.shared.currentVerse
            uiViewController.scrollToVerse(currentVerse)
        }
    }
}

/// Generic UICollectionView controller for verse-based content
class UIKitVerseListController<ItemData, CellContent: View>: UIViewController, UICollectionViewDelegate, ToolPanelScrollable {
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, VerseItem>!

    // Content configuration
    var cellContent: ((ItemData) -> CellContent)?
    private var rawData: [ItemData] = []

    // Direct coordinator reference - no SwiftUI state
    private let scrollCoordinator = ScrollSyncCoordinator.shared

    // Scroll state
    private var lastReportedVerse: Int = 0
    private var isProgrammaticScroll: Bool = false
    private var items: [VerseItem] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCollectionView()
        setupDataSource()
        // Register with coordinator for direct scroll sync
        scrollCoordinator.registerToolPanel(self)
    }

    private func setupCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.contentInsetAdjustmentBehavior = .automatic

        view.addSubview(collectionView)
    }

    private func setupDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewCell, VerseItem> { [weak self] cell, indexPath, item in
            guard let self = self,
                  let cellContent = self.cellContent,
                  indexPath.item < self.rawData.count else { return }

            let data = self.rawData[indexPath.item]
            cell.contentConfiguration = UIHostingConfiguration {
                cellContent(data)
            }
            .margins(.all, 0)
        }

        dataSource = UICollectionViewDiffableDataSource<Int, VerseItem>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
    }

    func updateItems(_ newItems: [VerseItem], rawData: [ItemData]) {
        self.items = newItems
        self.rawData = rawData

        var snapshot = NSDiffableDataSourceSnapshot<Int, VerseItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(newItems)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func scrollToVerse(_ verse: Int, animated: Bool = false) {
        guard let index = items.firstIndex(where: { $0.verse == verse }) else {
            // Try to find closest preceding verse
            if let index = items.lastIndex(where: { $0.verse < verse }) {
                scrollToIndex(index, animated: animated)
            }
            return
        }

        scrollToIndex(index, animated: animated)
    }

    private func isIndexVisibleNearTop(_ index: Int) -> Bool {
        let visible = collectionView.indexPathsForVisibleItems
        guard !visible.isEmpty else { return false }

        // Find the top-most visible index (smallest item).
        let topVisibleIndex = visible.map { $0.item }.min() ?? Int.max

        // Consider it "close enough" if we're already at or within 1 cell of the target.
        return abs(topVisibleIndex - index) <= 1
    }

    private func scrollToIndex(_ index: Int, animated: Bool) {
        isProgrammaticScroll = true

        // Use contentOffset - position item at top of visible area
        if let layoutAttributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
            // Account for safe area (notch)
            let topInset = collectionView.safeAreaInsets.top
            let targetY = layoutAttributes.frame.minY - topInset
            collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: animated)
        } else {
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: animated)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isProgrammaticScroll = false
        }
    }

    // MARK: - UIScrollViewDelegate (Direct coordinator sync - no SwiftUI)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isProgrammaticScroll else { return }

        // Find visible verse from top visible cell
        let visiblePoint = CGPoint(x: scrollView.bounds.midX, y: scrollView.contentOffset.y + 50)

        if let indexPath = collectionView.indexPathForItem(at: visiblePoint),
           indexPath.item < items.count {
            let verse = items[indexPath.item].verse
            if verse != lastReportedVerse && verse > 0 {
                lastReportedVerse = verse
                // Direct coordinator call - no SwiftUI state involved
                scrollCoordinator.toolPanelDidScrollToVerse(verse)
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollCoordinator.toolPanelBeganScrolling()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            scrollCoordinator.scrollEnded(from: .toolPanel)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollCoordinator.scrollEnded(from: .toolPanel)
    }
}

// MARK: - Cross Reference Cell Data

/// Data for a single verse's cross references
struct CrossRefVerseData {
    let verse: Int
    let refs: [CrossReference]
    let baseOffset: Int
    let totalCount: Int
}

/// Cell view for displaying a verse's cross references
struct CrossRefVerseCell: View {
    let data: CrossRefVerseData
    let translation: Translation
    let fontSize: Int
    let onNavigateToVerse: ((Int) -> Void)?
    @Binding var crossRefSheetState: CrossRefSheetState?
    @Binding var crossRefAllItems: [CrossRefTappableItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("v. \(data.verse)")
                .font(.system(size: CGFloat(fontSize - 2), weight: .semibold))
                .foregroundColor(.secondary)

            CrossRefLinkedText(
                crossRefs: data.refs,
                translation: translation,
                fontSize: fontSize,
                onNavigateToVerse: onNavigateToVerse,
                baseOffset: data.baseOffset,
                sharedSheetState: $crossRefSheetState,
                sharedAllItems: $crossRefAllItems,
                totalCount: data.totalCount
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - TSK Verse Cell Data

/// Data for a single verse's TSK content
struct TSKVerseData {
    let verseId: Int
    let verse: Int
    let baseOffset: Int
    let totalCount: Int
}

/// Cell view for displaying a verse's TSK topics
struct TSKVerseCell: View {
    let data: TSKVerseData
    let translation: Translation
    let fontSize: Int
    let onNavigateToVerse: ((Int) -> Void)?
    @Binding var tskSheetState: TSKSheetState?
    @Binding var tskAllItems: [TSKTappableItem]

    var body: some View {
        TSKVerseSection(
            verseId: data.verseId,
            translation: translation,
            fontSize: fontSize,
            onNavigateToVerse: onNavigateToVerse,
            baseOffset: data.baseOffset,
            sharedSheetState: $tskSheetState,
            sharedAllItems: $tskAllItems,
            totalCount: data.totalCount
        )
    }
}

// MARK: - Commentary Cell Data

/// Data for a single commentary unit
struct CommentaryUnitData {
    let index: Int
    let verse: Int
    let unit: CommentaryUnit
    let abbreviations: [CommentaryAbbreviation]?
}

/// Cell view for displaying a commentary unit
struct CommentaryUnitCell: View {
    let data: CommentaryUnitData
    let fontSize: Int
    let onScriptureTap: ((Int, Int?) -> Void)?
    let onStrongsTap: ((String) -> Void)?
    let onFootnoteTap: ((String, CommentaryFootnote) -> Void)?

    var body: some View {
        CommentaryUnitView(
            unit: data.unit,
            abbreviations: data.abbreviations,
            style: CommentaryRenderer.Style(
                bodyFont: .system(size: CGFloat(fontSize)),
                uiBodyFont: .systemFont(ofSize: CGFloat(fontSize))
            ),
            onScriptureTap: onScriptureTap,
            onStrongsTap: onStrongsTap,
            onFootnoteTap: onFootnoteTap
        )
    }
}

// MARK: - Notes Cell Data

/// Data for a single note section
struct NoteSectionData {
    let verse: Int
    let section: NoteSection
    let sectionIndex: Int
}

enum ToolPanelMode: String, CaseIterable {
    case notes = "Notes"
    case crossRefs = "Cross References"
    case tske = "Treasury of Scripture Knowledge (Enhanced)"
    case commentary = "Commentary"
}

struct ToolPanelView: View {
    let book: Int
    let chapter: Int
    let currentVerse: Int
    @ObservedRealmObject var user: User
    var onNavigateToVerse: ((Int) -> Void)?

    // Direct coordinator reference for scroll sync
    private let scrollCoordinator = ScrollSyncCoordinator.shared

    @AppStorage("toolPanelMode") private var panelMode: ToolPanelMode = .crossRefs
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
    @AppStorage("toolPanelScrollLinked") private var isScrollLinked: Bool = true
    @AppStorage("bottomToolbarMode") private var bottomToolbarMode: BottomToolbarMode = .navigation

    /// Current scroll position ID for each content type (verse number or index)
    @State private var scrollPosition: Int? = nil
    /// Last verse we reported to prevent duplicate callbacks
    @State private var lastReportedVerse: Int = 0
    @State private var note: Note?
    @State private var sections: [NoteSection] = []
    @State private var isLoading: Bool = true
    @State private var saveState: SaveState = .idle
    @State private var showingAddVerseSheet: Bool = false
    @State private var newVerseStart: Int = 1
    @State private var newVerseEnd: Int? = nil
    @State private var overlappingSection: NoteSection? = nil
    @State private var saveTask: Task<Void, Never>?

    // Editing state
    @State private var editingSection: NoteSection? = nil
    @State private var editingSectionIndex: Int? = nil
    @State private var editVerseStart: Int = 1
    @State private var editVerseEnd: Int? = nil
    @State private var editOverlappingSection: NoteSection? = nil

    // Locking state
    @AppStorage("notesIsReadOnly") private var isReadOnly: Bool = true
    @State private var showingLockConflict: Bool = false
    @State private var lockConflictInfo: (lockedBy: String, lockedAt: Date)?
    @State private var lockRefreshTask: Task<Void, Never>?

    // Conflict state
    @State private var showingConflictResolution: Bool = false
    @State private var currentConflict: NoteConflict?
    @State private var isProgrammaticScroll: Bool = false

    // Keyboard state (to disable scroll-linking while editing)
    @State private var isKeyboardVisible: Bool = false

    // UI state
    @State private var isMaximized: Bool = false
    @State private var showingOptionsMenu: Bool = false
    @AppStorage("toolFontSize") private var toolFontSize: Int = 16

    // Sync status
    @State private var syncStatus: ICloudModuleStorage.SyncStatus = .synced
    @State private var syncCheckTask: Task<Void, Never>?

    // TSKe cross-segment sheet navigation
    @State private var tskSheetState: TSKSheetState? = nil
    @State private var tskAllItems: [TSKTappableItem] = []

    // Cross References sheet navigation
    @State private var crossRefSheetState: CrossRefSheetState? = nil
    @State private var crossRefAllItems: [CrossRefTappableItem] = []

    // UIKit scroll target (verse to scroll to)
    @State private var scrollToVerseTarget: Int? = nil

    // Module storage
    private let moduleDatabase = ModuleDatabase.shared
    private let moduleSyncManager = ModuleSyncManager.shared
    private let moduleStorage = ICloudModuleStorage.shared
    @State private var notesModuleId: String = "bible-notes"

    // Commentary state
    @State private var commentarySeries: [String] = []
    @AppStorage("selectedCommentarySeries") private var selectedCommentarySeries: String = ""
    @State private var commentaryStrongsKey: String? = nil
    @State private var commentaryScriptureRef: CommentaryScriptureSheetItem? = nil
    @State private var commentaryFootnote: CommentaryFootnote? = nil

    // Commentary Data State
    @State private var commentaryUnits: [CommentaryUnit] = []
    @State private var commentaryBook: CommentaryBook? = nil
    @State private var commentarySeriesHasCoverage: Bool = false
    @State private var isCommentaryLoading: Bool = false

    var bookName: String {
        RealmManager.shared.realm.objects(Book.self).filter("id == \(book)").first?.name ?? "Unknown"
    }

    /// Display name for current panel mode - shows series name for commentary
    private var currentPanelModeDisplayName: String {
        if panelMode == .commentary {
            return selectedCommentarySeries.isEmpty ? "Commentary" : selectedCommentarySeries
        }
        return panelMode.rawValue
    }

    var maxVerseInChapter: Int {
        RealmManager.shared.realm.objects(Verse.self)
            .filter("b == \(book) AND c == \(chapter)")
            .max(ofProperty: "v") ?? 1
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Menu {
                    // Fixed modes (excluding commentary - those are shown individually by module name)
                    ForEach([ToolPanelMode.notes, .crossRefs, .tske], id: \.self) { mode in
                        Button {
                            panelMode = mode
                        } label: {
                            if panelMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }

                    // Commentary series shown by series name
                    if !commentarySeries.isEmpty {
                        Divider()
                        ForEach(commentarySeries, id: \.self) { series in
                            Button {
                                selectedCommentarySeries = series
                                panelMode = .commentary
                            } label: {
                                if panelMode == .commentary && selectedCommentarySeries == series {
                                    Label(series, systemImage: "checkmark")
                                } else {
                                    Text(series)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentPanelModeDisplayName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                }
                .modifier(ConditionalGlassButtonStyle())

                Spacer()

                if panelMode == .notes {
                    notesStatusIndicator
                }

                // Options menu
                Button {
                    showingOptionsMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .padding(.horizontal, 3)
                        .padding(.vertical, 8)
                }
                .modifier(ConditionalGlassButtonStyle())
                .popover(isPresented: $showingOptionsMenu) {
                    optionsMenuContent
                }
            }
            .padding(.horizontal)
            .padding(.top, 2)
            .padding(.bottom, 6)

            if panelMode == .notes {
                notesContent
            } else if panelMode == .tske {
                tskeContent
            } else if panelMode == .commentary {
                commentaryContent
            } else {
                crossRefsContent
            }
        }
        .sheet(isPresented: $isMaximized) {
            maximizedNotesSheet
        }
        .sheet(isPresented: Binding(
            get: { !isMaximized && showingAddVerseSheet },
            set: { showingAddVerseSheet = $0 }
        )) {
            addVerseSheet
        }
        .sheet(item: Binding(
            get: { isMaximized ? nil : editingSection },
            set: { editingSection = $0 }
        )) { _ in
            editVerseSheet
        }
        .sheet(isPresented: $showingLockConflict) {
            if let info = lockConflictInfo {
                LockConflictView(
                    lockedBy: info.lockedBy,
                    lockedAt: info.lockedAt,
                    bookName: bookName,
                    chapter: chapter,
                    onAction: handleLockAction
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $showingConflictResolution) {
            if let conflict = currentConflict {
                ConflictResolutionView(
                    conflict: conflict,
                    bookName: bookName,
                    onResolve: { versionId in
                        Task { await resolveConflict(keepVersionId: versionId) }
                    },
                    onCancel: {
                        showingConflictResolution = false
                        currentConflict = nil
                    }
                )
            }
        }
        .task {
            await loadNote()
        }
        .task {
            // Periodically check sync status while panel is visible
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                guard !Task.isCancelled else { break }
                await checkSyncStatus()
            }
        }
        .onChange(of: book) { _, _ in
            lastReportedVerse = 0
            scrollPosition = nil
            Task {
                await releaseLockIfNeeded()
                await loadNote()
            }
            // Scroll to current verse after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollPosition = currentVerse
            }
        }
        .onChange(of: chapter) { _, _ in
            lastReportedVerse = 0
            scrollPosition = nil
            Task {
                await releaseLockIfNeeded()
                await loadNote()
            }
            // Scroll to current verse after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollPosition = currentVerse
            }
        }
        .onDisappear {
            lockRefreshTask?.cancel()
            Task { await releaseLockIfNeeded() }
        }
        .toolbar {
            // Hide keyboard toolbar when bottom toolbar is in search mode
            if bottomToolbarMode != .search {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onAppear {
            isReadOnly = true // Default to read-only when panel opens
        }
        .task {
            // Load commentary series early to determine if commentary option should show in picker
            await loadCommentarySeriesOnly()
        }
        .onChange(of: panelMode) { _, _ in
            // Reset scroll state when switching modes
            lastReportedVerse = 0
            scrollPosition = nil
            // Scroll tool pane to match Bible pane's current verse
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                scrollPosition = currentVerse
            }
        }
    }

    private var optionsMenuContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Notes mode options
            if panelMode == .notes {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        isReadOnly.toggle()
                        showingOptionsMenu = false
                    } label: {
                        Label(
                            isReadOnly ? "Edit" : "Read-Only",
                            systemImage: isReadOnly ? "square.and.pencil" : "book"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    Button {
                        showingOptionsMenu = false
                        isMaximized = true
                    } label: {
                        Label("Maximize", systemImage: "arrow.down.left.and.arrow.up.right")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(14)
            }

            // Scroll link toggle
            Button {
                isScrollLinked.toggle()
                showingOptionsMenu = false
            } label: {
                Label(
                    isScrollLinked ? "Unlink Scroll" : "Link Scroll",
                    systemImage: isScrollLinked ? "link.circle.fill" : "link.circle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Hide
            Button {
                showingOptionsMenu = false
                if panelMode == .notes {
                    isReadOnly = true
                }
                notesPanelVisible = false
            } label: {
                Label("Hide Tools", systemImage: "rectangle.portrait")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)

            // Font size controls - compact row
            HStack(spacing: 0) {
                Button {
                    if toolFontSize > 12 {
                        toolFontSize -= 2
                    }
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(toolFontSize <= 12)

                Divider()
                    .frame(height: 20)

                Button {
                    if toolFontSize < 24 {
                        toolFontSize += 2
                    }
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(toolFontSize >= 24)
            }
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .font(.body)
        .fontWeight(.regular)
        .padding(12)
        .background(Color(UIColor.systemGroupedBackground))
        .presentationCompactAdaptation(.popover)
    }

    @State private var showingStatusPopover: Bool = false
    @State private var showingMaximizedStatusPopover: Bool = false

    @ViewBuilder
    private var notesStatusIndicator: some View {
        Button {
            showingStatusPopover = true
        } label: {
            HStack(spacing: 4) {
                // Save state icon
                switch saveState {
                case .idle:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .saving:
                    ProgressView()
                        .scaleEffect(0.6)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }

                // Sync status icon
                switch syncStatus {
                case .synced:
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                case .syncing:
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(.secondary)
                case .notSynced:
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                case .notAvailable:
                    Image(systemName: "xmark.icloud")
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 1.2)
        }
        .modifier(ConditionalGlassButtonStyle())
        .popover(isPresented: $showingStatusPopover) {
            statusPopoverContent
        }
    }

    @ViewBuilder
    private var statusPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Save status row
            HStack {
                switch saveState {
                case .idle:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("No unsaved changes")
                case .saving:
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Saving...")
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Saved")
                case .error(let message):
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            // Sync status row
            HStack {
                switch syncStatus {
                case .synced:
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                    Text("Synced to iCloud")
                case .syncing:
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                        .foregroundStyle(.secondary)
                    Text("Syncing to iCloud...")
                case .notSynced:
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                    Text("Waiting to sync")
                case .notAvailable:
                    Image(systemName: "xmark.icloud")
                        .foregroundStyle(.red)
                    Text("iCloud unavailable")
                }
            }
        }
        .padding()
        .presentationCompactAdaptation(.popover)
    }

    private var maximizedNotesSheet: some View {
        NavigationStack {
            notesContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 12) {
                            Text("\(bookName) \(chapter)")
                                .font(.headline)

                            Button {
                                showingMaximizedStatusPopover = true
                            } label: {
                                HStack(spacing: 4) {
                                    // Save state icon
                                    switch saveState {
                                    case .idle, .saved:
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    case .saving:
                                        ProgressView()
                                            .scaleEffect(0.6)
                                    case .error:
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }

                                    // Sync status icon
                                    switch syncStatus {
                                    case .synced:
                                        Image(systemName: "checkmark.icloud.fill")
                                            .foregroundStyle(.green)
                                    case .syncing:
                                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                                            .foregroundStyle(.secondary)
                                    case .notSynced:
                                        Image(systemName: "exclamationmark.icloud")
                                            .foregroundStyle(.orange)
                                    case .notAvailable:
                                        Image(systemName: "xmark.icloud")
                                            .foregroundStyle(.red)
                                    }
                                }
                                .imageScale(.small)
                            }
                            .popover(isPresented: $showingMaximizedStatusPopover) {
                                statusPopoverContent
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            isMaximized = false
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            isReadOnly.toggle()
                        } label: {
                            Image(systemName: isReadOnly ? "square.and.pencil" : "book")
                        }
                    }
                }
                .sheet(isPresented: $showingAddVerseSheet) {
                    addVerseSheet
                }
                .sheet(item: $editingSection) { _ in
                    editVerseSheet
                }
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        if isLoading {
            Spacer()
            ProgressView()
            Spacer()
        } else {
            let gaps = verseGaps()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sections.indices, id: \.self) { index in
                            let section = sections[index]

                            // Show gap button before this section (if there's a gap)
                            if !isReadOnly && !section.isGeneral {
                                if let gap = gaps.first(where: { $0.after == nil && section.verseStart == $0.gapEnd + 1 }) {
                                    gapAddButton(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                                } else if let prevIndex = sections.prefix(index).lastIndex(where: { !$0.isGeneral }),
                                          let prevEnd = sections[prevIndex].verseEnd ?? sections[prevIndex].verseStart,
                                          let gap = gaps.first(where: { $0.after == prevEnd }) {
                                    gapAddButton(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                                }
                            }

                            NoteSectionView(
                                section: $sections[index],
                                isReadOnly: isReadOnly,
                                fontSize: toolFontSize,
                                translation: user.readerTranslation!,
                                onContentChange: { scheduleSave() },
                                onNavigateToVerse: { verse in
                                    // Close maximized sheet if open
                                    if isMaximized {
                                        isMaximized = false
                                    }
                                    // Construct full verseId from verse number within current chapter
                                    let verseId = book * 1000000 + chapter * 1000 + verse
                                    onNavigateToVerse?(verseId)
                                },
                                onNavigateToVerseId: { verseId in
                                    // Close maximized sheet if open
                                    if isMaximized {
                                        isMaximized = false
                                    }
                                    onNavigateToVerse?(verseId)
                                },
                                onEditVerseRange: section.isGeneral ? nil : {
                                    startEditingSection(section, at: index)
                                }
                            )
                            .id(section.verseStart ?? -index)
                        }

                        // Show "No verse notes" placeholder in read-only mode when no verse sections exist
                        if isReadOnly && !sections.contains(where: { !$0.isGeneral }) {
                            Text("No verse notes")
                                .font(.system(size: CGFloat(toolFontSize)))
                                .foregroundStyle(.tertiary)
                        }

                        // Show gap button after last verse section (only when verse sections exist)
                        if !isReadOnly {
                            if let lastVerseSection = sections.last(where: { !$0.isGeneral }),
                               let lastEnd = lastVerseSection.verseEnd ?? lastVerseSection.verseStart,
                               let gap = gaps.first(where: { $0.after == lastEnd }) {
                                gapAddButton(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                            }
                        }

                        // General add verse button (only shown when no verse notes exist)
                        if !isReadOnly && !sections.contains(where: { !$0.isGeneral }) {
                            Button {
                                showingAddVerseSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("Add verse note")
                                }
                                .foregroundColor(.accentColor)
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                        }
                    }
                    .padding()
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $scrollPosition, anchor: .top)
                .scrollDismissesKeyboard(.never)
                .onChange(of: currentVerse) { _, newVerse in
                    guard isScrollLinked && !isKeyboardVisible else { return }
                    // Skip if tool panel is the active scroller (prevents feedback loop)
                    if scrollCoordinator.activeScroller == .toolPanel { return }

                    isProgrammaticScroll = true

                    // Use proxy.scrollTo for reliable programmatic scrolling
                    if findSectionId(forVerse: newVerse) != nil {
                        proxy.scrollTo(newVerse, anchor: .top)
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isProgrammaticScroll = false
                    }
                }
                .onAppear {
                    // Scroll to current verse when view appears
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(currentVerse, anchor: .top)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gapAddButton(gapStart: Int, gapEnd: Int) -> some View {
        Button {
            addVerseSectionWithRange(start: gapStart, end: gapEnd > gapStart ? gapEnd : nil)
        } label: {
            HStack {
                Image(systemName: "plus.circle")
                if gapStart == gapEnd {
                    Text("Add note for verse \(gapStart)")
                } else {
                    Text("Add note for verses \(gapStart)-\(gapEnd)")
                }
            }
            .font(.subheadline)
            .foregroundColor(.accentColor)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var crossRefsContent: some View {
        // Get all verse IDs in this chapter that have cross references
        let chapterStart = book * 1000000 + chapter * 1000 + 1
        let chapterEnd = book * 1000000 + chapter * 1000 + 999
        let allCrossRefs = RealmManager.shared.realm.objects(CrossReference.self)
            .filter("id >= \(chapterStart) AND id <= \(chapterEnd)")
            .sorted(byKeyPath: "id", ascending: true)

        // Group cross refs by verse
        let groupedRefs = Dictionary(grouping: Array(allCrossRefs)) { crossRef in
            crossRef.id % 1000 // Extract verse number from id
        }
        let sortedVerses = groupedRefs.keys.sorted()

        // Compute offsets and total count for cross-segment navigation
        let verseOffsets: [Int: Int] = {
            var offsets: [Int: Int] = [:]
            var runningOffset = 0
            for verse in sortedVerses {
                offsets[verse] = runningOffset
                runningOffset += groupedRefs[verse]?.count ?? 0
            }
            return offsets
        }()
        let totalCrossRefCount = allCrossRefs.count

        // Build items for UIKit list
        let items: [(verse: Int, data: CrossRefVerseData)] = sortedVerses.compactMap { verse in
            guard let refs = groupedRefs[verse] else { return nil }
            return (verse: verse, data: CrossRefVerseData(
                verse: verse,
                refs: refs.sorted { $0.r < $1.r },
                baseOffset: verseOffsets[verse] ?? 0,
                totalCount: totalCrossRefCount
            ))
        }

        Group {
            if sortedVerses.isEmpty {
                VStack {
                    Spacer()
                    Text("No cross references for this chapter")
                        .font(.system(size: CGFloat(toolFontSize)))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                UIKitVerseList(
                    items: items,
                    cellContent: { data in
                        CrossRefVerseCell(
                            data: data,
                            translation: user.readerTranslation!,
                            fontSize: toolFontSize,
                            onNavigateToVerse: onNavigateToVerse,
                            crossRefSheetState: $crossRefSheetState,
                            crossRefAllItems: $crossRefAllItems
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    },
                    listId: "crossRef_\(book)_\(chapter)_\(toolFontSize)"
                )
            }
        }
        .onChange(of: chapter) { _, _ in
            crossRefSheetState = nil
            crossRefAllItems = []
        }
        .onChange(of: book) { _, _ in
            crossRefSheetState = nil
            crossRefAllItems = []
        }
        .sheet(item: $crossRefSheetState) { state in
            crossRefSheetContent(state: state, translation: user.readerTranslation!)
        }
    }

    @ViewBuilder
    private func crossRefSheetContent(state: CrossRefSheetState, translation: Translation) -> some View {
        let item = state.currentItem
        NavigationStack {
            ScrollView {
                CrossRefVerseContent(
                    title: item.displayText,
                    verseId: item.sv,
                    endVerseId: item.ev,
                    translation: translation
                )
                .padding()
            }
            .id("\(item.sv)-\(item.ev ?? 0)")
            .navigationTitle(item.displayText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        crossRefSheetState = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if onNavigateToVerse != nil {
                        Button {
                            crossRefSheetState = nil
                            onNavigateToVerse?(item.sv)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if state.allItems.count > 1 {
                        Button {
                            if let prev = state.withPrev() {
                                crossRefSheetState = prev
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigatePrev)

                        Spacer()

                        Text("\(state.currentIndex + 1) of \(state.displayCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 8)

                        Spacer()

                        Button {
                            if let next = state.withNext() {
                                crossRefSheetState = next
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigateNext)
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.325), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    // MARK: - TSKe Content

    /// Compute ref counts for all TSKe content in the chapter (for cross-segment swipe navigation)
    private func computeTskRefData(tskChapter: TSKChapter?, allTskVerses: Results<TSKVerse>) -> (totalCount: Int, chapterOverviewCount: Int, verseOffsets: [Int: Int]) {
        var totalCount = 0
        var verseOffsets: [Int: Int] = [:]

        // Chapter overview refs
        let chapterOverviewCount = tskChapter.map { countRefsInSegmentsJson($0.segmentsJson) } ?? 0
        totalCount += chapterOverviewCount

        // Verse refs
        for tskVerse in allTskVerses {
            verseOffsets[tskVerse.id] = totalCount
            // Count refs in all topics for this verse
            for topic in tskVerse.topics {
                totalCount += countRefsInSegmentsJson(topic.segmentsJson)
            }
        }

        return (totalCount, chapterOverviewCount, verseOffsets)
    }

    @ViewBuilder
    private var tskeContent: some View {
        // Get TSKe data for this chapter
        let tskBook = RealmManager.shared.realm.objects(TSKBook.self).filter("b == \(book)").first
        let tskChapter = RealmManager.shared.realm.objects(TSKChapter.self).filter("b == \(book) AND c == \(chapter)").first

        // Get all verse entries for this chapter
        let chapterStart = book * 1000000 + chapter * 1000 + 1
        let chapterEnd = book * 1000000 + chapter * 1000 + 999
        let allTskVerses = RealmManager.shared.realm.objects(TSKVerse.self)
            .filter("id >= \(chapterStart) AND id <= \(chapterEnd)")
            .sorted(byKeyPath: "id", ascending: true)

        // Compute ref counts and offsets for cross-segment swipe navigation
        let refData = computeTskRefData(tskChapter: tskChapter, allTskVerses: allTskVerses)

        // Build items for UIKit list
        let items: [(verse: Int, data: TSKVerseData)] = Array(allTskVerses).map { tskVerse in
            let verseNum = tskVerse.id % 1000
            let verseOffset = refData.verseOffsets[tskVerse.id] ?? 0
            return (verse: verseNum, data: TSKVerseData(
                verseId: tskVerse.id,
                verse: verseNum,
                baseOffset: verseOffset,
                totalCount: refData.totalCount
            ))
        }

        let hasHeaderContent = (chapter == 1 && tskBook?.t.isEmpty == false) ||
                               (tskChapter?.segmentsJson.isEmpty == false)

        Group {
            if allTskVerses.isEmpty && tskBook == nil && tskChapter == nil {
                VStack {
                    Spacer()
                    Text("No TSKe data for this chapter")
                        .font(.system(size: CGFloat(toolFontSize)))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                UIKitVerseList(
                    items: items,
                    cellContent: { data in
                        TSKVerseCell(
                            data: data,
                            translation: user.readerTranslation!,
                            fontSize: toolFontSize,
                            onNavigateToVerse: onNavigateToVerse,
                            tskSheetState: $tskSheetState,
                            tskAllItems: $tskAllItems
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    },
                    listId: "tske_\(book)_\(chapter)_\(toolFontSize)"
                )
            }
        }
        .onChange(of: chapter) { _, _ in
            tskSheetState = nil
            tskAllItems = []
        }
        .onChange(of: book) { _, _ in
            tskSheetState = nil
            tskAllItems = []
        }
        .sheet(item: $tskSheetState) { state in
            tskSheetContent(state: state, translation: user.readerTranslation!)
        }
    }

    @ViewBuilder
    private func tskSheetContent(state: TSKSheetState, translation: Translation) -> some View {
        let item = state.currentItem
        NavigationStack {
            ScrollView {
                VerseSheetContent(
                    title: item.displayText,
                    verseId: item.sv,
                    endVerseId: item.ev,
                    translation: translation
                )
                .padding()
            }
            .id("\(item.sv)-\(item.ev ?? 0)")  // Force refresh when item changes
            .navigationTitle(item.displayText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        tskSheetState = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if onNavigateToVerse != nil {
                        Button {
                            tskSheetState = nil
                            onNavigateToVerse?(item.sv)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if state.allItems.count > 1 {
                        Button {
                            if let prev = state.withPrev() {
                                tskSheetState = prev
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigatePrev)

                        Spacer()

                        Text("\(state.currentIndex + 1) of \(state.displayCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 8)

                        Spacer()

                        Button {
                            if let next = state.withNext() {
                                tskSheetState = next
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigateNext)
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.325), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    // MARK: - Commentary Content

    @ViewBuilder
    private var commentaryContent: some View {
        VStack(spacing: 0) {
            if selectedCommentarySeries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Select a commentary series")
                        .font(.system(size: CGFloat(toolFontSize)))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isCommentaryLoading {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !commentarySeriesHasCoverage {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("\(selectedCommentarySeries) does not include \(bookName)")
                        .font(.system(size: CGFloat(toolFontSize)))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commentaryUnits.isEmpty {
                VStack(spacing: 12) {
                    Text("No commentary for this chapter")
                        .font(.system(size: CGFloat(toolFontSize)))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                commentaryScrollView(units: commentaryUnits, commentaryBook: commentaryBook)
                    .id("commentaryScroll_\(book)_\(chapter)")
            }
        }
        .id("commentary_\(book)_\(chapter)_\(selectedCommentarySeries)")
        .task(id: book) { await loadCommentaryContent() }
        .task(id: chapter) { await loadCommentaryContent() }
        .task(id: selectedCommentarySeries) { await loadCommentaryContent() }
        .sheet(item: Binding(
            get: { commentaryStrongsKey.map { CommentaryStrongsSheetItem(key: $0) } },
            set: { commentaryStrongsKey = $0?.key }
        )) { item in
            LexiconSheetView(
                word: "",
                strongs: [item.key],
                morphology: nil,
                translation: user.readerTranslation,
                onNavigateToVerse: { verseId in
                    commentaryStrongsKey = nil
                    onNavigateToVerse?(verseId)
                }
            )
            .presentationDetents([.fraction(0.325), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(item: $commentaryScriptureRef) { item in
            commentaryScriptureSheetContent(item: item, translation: user.readerTranslation!)
        }
        .sheet(item: $commentaryFootnote) { footnote in
            commentaryFootnoteSheetContent(footnote: footnote)
        }
    }

    @ViewBuilder
    private func commentaryScrollView(units: [CommentaryUnit], commentaryBook: CommentaryBook?) -> some View {
        // Build items for UIKit list
        let items: [(verse: Int, data: CommentaryUnitData)] = units.enumerated().map { index, unit in
            (verse: unit.verse, data: CommentaryUnitData(
                index: index,
                verse: unit.verse,
                unit: unit,
                abbreviations: commentaryBook?.abbreviations
            ))
        }

        UIKitVerseList(
            items: items,
            cellContent: { data in
                CommentaryUnitCell(
                    data: data,
                    fontSize: toolFontSize,
                    onScriptureTap: { sv, ev in
                        commentaryScriptureRef = CommentaryScriptureSheetItem(verseId: sv, endVerseId: ev)
                    },
                    onStrongsTap: { strongsKey in
                        commentaryStrongsKey = strongsKey
                    },
                    onFootnoteTap: { _, footnote in
                        commentaryFootnote = footnote
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            },
            listId: "commentary_\(book)_\(chapter)_\(selectedCommentarySeries)_\(toolFontSize)"
        )
    }

    private func loadCommentaryContent() async {
        guard !selectedCommentarySeries.isEmpty else { return }

        isCommentaryLoading = true
        defer { isCommentaryLoading = false }

        // Use a detached task to avoid blocking the main actor
        // We capture values to avoid actor isolation issues if we were accessing self in detached task
        let series = selectedCommentarySeries
        let b = book
        let c = chapter
        let database = moduleDatabase

        let (coverage, bookInfo, units) = await Task.detached(priority: .userInitiated) {
            let coverage = (try? database.seriesHasCoverageForBook(seriesFull: series, bookNumber: b)) ?? false
            let bookInfo = coverage ? (try? database.getCommentaryBookForSeries(seriesFull: series, bookNumber: b)) : nil
            let units = coverage ? ((try? database.getCommentaryUnitsForChapterBySeries(seriesFull: series, book: b, chapter: c)) ?? []) : []
            return (coverage, bookInfo, units)
        }.value

        // Update state on Main Actor
        commentarySeriesHasCoverage = coverage
        commentaryBook = bookInfo
        commentaryUnits = units
    }

    /// Load just the commentary series list (for picker availability check)
    private func loadCommentarySeriesOnly() async {
        do {
            commentarySeries = try moduleDatabase.getCommentarySeries()
            if !commentarySeries.isEmpty && (selectedCommentarySeries.isEmpty || !commentarySeries.contains(selectedCommentarySeries)) {
                selectedCommentarySeries = commentarySeries.first ?? ""
            }
        } catch {
            print("Failed to load commentary series: \(error)")
        }
    }

    /// Format verse ID to display string (e.g., 40001001 -> "Matt 1:1")
    private func formatVerseReference(_ verseId: Int) -> String {
        let bookId = verseId / 1000000
        let chapter = (verseId % 1000000) / 1000
        let verse = verseId % 1000

        let realm = RealmManager.shared.realm
        let bookName: String
        if let book = realm.objects(Book.self).filter("id == %@", bookId).first {
            bookName = book.name
        } else {
            bookName = "?"
        }
        return "\(bookName) \(chapter):\(verse)"
    }

    @ViewBuilder
    private func commentaryScriptureSheetContent(item: CommentaryScriptureSheetItem, translation: Translation) -> some View {
        let displayText = formatVerseRangeReference(item.verseId, endVerseId: item.endVerseId)
        NavigationStack {
            ScrollView {
                VerseSheetContent(
                    title: displayText,
                    verseId: item.verseId,
                    endVerseId: item.endVerseId,
                    translation: translation
                )
                .padding()
            }
            .navigationTitle(displayText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        commentaryScriptureRef = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if onNavigateToVerse != nil {
                        Button {
                            commentaryScriptureRef = nil
                            onNavigateToVerse?(item.verseId)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.325), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    /// Format verse range reference (e.g., "Matt 1:1-5" or "Matt 1:1")
    private func formatVerseRangeReference(_ verseId: Int, endVerseId: Int?) -> String {
        let bookId = verseId / 1000000
        let chapter = (verseId % 1000000) / 1000
        let verse = verseId % 1000

        let realm = RealmManager.shared.realm
        let bookName: String
        if let book = realm.objects(Book.self).filter("id == %@", bookId).first {
            bookName = book.name
        } else {
            bookName = "?"
        }

        if let ev = endVerseId {
            let endVerse = ev % 1000
            if endVerse != verse {
                return "\(bookName) \(chapter):\(verse)-\(endVerse)"
            }
        }
        return "\(bookName) \(chapter):\(verse)"
    }

    @ViewBuilder
    private func commentaryFootnoteSheetContent(footnote: CommentaryFootnote) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Render the footnote content with annotation support
                    AnnotatedTextView(
                        footnote.content,
                        style: CommentaryRenderer.Style(
                            bodyFont: .system(size: CGFloat(toolFontSize)),
                            uiBodyFont: .systemFont(ofSize: CGFloat(toolFontSize))
                        ),
                        onScriptureTap: { sv, ev in
                            commentaryFootnote = nil
                            commentaryScriptureRef = CommentaryScriptureSheetItem(verseId: sv, endVerseId: ev)
                        },
                        onStrongsTap: { strongsKey in
                            commentaryFootnote = nil
                            commentaryStrongsKey = strongsKey
                        }
                    )
                }
                .padding()
            }
            .navigationTitle("Footnote \(footnote.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        commentaryFootnote = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.325), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }

    private var addVerseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start verse", selection: $newVerseStart) {
                        ForEach(1...maxVerseInChapter, id: \.self) { verse in
                            Text("\(verse)").tag(verse)
                        }
                    }

                    Picker("End verse", selection: $newVerseEnd) {
                        Text("Single verse").tag(nil as Int?)
                        ForEach((newVerseStart + 1)...max(newVerseStart + 1, maxVerseInChapter), id: \.self) { verse in
                            Text("\(verse)").tag(verse as Int?)
                        }
                    }
                } header: {
                    Text("Verse")
                } footer: {
                    if let overlap = overlappingSection {
                        Text("This overlaps with existing note: \(overlap.displayTitle)")
                            .foregroundColor(.orange)
                    } else {
                        Text("Select a single verse or a range")
                    }
                }

                if overlappingSection != nil {
                    Section {
                        Button {
                            scrollToOverlappingSection()
                        } label: {
                            Label("Edit existing note instead", systemImage: "square.and.pencil")
                        }
                    }
                }
            }
            .navigationTitle("Add Verse Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingAddVerseSheet = false
                        resetAddVerseForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addVerseSection()
                    }
                    .disabled(overlappingSection != nil)
                }
            }
            .onChange(of: newVerseStart) { _, _ in
                // Reset end verse if it's now invalid
                if let end = newVerseEnd, end <= newVerseStart {
                    newVerseEnd = nil
                }
                checkForOverlap()
            }
            .onChange(of: newVerseEnd) { _, _ in
                checkForOverlap()
            }
            .onAppear {
                checkForOverlap()
            }
        }
        .presentationDetents([.medium])
    }

    private func findSectionId(forVerse verse: Int) -> String? {
        // First look for exact match (verse is within a section's range)
        for section in sections {
            if let start = section.verseStart, let end = section.verseEnd {
                if verse >= start && verse <= end {
                    return section.id
                }
            } else if let start = section.verseStart, start == verse {
                return section.id
            }
        }

        // No exact match - find the closest verse section
        let verseSections = sections.filter { !$0.isGeneral && $0.verseStart != nil }
        guard !verseSections.isEmpty else { return nil }

        var closestSection: NoteSection? = nil
        var closestDistance = Int.max

        for section in verseSections {
            guard let start = section.verseStart else { continue }
            let end = section.verseEnd ?? start

            // Calculate distance to this section
            let distance: Int
            if verse < start {
                distance = start - verse
            } else if verse > end {
                distance = verse - end
            } else {
                distance = 0 // Should have been caught above, but just in case
            }

            if distance < closestDistance {
                closestDistance = distance
                closestSection = section
            }
        }

        return closestSection?.id
    }

    private func loadNote() async {
        isLoading = true
        saveState = .idle
        lockRefreshTask?.cancel()

        do {
            // Ensure default notes module exists
            try await moduleSyncManager.ensureDefaultNotesModule()

            // Load notes from SQLite for this chapter
            let entries = try moduleDatabase.getNotesForChapter(moduleId: notesModuleId, book: book, chapter: chapter)

            // Convert NoteEntry records to NoteSection for UI
            sections = convertEntriesToSections(entries)

            // If no entries, start with empty general section
            if sections.isEmpty {
                sections = [.general(content: "")]
            }

            // Create a synthetic Note object for compatibility
            note = Note(book: book, chapter: chapter)
        } catch {
            print("Failed to load notes: \(error)")
            note = Note(book: book, chapter: chapter)
            sections = [.general(content: "")]
        }

        isLoading = false

        // Check sync status
        await checkSyncStatus()
    }

    /// Convert NoteEntry records to NoteSection array for UI display
    private func convertEntriesToSections(_ entries: [NoteEntry]) -> [NoteSection] {
        var result: [NoteSection] = []

        // Sort entries by verse number
        let sorted = entries.sorted { $0.verse < $1.verse }

        for entry in sorted {
            if entry.verse == 0 {
                // General notes (chapter-level)
                result.insert(.general(content: entry.content), at: 0)
            } else if let verseRefs = entry.verseRefs, let endVerse = verseRefs.first, endVerse != entry.verse {
                // Verse range - endVerse stored in verseRefs
                result.append(.verseRange(start: entry.verse, end: endVerse, content: entry.content))
            } else {
                // Single verse
                result.append(.verse(entry.verse, content: entry.content))
            }
        }

        return result
    }

    /// Convert NoteSection array back to NoteEntry records for storage
    private func convertSectionsToEntries(_ sections: [NoteSection]) -> [NoteEntry] {
        var entries: [NoteEntry] = []

        for section in sections {
            let verse: Int
            let endVerse: Int?
            let content = section.content

            if section.isGeneral {
                verse = 0
                endVerse = nil
            } else if let start = section.verseStart {
                verse = start
                if let end = section.verseEnd, end != start {
                    endVerse = end
                } else {
                    endVerse = nil
                }
            } else {
                verse = 0
                endVerse = nil
            }

            let verseId = book * 1000000 + chapter * 1000 + verse

            // Generate stable ID based on module + verse
            let entryId = "\(notesModuleId):\(verseId)"

            let entry = NoteEntry(
                id: entryId,
                moduleId: notesModuleId,
                verseId: verseId,
                title: section.displayTitle.isEmpty ? nil : section.displayTitle,
                content: content,
                verseRefs: endVerse.map { [$0] },
                lastModified: Int(Date().timeIntervalSince1970)
            )
            entries.append(entry)
        }

        return entries
    }

    private func checkSyncStatus() async {
        let fileName = "\(notesModuleId).json"
        syncStatus = await moduleStorage.getSyncStatus(type: .notes, fileName: fileName)
    }

    private func tryAcquireLock() async {
        // Lock handling simplified for new module system
        // The JSON file-based system handles conflicts at sync time
    }

    private func handleLockAction(_ action: LockAction) {
        showingLockConflict = false
        switch action {
        case .viewReadOnly:
            isReadOnly = true
        case .editAnyway:
            isReadOnly = false
        case .cancel:
            break
        }
    }

    private func startLockRefresh() {
        // No longer needed with new module system
    }

    private func releaseLockIfNeeded() async {
        // No longer needed with new module system
    }

    private func resolveConflict(keepVersionId: String) async {
        // Conflict resolution handled differently in new module system
        showingConflictResolution = false
        currentConflict = nil
        await loadNote()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveState = .idle

        saveTask = Task {
            // Debounce: wait 1 second before saving
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard !Task.isCancelled else { return }

            await saveNote()
        }
    }

    private func saveNote() async {
        guard note != nil else { return }
        guard !isReadOnly else { return } // Don't save in read-only mode

        saveState = .saving

        do {
            // Convert sections to NoteEntry records
            let entries = convertSectionsToEntries(sections)

            // Delete existing entries for this chapter first
            let existingEntries = try moduleDatabase.getNotesForChapter(moduleId: notesModuleId, book: book, chapter: chapter)
            for entry in existingEntries {
                try moduleDatabase.deleteNoteEntry(id: entry.id)
            }

            // Save new entries (skip empty ones)
            for entry in entries where !entry.content.isEmpty {
                try moduleDatabase.saveNoteEntry(entry)
            }

            // Export to iCloud
            try await moduleSyncManager.exportModule(id: notesModuleId)

            saveState = .saved

            // Check sync status after save
            await checkSyncStatus()

            // Clear "Saved" indicator after 2 seconds
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .saved = saveState {
                saveState = .idle
            }
        } catch {
            saveState = .error("Save failed")
            print("Failed to save notes: \(error)")
        }
    }

    private func addVerseSection() {
        let start = newVerseStart
        let end = newVerseEnd ?? start
        let newSection: NoteSection

        if end != start && end > start {
            newSection = .verseRange(start: start, end: end, content: "")
        } else {
            newSection = .verse(start, content: "")
        }

        // Insert in sorted order (after general, sorted by verse number)
        var insertIndex = sections.count
        for (index, section) in sections.enumerated() {
            if let existingStart = section.verseStart {
                if start < existingStart {
                    insertIndex = index
                    break
                }
            }
        }

        sections.insert(newSection, at: insertIndex)
        scheduleSave()

        showingAddVerseSheet = false
        resetAddVerseForm()
    }

    private func resetAddVerseForm() {
        newVerseStart = 1
        newVerseEnd = nil
        overlappingSection = nil
    }

    private func checkForOverlap() {
        let start = newVerseStart
        let end = newVerseEnd ?? start

        // Check if any existing section overlaps with this range
        for section in sections {
            guard let sectionStart = section.verseStart else { continue }
            let sectionEnd = section.verseEnd ?? sectionStart

            // Check for overlap: ranges overlap if one starts before the other ends
            let overlaps = start <= sectionEnd && end >= sectionStart

            if overlaps {
                overlappingSection = section
                return
            }
        }

        overlappingSection = nil
    }

    private func scrollToOverlappingSection() {
        if let section = overlappingSection {
            let targetVerse = section.verseStart
            showingAddVerseSheet = false
            resetAddVerseForm()
            // Delay scroll until after sheet dismissal animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                scrollPosition = targetVerse
            }
        }
    }

    // MARK: - Editing

    private var editVerseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Start verse", selection: $editVerseStart) {
                        ForEach(1...maxVerseInChapter, id: \.self) { verse in
                            Text("\(verse)").tag(verse)
                        }
                    }

                    Picker("End verse", selection: $editVerseEnd) {
                        Text("Single verse").tag(nil as Int?)
                        ForEach((editVerseStart + 1)...max(editVerseStart + 1, maxVerseInChapter), id: \.self) { verse in
                            Text("\(verse)").tag(verse as Int?)
                        }
                    }
                } header: {
                    Text("Verse")
                } footer: {
                    if let overlap = editOverlappingSection {
                        Text("This overlaps with existing note: \(overlap.displayTitle)")
                            .foregroundColor(.orange)
                    } else {
                        Text("Select a single verse or a range")
                    }
                }

                if editOverlappingSection != nil {
                    Section {
                        Button {
                            scrollToEditOverlappingSection()
                        } label: {
                            Label("Edit existing note instead", systemImage: "square.and.pencil")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        deleteEditingSection()
                    } label: {
                        Label("Delete this verse note", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit Verse Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editingSection = nil
                        resetEditVerseForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEditedVerseRange()
                    }
                    .disabled(editOverlappingSection != nil)
                }
            }
            .onChange(of: editVerseStart) { _, _ in
                // Reset end verse if it's now invalid
                if let end = editVerseEnd, end <= editVerseStart {
                    editVerseEnd = nil
                }
                checkForEditOverlap()
            }
            .onChange(of: editVerseEnd) { _, _ in
                checkForEditOverlap()
            }
        }
        .presentationDetents([.medium])
    }

    private func startEditingSection(_ section: NoteSection, at index: Int) {
        editingSectionIndex = index
        editVerseStart = section.verseStart ?? 1
        editVerseEnd = section.verseEnd != section.verseStart ? section.verseEnd : nil
        editOverlappingSection = nil
        editingSection = section
    }

    private func resetEditVerseForm() {
        editingSectionIndex = nil
        editVerseStart = 1
        editVerseEnd = nil
        editOverlappingSection = nil
    }

    private func checkForEditOverlap() {
        guard let editingIndex = editingSectionIndex else { return }
        let start = editVerseStart
        let end = editVerseEnd ?? start

        // Check if any OTHER existing section overlaps with this range
        for (index, section) in sections.enumerated() {
            guard index != editingIndex else { continue }
            guard let sectionStart = section.verseStart else { continue }
            let sectionEnd = section.verseEnd ?? sectionStart

            let overlaps = start <= sectionEnd && end >= sectionStart

            if overlaps {
                editOverlappingSection = section
                return
            }
        }

        editOverlappingSection = nil
    }

    private func scrollToEditOverlappingSection() {
        if let section = editOverlappingSection {
            let targetVerse = section.verseStart
            editingSection = nil
            resetEditVerseForm()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                scrollPosition = targetVerse
            }
        }
    }

    private func saveEditedVerseRange() {
        guard let index = editingSectionIndex, index < sections.count else { return }
        let start = editVerseStart
        let end = editVerseEnd ?? start
        let content = sections[index].content

        // Create updated section
        let updatedSection: NoteSection
        if end != start && end > start {
            updatedSection = .verseRange(start: start, end: end, content: content)
        } else {
            updatedSection = .verse(start, content: content)
        }

        // Remove old section
        sections.remove(at: index)

        // Insert in sorted order
        var insertIndex = sections.count
        for (i, section) in sections.enumerated() {
            if let existingStart = section.verseStart {
                if start < existingStart {
                    insertIndex = i
                    break
                }
            }
        }

        sections.insert(updatedSection, at: insertIndex)
        scheduleSave()

        editingSection = nil
        resetEditVerseForm()
    }

    private func deleteEditingSection() {
        guard let index = editingSectionIndex, index < sections.count else { return }
        sections.remove(at: index)
        scheduleSave()

        editingSection = nil
        resetEditVerseForm()
    }

    // MARK: - Gap Calculation

    private func verseGaps() -> [(after: Int?, gapStart: Int, gapEnd: Int)] {
        let verseSections = sections.filter { !$0.isGeneral }.sorted { ($0.verseStart ?? 0) < ($1.verseStart ?? 0) }

        var gaps: [(after: Int?, gapStart: Int, gapEnd: Int)] = []

        // Check gap before first verse section
        if let first = verseSections.first, let firstStart = first.verseStart, firstStart > 1 {
            gaps.append((after: nil, gapStart: 1, gapEnd: firstStart - 1))
        } else if verseSections.isEmpty && maxVerseInChapter > 0 {
            // No verse sections at all - entire chapter is a gap
            gaps.append((after: nil, gapStart: 1, gapEnd: maxVerseInChapter))
        }

        // Check gaps between sections
        for i in 0..<verseSections.count {
            let current = verseSections[i]
            let currentEnd = current.verseEnd ?? current.verseStart ?? 0

            if i + 1 < verseSections.count {
                let next = verseSections[i + 1]
                let nextStart = next.verseStart ?? 0

                if nextStart > currentEnd + 1 {
                    gaps.append((after: currentEnd, gapStart: currentEnd + 1, gapEnd: nextStart - 1))
                }
            } else {
                // After last section - check if there's a gap to end of chapter
                if currentEnd < maxVerseInChapter {
                    gaps.append((after: currentEnd, gapStart: currentEnd + 1, gapEnd: maxVerseInChapter))
                }
            }
        }

        return gaps
    }

    private func addVerseSectionWithRange(start: Int, end: Int?) {
        newVerseStart = start
        newVerseEnd = end
        overlappingSection = nil
        showingAddVerseSheet = true
    }
}

struct NoteSectionView: View {
    @Binding var section: NoteSection
    let isReadOnly: Bool
    let fontSize: Int
    let translation: Translation
    let onContentChange: () -> Void
    var onNavigateToVerse: ((Int) -> Void)?
    var onNavigateToVerseId: ((Int) -> Void)?
    var onEditVerseRange: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            if !section.displayTitle.isEmpty {
                if section.isGeneral {
                    Text(section.displayTitle)
                        .font(.system(size: CGFloat(fontSize), weight: .bold))
                        .foregroundColor(.primary)
                } else if let verseStart = section.verseStart {
                    HStack {
                        Button {
                            onNavigateToVerse?(verseStart)
                        } label: {
                            Text(section.displayTitle)
                                .font(.system(size: CGFloat(fontSize), weight: .bold))
                                .foregroundColor(.accentColor)
                        }

                        if !isReadOnly, let onEdit = onEditVerseRange {
                            Spacer()
                            Button {
                                onEdit()
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            // Text editor or read-only text
            if isReadOnly {
                let placeholder = section.isGeneral ? "No general notes" : "No notes"
                if section.content.isEmpty {
                    Text(placeholder)
                        .font(.system(size: CGFloat(fontSize)))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .foregroundStyle(.tertiary)
                } else {
                    InteractiveNoteContentView(
                        content: section.content,
                        fontSize: fontSize,
                        translation: translation,
                        onNavigateToVerse: onNavigateToVerseId
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    if section.content.isEmpty && !isFocused {
                        Text("Add your notes...")
                            .font(.system(size: CGFloat(fontSize)))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                    }

                    TextEditor(text: $section.content)
                        .font(.system(size: CGFloat(fontSize)))
                        .focused($isFocused)
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.never)
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(8)
                        .onChange(of: section.content) { _, _ in
                            onContentChange()
                        }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Count the number of verse references in this section's content
    var referenceCount: Int {
        VerseReferenceParser.shared.parse(section.content).count
    }
}

// MARK: - Verse Reference Parser

struct ParsedVerseReference: Identifiable {
    let id = UUID()
    let range: Range<String.Index>
    let displayText: String
    let bookId: Int
    let chapter: Int
    let startVerse: Int
    let endVerse: Int?

    var verseId: Int {
        bookId * 1000000 + chapter * 1000 + startVerse
    }

    var endVerseId: Int? {
        guard let end = endVerse else { return nil }
        return bookId * 1000000 + chapter * 1000 + end
    }
}

class VerseReferenceParser {
    static let shared = VerseReferenceParser()

    private var bookNameToId: [String: Int] = [:]
    private var bookAbbrevToId: [String: Int] = [:]

    private init() {
        // Build lookup tables from realm
        let books = RealmManager.shared.realm.objects(Book.self)
        for book in books {
            // Full name (case insensitive)
            bookNameToId[book.name.lowercased()] = book.id
            // OSIS ID (e.g., "Gen", "Matt")
            bookAbbrevToId[book.osisId.lowercased()] = book.id
            // Paratext abbreviation
            if !book.osisParatextAbbreviation.isEmpty {
                bookAbbrevToId[book.osisParatextAbbreviation.lowercased()] = book.id
            }
        }
        // Add common abbreviations
        bookAbbrevToId["1sam"] = bookNameToId["1 samuel"]
        bookAbbrevToId["2sam"] = bookNameToId["2 samuel"]
        bookAbbrevToId["1ki"] = bookNameToId["1 kings"]
        bookAbbrevToId["2ki"] = bookNameToId["2 kings"]
        bookAbbrevToId["1chr"] = bookNameToId["1 chronicles"]
        bookAbbrevToId["2chr"] = bookNameToId["2 chronicles"]
        bookAbbrevToId["1cor"] = bookNameToId["1 corinthians"]
        bookAbbrevToId["2cor"] = bookNameToId["2 corinthians"]
        bookAbbrevToId["1thess"] = bookNameToId["1 thessalonians"]
        bookAbbrevToId["2thess"] = bookNameToId["2 thessalonians"]
        bookAbbrevToId["1tim"] = bookNameToId["1 timothy"]
        bookAbbrevToId["2tim"] = bookNameToId["2 timothy"]
        bookAbbrevToId["1pet"] = bookNameToId["1 peter"]
        bookAbbrevToId["2pet"] = bookNameToId["2 peter"]
        bookAbbrevToId["1jn"] = bookNameToId["1 john"]
        bookAbbrevToId["2jn"] = bookNameToId["2 john"]
        bookAbbrevToId["3jn"] = bookNameToId["3 john"]
        bookAbbrevToId["phil"] = bookNameToId["philippians"]
        bookAbbrevToId["phm"] = bookNameToId["philemon"]
        bookAbbrevToId["jas"] = bookNameToId["james"]
        bookAbbrevToId["rev"] = bookNameToId["revelation"]
    }

    /// Parse all verse references in the format [Book Chapter:Verse] or [Book Chapter:StartVerse-EndVerse]
    func parse(_ text: String) -> [ParsedVerseReference] {
        var references: [ParsedVerseReference] = []

        // Pattern: [Book Chapter:Verse] or [Book Chapter:Verse-EndVerse]
        // Book can be: "John", "1 John", "Genesis", "Gen", etc.
        let pattern = #"\[([1-3]?\s?[A-Za-z]+)\s+(\d+):(\d+)(?:-(\d+))?\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return references
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 4,
                  let fullRange = Range(match.range, in: text),
                  let bookRange = Range(match.range(at: 1), in: text),
                  let chapterRange = Range(match.range(at: 2), in: text),
                  let verseRange = Range(match.range(at: 3), in: text) else {
                continue
            }

            let bookStr = String(text[bookRange]).trimmingCharacters(in: .whitespaces)
            let chapterStr = String(text[chapterRange])
            let verseStr = String(text[verseRange])

            var endVerse: Int? = nil
            if match.numberOfRanges >= 5, match.range(at: 4).location != NSNotFound,
               let endVerseRange = Range(match.range(at: 4), in: text) {
                endVerse = Int(String(text[endVerseRange]))
            }

            guard let chapter = Int(chapterStr),
                  let startVerse = Int(verseStr),
                  let bookId = resolveBookId(bookStr) else {
                continue
            }

            // Validate that the verse exists
            let verseId = bookId * 1000000 + chapter * 1000 + startVerse
            let exists = RealmManager.shared.realm.objects(Verse.self)
                .filter("id == \(verseId)")
                .first != nil

            if exists {
                let displayText = String(text[fullRange])
                    .dropFirst() // Remove [
                    .dropLast()  // Remove ]
                references.append(ParsedVerseReference(
                    range: fullRange,
                    displayText: String(displayText),
                    bookId: bookId,
                    chapter: chapter,
                    startVerse: startVerse,
                    endVerse: endVerse
                ))
            }
        }

        return references
    }

    private func resolveBookId(_ bookStr: String) -> Int? {
        let normalized = bookStr.lowercased()

        // Try exact match first
        if let id = bookNameToId[normalized] {
            return id
        }

        // Try abbreviations
        if let id = bookAbbrevToId[normalized] {
            return id
        }

        // Try partial match (for things like "1 Jn" -> "1 John")
        for (name, id) in bookNameToId {
            if name.hasPrefix(normalized) {
                return id
            }
        }

        return nil
    }
}

// MARK: - Interactive Note Content View

struct InteractiveNoteContentView: View {
    let content: String
    let fontSize: Int
    let translation: Translation
    var onNavigateToVerse: ((Int) -> Void)?

    private var segments: [(text: String, reference: ParsedVerseReference?)] {
        let references = VerseReferenceParser.shared.parse(content)

        if references.isEmpty {
            return [(content, nil)]
        }

        var result: [(String, ParsedVerseReference?)] = []
        var currentIndex = content.startIndex

        for ref in references.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            // Add text before this reference
            if currentIndex < ref.range.lowerBound {
                let textBefore = String(content[currentIndex..<ref.range.lowerBound])
                result.append((textBefore, nil))
            }
            // Add the reference
            result.append((ref.displayText, ref))
            currentIndex = ref.range.upperBound
        }

        // Add remaining text after last reference
        if currentIndex < content.endIndex {
            let textAfter = String(content[currentIndex..<content.endIndex])
            result.append((textAfter, nil))
        }

        return result
    }

    var body: some View {
        // Use a custom layout that wraps text and inline buttons
        WrappingHStack(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if let reference = segment.reference {
                    VerseReferenceButton(
                        reference: reference,
                        translation: translation,
                        fontSize: fontSize,
                        onNavigateToVerse: onNavigateToVerse
                    )
                } else {
                    Text(segment.text)
                        .font(.system(size: CGFloat(fontSize)))
                }
            }
        }
    }

    /// Count the number of verse references in this content
    var referenceCount: Int {
        VerseReferenceParser.shared.parse(content).count
    }
}

struct VerseReferenceButton: View {
    let reference: ParsedVerseReference
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?
    @State private var showingSheet = false

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Text(reference.displayText)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundColor(.accentColor)
        }
        .sheet(isPresented: $showingSheet) {
            NavigationStack {
                ScrollView {
                    VerseSheetContent(
                        title: reference.displayText,
                        verseId: reference.verseId,
                        endVerseId: reference.endVerseId,
                        translation: translation
                    )
                    .padding()
                }
                .navigationTitle(reference.displayText)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showingSheet = false
                        }
                    }
                    if onNavigateToVerse != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showingSheet = false
                                onNavigateToVerse?(reference.verseId)
                            } label: {
                                Image(systemName: "arrow.up.right")
                            }
                        }
                    }
                }
                .presentationDetents([.fraction(0.4), .medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

// Simple flow layout for comma-separated items
// Uses caching to avoid recalculating positions during height changes
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat? = nil  // Vertical spacing between lines (defaults to spacing)

    // Cache structure to store layout calculations
    struct LayoutCache {
        var lastWidth: CGFloat = -1
        var lastSubviewCount: Int = -1
        var cachedSize: CGSize = .zero
        var cachedPositions: [CGPoint] = []
    }

    func makeCache(subviews: Subviews) -> LayoutCache {
        LayoutCache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout LayoutCache) -> CGSize {
        updateCacheIfNeeded(proposal: proposal, subviews: subviews, cache: &cache)
        return cache.cachedSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout LayoutCache) {
        updateCacheIfNeeded(proposal: proposal, subviews: subviews, cache: &cache)
        for (index, position) in cache.cachedPositions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func updateCacheIfNeeded(proposal: ProposedViewSize, subviews: Subviews, cache: inout LayoutCache) {
        let width = proposal.width ?? .infinity
        let subviewCount = subviews.count

        // Only recalculate if width or subview count changed
        if cache.lastWidth == width && cache.lastSubviewCount == subviewCount {
            return
        }

        let result = arrange(proposal: proposal, subviews: subviews)
        cache.lastWidth = width
        cache.lastSubviewCount = subviewCount
        cache.cachedSize = result.size
        cache.cachedPositions = result.positions
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        let verticalSpacing = lineSpacing ?? spacing
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - TSKe Views

// Parsed segment content for TSKe views - defined at file scope for reuse
private enum TSKSegmentContent {
    case word(String, italic: Bool, trailingSpace: Bool)
    case ref(sv: Int, ev: Int?, displayText: String, trailingSeparator: String?)
}

private struct TSKParsedSegment: Identifiable {
    let id: Int
    let content: TSKSegmentContent
}

// Cache for book OSIS IDs to avoid repeated Realm queries
private class BookOsisCache {
    static let shared = BookOsisCache()
    private var cache: [Int: String] = [:]

    func getOsisId(for bookId: Int) -> String {
        if let cached = cache[bookId] {
            return cached
        }
        let osisId = RealmManager.shared.realm.objects(Book.self).filter("id == \(bookId)").first?.osisId ?? ""
        cache[bookId] = osisId
        return osisId
    }
}

/// Data for a single TSKe ref (used for cross-segment navigation)
struct TSKRefItem {
    let index: Int
    let sourceVerseId: Int  // The verse section where this button is located
    let sv: Int             // The referenced verse (target of cross-reference)
    let ev: Int?
    let displayText: String
}

/// Builds a flat array of all TSKe refs in a chapter (for cross-segment navigation)
func buildTskRefArray(tskChapter: TSKChapter?, allTskVerses: Results<TSKVerse>) -> [TSKRefItem] {
    var refs: [TSKRefItem] = []
    var currentIndex = 0

    // Chapter overview refs (sourceVerseId = 0 for chapter-level content)
    if let chapter = tskChapter, !chapter.segmentsJson.isEmpty {
        let chapterRefs = parseRefsFromSegmentsJson(chapter.segmentsJson)
        for ref in chapterRefs {
            refs.append(TSKRefItem(index: currentIndex, sourceVerseId: 0, sv: ref.sv, ev: ref.ev, displayText: ref.displayText))
            currentIndex += 1
        }
    }

    // Verse refs (sourceVerseId = the verse section containing the button)
    for tskVerse in allTskVerses {
        for topic in tskVerse.topics {
            let topicRefs = parseRefsFromSegmentsJson(topic.segmentsJson)
            for ref in topicRefs {
                refs.append(TSKRefItem(index: currentIndex, sourceVerseId: tskVerse.id, sv: ref.sv, ev: ref.ev, displayText: ref.displayText))
                currentIndex += 1
            }
        }
    }

    return refs
}

/// Parses refs from segments JSON, returning (sv, ev, displayText) tuples
private func parseRefsFromSegmentsJson(_ json: String) -> [(sv: Int, ev: Int?, displayText: String)] {
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }

    var refs: [(sv: Int, ev: Int?, displayText: String)] = []
    var pendingSv: Int? = nil

    for dict in parsed {
        if let sv = dict["sv"] as? Int {
            // Flush any pending sv first
            if let prevSv = pendingSv {
                refs.append((sv: prevSv, ev: nil, displayText: buildRefDisplayText(sv: prevSv, ev: nil)))
            }

            // Check if this dict has both sv and ev
            if let ev = dict["ev"] as? Int {
                refs.append((sv: sv, ev: ev, displayText: buildRefDisplayText(sv: sv, ev: ev)))
                pendingSv = nil
            } else {
                pendingSv = sv
            }
        } else if let ev = dict["ev"] as? Int, let sv = pendingSv {
            refs.append((sv: sv, ev: ev, displayText: buildRefDisplayText(sv: sv, ev: ev)))
            pendingSv = nil
        } else if dict["t"] != nil, let sv = pendingSv {
            // Flush pending sv before text
            refs.append((sv: sv, ev: nil, displayText: buildRefDisplayText(sv: sv, ev: nil)))
            pendingSv = nil
        }
    }

    // Flush remaining pending sv
    if let sv = pendingSv {
        refs.append((sv: sv, ev: nil, displayText: buildRefDisplayText(sv: sv, ev: nil)))
    }

    return refs
}

/// Builds display text for a ref (e.g., "Gen 1:1" or "Gen 1:1-3")
private func buildRefDisplayText(sv: Int, ev: Int?) -> String {
    let (startVerse, startChapter, startBook) = splitVerseId(sv)
    let startOsisId = BookOsisCache.shared.getOsisId(for: startBook)

    if let ev = ev {
        let (endVerse, endChapter, endBook) = splitVerseId(ev)
        if startBook == endBook && startChapter == endChapter {
            return "\(startOsisId) \(startChapter):\(startVerse)-\(endVerse)"
        } else {
            let endOsisId = BookOsisCache.shared.getOsisId(for: endBook)
            return "\(startOsisId) \(startChapter):\(startVerse) - \(endOsisId) \(endChapter):\(endVerse)"
        }
    } else {
        return "\(startOsisId) \(startChapter):\(startVerse)"
    }
}

/// Counts the number of refs in a segments JSON string (for computing popover offsets)
func countRefsInSegmentsJson(_ json: String) -> Int {
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return 0
    }

    var count = 0
    var pendingSv = false

    for dict in parsed {
        if dict["sv"] != nil {
            // Flush any pending sv first (handles consecutive sv entries)
            if pendingSv {
                count += 1
                pendingSv = false
            }
            // Check if this dict has both sv and ev (complete range)
            if dict["ev"] != nil {
                count += 1
            } else {
                pendingSv = true
            }
        } else if dict["ev"] != nil && pendingSv {
            count += 1
            pendingSv = false
        } else if dict["t"] != nil && pendingSv {
            // Flush pending sv before text
            count += 1
            pendingSv = false
        }
    }

    // Flush remaining pending sv
    if pendingSv {
        count += 1
    }

    return count
}

/// Renders chapter overview segments (text + verse references) as flowing text using UITextView
struct TSKSegmentsView: View {
    let segmentsJson: String
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?
    var separateRefs: Bool = false

    // Shared state for cross-segment navigation (sheet-based)
    var baseOffset: Int = 0
    var sharedSheetState: Binding<TSKSheetState?>? = nil
    var sharedAllItems: Binding<[TSKTappableItem]>? = nil
    var totalCount: Int? = nil

    var body: some View {
        TSKLinkedText(
            segmentsJson: segmentsJson,
            translation: translation,
            fontSize: fontSize,
            onNavigateToVerse: onNavigateToVerse,
            separateRefs: separateRefs,
            baseOffset: baseOffset,
            sharedSheetState: sharedSheetState,
            sharedAllItems: sharedAllItems,
            totalCount: totalCount
        )
    }
}

struct TSKRefButton: View {
    let sv: Int
    let ev: Int?
    let displayText: String
    let translation: Translation
    let fontSize: Int
    let popoverIndex: Int
    @Binding var activePopoverIndex: Int?
    let totalPopoverCount: Int
    var onNavigateToVerse: ((Int) -> Void)?
    var onSwipeNavigate: ((Int) -> Void)?  // Callback for swipe navigation (scroll-first)
    @State private var showingSheet = false

    private var canSwipePrev: Bool { popoverIndex > 0 }
    private var canSwipeNext: Bool { popoverIndex < totalPopoverCount - 1 }

    private func handleSwipePrev() {
        if let onSwipe = onSwipeNavigate {
            // Use scroll-first navigation for LazyVStack
            onSwipe(popoverIndex - 1)
        } else {
            activePopoverIndex = popoverIndex - 1
        }
    }

    private func handleSwipeNext() {
        if let onSwipe = onSwipeNavigate {
            // Use scroll-first navigation for LazyVStack
            onSwipe(popoverIndex + 1)
        } else {
            activePopoverIndex = popoverIndex + 1
        }
    }

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Text(displayText)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundColor(.accentColor)
        }
        .sheet(isPresented: $showingSheet) {
            NavigationStack {
                ScrollView {
                    VerseSheetContent(
                        title: displayText,
                        verseId: sv,
                        endVerseId: ev,
                        translation: translation
                    )
                    .padding()
                }
                .navigationTitle(displayText)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            showingSheet = false
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        if totalPopoverCount > 1 {
                            HStack(spacing: 12) {
                                Button {
                                    showingSheet = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        handleSwipePrev()
                                        activePopoverIndex = popoverIndex - 1
                                    }
                                } label: {
                                    Image(systemName: "chevron.left")
                                }
                                .disabled(!canSwipePrev)

                                Text("\(popoverIndex + 1)/\(totalPopoverCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button {
                                    showingSheet = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        handleSwipeNext()
                                        activePopoverIndex = popoverIndex + 1
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                }
                                .disabled(!canSwipeNext)
                            }
                        }
                    }
                    if onNavigateToVerse != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showingSheet = false
                                onNavigateToVerse?(sv)
                            } label: {
                                Image(systemName: "arrow.up.right")
                            }
                        }
                    }
                }
                .presentationDetents([.fraction(0.4), .medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

/// Isolated view for a single verse's TSKe content - prevents cascade re-renders
struct TSKVerseSection: View {
    let verseId: Int
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?

    // Shared state for cross-segment navigation (sheet-based)
    var baseOffset: Int = 0
    var sharedSheetState: Binding<TSKSheetState?>? = nil
    var sharedAllItems: Binding<[TSKTappableItem]>? = nil
    var totalCount: Int? = nil

    private var verseNum: Int { verseId % 1000 }

    /// Load topics directly from Realm (computed once per render)
    private var topics: [(id: String, heading: String, segmentsJson: String, refCount: Int)] {
        guard let tskVerse = RealmManager.shared.realm.objects(TSKVerse.self).filter("id == \(verseId)").first else {
            return []
        }
        return Array(tskVerse.topics.map {
            (id: $0.id, heading: $0.h, segmentsJson: $0.segmentsJson, refCount: countRefsInSegmentsJson($0.segmentsJson))
        })
    }

    private func computeTopicOffsets() -> [Int] {
        var offsets: [Int] = []
        var runningOffset = baseOffset
        for topic in topics {
            offsets.append(runningOffset)
            runningOffset += topic.refCount
        }
        return offsets
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("v. \(verseNum)")
                .font(.system(size: CGFloat(fontSize - 2), weight: .semibold))
                .foregroundColor(.secondary)

            // Compute running offset for each topic
            let topicOffsets = computeTopicOffsets()

            ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                TSKTopicView(
                    heading: topic.heading,
                    segmentsJson: topic.segmentsJson,
                    translation: translation,
                    fontSize: fontSize,
                    onNavigateToVerse: onNavigateToVerse,
                    baseOffset: topicOffsets[index],
                    sharedSheetState: sharedSheetState,
                    sharedAllItems: sharedAllItems,
                    totalCount: totalCount
                )
            }
        }
    }
}

/// Displays a topic with its heading and segments (text + verse refs)
struct TSKTopicView: View {
    let heading: String
    let segmentsJson: String
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?

    // Shared state for cross-segment navigation (sheet-based)
    var baseOffset: Int = 0
    var sharedSheetState: Binding<TSKSheetState?>? = nil
    var sharedAllItems: Binding<[TSKTappableItem]>? = nil
    var totalCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Topic heading (skip if empty)
            if !heading.isEmpty {
                Text(heading)
                    .font(.system(size: CGFloat(fontSize - 2), weight: .medium))
                    .foregroundStyle(heading == "Reciprocal" ? .secondary : .primary)
            }

            // Segments (reuse the same view as chapter overview, with separators)
            if !segmentsJson.isEmpty {
                TSKSegmentsView(
                    segmentsJson: segmentsJson,
                    translation: translation,
                    fontSize: fontSize,
                    onNavigateToVerse: onNavigateToVerse,
                    separateRefs: true,
                    baseOffset: baseOffset,
                    sharedSheetState: sharedSheetState,
                    sharedAllItems: sharedAllItems,
                    totalCount: totalCount
                )
            }
        }
        .padding(.leading, 8)
    }
}

// MARK: - Commentary Sheet Items

/// Sheet item for Strong's number from commentary
struct CommentaryStrongsSheetItem: Identifiable {
    let key: String
    var id: String { key }
}

/// Sheet item for scripture reference from commentary
struct CommentaryScriptureSheetItem: Identifiable {
    let verseId: Int
    let endVerseId: Int?
    var id: String { "\(verseId)-\(endVerseId ?? 0)" }
}

// MARK: - TSKe UITextView Implementation

/// Custom attribute key for tappable indices in TSKe text
private let TSKTappableIndexKey = NSAttributedString.Key("tskTappableIndex")

/// Tappable item in TSKe content
struct TSKTappableItem: Equatable, Identifiable {
    let index: Int
    let sv: Int
    let ev: Int?
    let displayText: String

    var id: Int { index }
}

/// Sheet state for TSKe navigation
struct TSKSheetState: Equatable, Identifiable {
    let currentItem: TSKTappableItem
    let allItems: [TSKTappableItem]
    var totalCount: Int? = nil  // Pre-computed total (for lazy-loaded items)

    var id: String { "tsk-sheet" }

    var currentIndex: Int {
        allItems.firstIndex(where: { $0.index == currentItem.index }) ?? 0
    }

    // Use totalCount if provided, otherwise fall back to allItems.count
    var displayCount: Int { totalCount ?? allItems.count }

    var canNavigatePrev: Bool { currentIndex > 0 }
    var canNavigateNext: Bool { currentIndex < allItems.count - 1 }

    func withPrev() -> TSKSheetState? {
        guard canNavigatePrev else { return nil }
        return TSKSheetState(currentItem: allItems[currentIndex - 1], allItems: allItems, totalCount: totalCount)
    }

    func withNext() -> TSKSheetState? {
        guard canNavigateNext else { return nil }
        return TSKSheetState(currentItem: allItems[currentIndex + 1], allItems: allItems, totalCount: totalCount)
    }
}

/// SwiftUI view that renders TSKe segments using UITextView with tappable refs
struct TSKLinkedText: View {
    let segmentsJson: String
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?
    var separateRefs: Bool = false

    // Shared state for cross-segment navigation
    var baseOffset: Int = 0
    var sharedSheetState: Binding<TSKSheetState?>? = nil
    var sharedAllItems: Binding<[TSKTappableItem]>? = nil
    var totalCount: Int? = nil  // Pre-computed total for lazy-loaded items

    @State private var tappableItems: [TSKTappableItem] = []
    @State private var localSheetState: TSKSheetState? = nil

    private var effectiveSheetState: Binding<TSKSheetState?> {
        sharedSheetState ?? $localSheetState
    }

    private func navigateToPrev() {
        guard let current = effectiveSheetState.wrappedValue, let newState = current.withPrev() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    private func navigateToNext() {
        guard let current = effectiveSheetState.wrappedValue, let newState = current.withNext() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    var body: some View {
        TSKLinkedTextView(
            segmentsJson: segmentsJson,
            fontSize: fontSize,
            separateRefs: separateRefs,
            baseOffset: baseOffset,
            onLinkTap: { index in
                if let item = tappableItems.first(where: { $0.index == index }) {
                    let allItems = sharedAllItems?.wrappedValue ?? tappableItems
                    effectiveSheetState.wrappedValue = TSKSheetState(currentItem: item, allItems: allItems, totalCount: totalCount)
                }
            },
            onItemsParsed: { items in
                tappableItems = items
                if let sharedItems = sharedAllItems {
                    let otherItems = sharedItems.wrappedValue.filter { item in
                        item.index < baseOffset || item.index >= baseOffset + items.count
                    }
                    sharedItems.wrappedValue = (otherItems + items).sorted { $0.index < $1.index }
                }
            }
        )
        .sheet(item: sharedSheetState == nil ? $localSheetState : .constant(nil)) { state in
            sheetContent(state: state)
                .presentationDetents([.fraction(0.325), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
    }

    @ViewBuilder
    private func sheetContent(state: TSKSheetState) -> some View {
        let item = state.currentItem
        NavigationStack {
            ScrollView {
                VerseSheetContent(
                    title: item.displayText,
                    verseId: item.sv,
                    endVerseId: item.ev,
                    translation: translation,
                    onNavigate: onNavigateToVerse != nil ? {
                        effectiveSheetState.wrappedValue = nil
                        onNavigateToVerse?(item.sv)
                    } : nil
                )
                .padding()
            }
            .navigationTitle(item.displayText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        effectiveSheetState.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if onNavigateToVerse != nil {
                        Button {
                            effectiveSheetState.wrappedValue = nil
                            onNavigateToVerse?(item.sv)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if state.allItems.count > 1 {
                        Button(action: navigateToPrev) {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigatePrev)

                        Spacer()

                        Text("\(state.currentIndex + 1) of \(state.displayCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 8)

                        Spacer()

                        Button(action: navigateToNext) {
                            Image(systemName: "chevron.right")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigateNext)
                    }
                }
            }
        }
    }
}

/// UIViewRepresentable for TSKe linked text
private struct TSKLinkedTextView: UIViewRepresentable {
    let segmentsJson: String
    let fontSize: Int
    let separateRefs: Bool
    let baseOffset: Int
    let onLinkTap: (Int) -> Void
    let onItemsParsed: ([TSKTappableItem]) -> Void

    func makeUIView(context: Context) -> TSKTappableTextView {
        let textView = TSKTappableTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.onTappableIndexTap = context.coordinator.handleTap

        // Performance optimization: Draw on background thread
        textView.layer.drawsAsynchronously = true

        return textView
    }

    func updateUIView(_ textView: TSKTappableTextView, context: Context) {
        if context.coordinator.lastJson != segmentsJson || context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastJson = segmentsJson
            context.coordinator.lastFontSize = fontSize
            context.coordinator.cachedSize = nil  // Invalidate size cache
            let (attrString, items) = buildAttributedString()
            textView.attributedText = attrString
            context.coordinator.onLinkTap = onLinkTap
            textView.invalidateIntrinsicContentSize()

            DispatchQueue.main.async {
                onItemsParsed(items)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTap: onLinkTap)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TSKTappableTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width

        // Return cached size if width hasn't changed significantly
        if let cached = context.coordinator.cachedSize,
           abs(cached.width - width) < 1 {
            return cached
        }

        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let result = CGSize(width: width, height: size.height)
        context.coordinator.cachedSize = result
        return result
    }

    private func buildAttributedString() -> (NSAttributedString, [TSKTappableItem]) {
        guard let data = segmentsJson.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return (NSAttributedString(), [])
        }

        let result = NSMutableAttributedString()
        var tappableItems: [TSKTappableItem] = []
        var itemIndex = baseOffset
        let uiFont = UIFont.systemFont(ofSize: CGFloat(fontSize))
        var pendingSv: Int? = nil
        var isFirstRef = true
        var lastWasRef = false  // Track if last appended content was a ref

        // Add paragraph spacing for better readability
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        // Helper to check if result ends with whitespace
        func resultEndsWithWhitespace() -> Bool {
            guard result.length > 0 else { return true }
            let lastChar = result.string.last
            return lastChar?.isWhitespace == true
        }

        for (index, dict) in parsed.enumerated() {
            // Skip "Overview " prefix
            if index == 0, let text = dict["t"] as? String, text.hasPrefix("Overview") {
                continue
            }

            if let text = dict["t"] as? String {
                // Check if this is a range separator (hyphen/dash between sv and ev)
                // Don't flush pending sv if text is just a hyphen - ev might follow
                let isRangeSeparator = (text == "-" || text == "–" || text == "—") && pendingSv != nil

                // Flush any pending sv before text (unless it's a range separator)
                if let sv = pendingSv, !isRangeSeparator {
                    // Always add space before ref if result doesn't end with whitespace
                    if !resultEndsWithWhitespace() {
                        result.append(NSAttributedString(string: " ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    // In separateRefs mode, also add comma between refs
                    if separateRefs && !isFirstRef {
                        result.append(NSAttributedString(string: ", ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    let displayText = buildRefDescription(sv: sv, ev: nil)
                    result.append(NSAttributedString(string: displayText, attributes: [
                        .font: uiFont,
                        .foregroundColor: UIColor.tintColor,
                        .paragraphStyle: paragraphStyle,
                        TSKTappableIndexKey: itemIndex
                    ]))
                    tappableItems.append(TSKTappableItem(index: itemIndex, sv: sv, ev: nil, displayText: displayText))
                    itemIndex += 1
                    isFirstRef = false
                    pendingSv = nil
                    lastWasRef = true
                }

                // Skip range separators - they'll be included in the ref display text
                if isRangeSeparator {
                    continue
                }

                var cleaned = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")

                // Add space before text if last content was a ref and text doesn't start with whitespace
                // Include hyphens/dashes as needing space (they're text separators in TSKe, not punctuation)
                if lastWasRef && !cleaned.isEmpty {
                    let firstChar = cleaned.first!
                    let isHyphenOrDash = firstChar == "-" || firstChar == "–" || firstChar == "—"
                    let needsSpace = !firstChar.isWhitespace && (!firstChar.isPunctuation || isHyphenOrDash)
                    if needsSpace {
                        result.append(NSAttributedString(string: " ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                }

                let isItalic = dict["i"] as? Bool ?? false
                let font = isItalic ? UIFont.italicSystemFont(ofSize: CGFloat(fontSize)) : uiFont
                result.append(NSAttributedString(string: cleaned, attributes: [
                    .font: font,
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: paragraphStyle
                ]))
                lastWasRef = false

            } else if let sv = dict["sv"] as? Int {
                // Try Int first, then Double (JSONSerialization can parse large ints as Double), then String
                let evInSameDict: Int? = (dict["ev"] as? Int)
                    ?? (dict["ev"] as? Double).map { Int($0) }
                    ?? (dict["ev"] as? String).flatMap { Int($0) }

                // Flush any pending sv first
                if let prevSv = pendingSv {
                    // Always add space before ref if result doesn't end with whitespace
                    if !resultEndsWithWhitespace() {
                        result.append(NSAttributedString(string: " ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    // In separateRefs mode, also add comma between refs
                    if separateRefs && !isFirstRef {
                        result.append(NSAttributedString(string: ", ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    let displayText = buildRefDescription(sv: prevSv, ev: nil)
                    result.append(NSAttributedString(string: displayText, attributes: [
                        .font: uiFont,
                        .foregroundColor: UIColor.tintColor,
                        .paragraphStyle: paragraphStyle,
                        TSKTappableIndexKey: itemIndex
                    ]))
                    tappableItems.append(TSKTappableItem(index: itemIndex, sv: prevSv, ev: nil, displayText: displayText))
                    itemIndex += 1
                    isFirstRef = false
                    pendingSv = nil
                    lastWasRef = true
                }

                if let ev = evInSameDict {
                    // Always add space before ref if result doesn't end with whitespace
                    if !resultEndsWithWhitespace() {
                        result.append(NSAttributedString(string: " ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    // In separateRefs mode, also add comma between refs
                    if separateRefs && !isFirstRef {
                        result.append(NSAttributedString(string: ", ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    let displayText = buildRefDescription(sv: sv, ev: ev)
                    result.append(NSAttributedString(string: displayText, attributes: [
                        .font: uiFont,
                        .foregroundColor: UIColor.tintColor,
                        .paragraphStyle: paragraphStyle,
                        TSKTappableIndexKey: itemIndex
                    ]))
                    tappableItems.append(TSKTappableItem(index: itemIndex, sv: sv, ev: ev, displayText: displayText))
                    itemIndex += 1
                    isFirstRef = false
                    lastWasRef = true
                } else {
                    pendingSv = sv
                }

            } else if let ev = dict["ev"] as? Int {
                if let sv = pendingSv {
                    // Always add space before ref if result doesn't end with whitespace
                    if !resultEndsWithWhitespace() {
                        result.append(NSAttributedString(string: " ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    // In separateRefs mode, also add comma between refs
                    if separateRefs && !isFirstRef {
                        result.append(NSAttributedString(string: ", ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
                    }
                    let displayText = buildRefDescription(sv: sv, ev: ev)
                    result.append(NSAttributedString(string: displayText, attributes: [
                        .font: uiFont,
                        .foregroundColor: UIColor.tintColor,
                        .paragraphStyle: paragraphStyle,
                        TSKTappableIndexKey: itemIndex
                    ]))
                    tappableItems.append(TSKTappableItem(index: itemIndex, sv: sv, ev: ev, displayText: displayText))
                    itemIndex += 1
                    isFirstRef = false
                    pendingSv = nil
                    lastWasRef = true
                }
            }
        }

        // Flush remaining pending sv
        if let sv = pendingSv {
            // Always add space before ref if result doesn't end with whitespace
            if !resultEndsWithWhitespace() {
                result.append(NSAttributedString(string: " ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
            }
            // In separateRefs mode, also add comma between refs
            if separateRefs && !isFirstRef {
                result.append(NSAttributedString(string: ", ", attributes: [.font: uiFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraphStyle]))
            }
            let displayText = buildRefDescription(sv: sv, ev: nil)
            result.append(NSAttributedString(string: displayText, attributes: [
                .font: uiFont,
                .foregroundColor: UIColor.tintColor,
                .paragraphStyle: paragraphStyle,
                TSKTappableIndexKey: itemIndex
            ]))
            tappableItems.append(TSKTappableItem(index: itemIndex, sv: sv, ev: nil, displayText: displayText))
        }

        return (result, tappableItems)
    }

    private func buildRefDescription(sv: Int, ev: Int?) -> String {
        let (startVerse, startChapter, startBook) = splitVerseId(sv)
        let startOsisId = BookOsisCache.shared.getOsisId(for: startBook)

        if let ev = ev {
            let (endVerse, endChapter, endBook) = splitVerseId(ev)
            if startBook == endBook && startChapter == endChapter {
                return "\(startOsisId) \(startChapter):\(startVerse)-\(endVerse)"
            } else {
                let endOsisId = BookOsisCache.shared.getOsisId(for: endBook)
                return "\(startOsisId) \(startChapter):\(startVerse) - \(endOsisId) \(endChapter):\(endVerse)"
            }
        } else {
            return "\(startOsisId) \(startChapter):\(startVerse)"
        }
    }

    class Coordinator {
        var onLinkTap: (Int) -> Void
        var lastJson: String = ""
        var lastFontSize: Int = 0
        var cachedSize: CGSize?

        init(onLinkTap: @escaping (Int) -> Void) {
            self.onLinkTap = onLinkTap
        }

        func handleTap(_ index: Int) {
            onLinkTap(index)
        }
    }
}

/// UITextView subclass using TextKit 1 for TSKe tap handling
private class TSKTappableTextView: UITextView {
    var onTappableIndexTap: ((Int) -> Void)?

    private let textKit1LayoutManager = NSLayoutManager()
    private let textKit1TextContainer = NSTextContainer()
    private let textKit1TextStorage = NSTextStorage()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        textKit1TextStorage.addLayoutManager(textKit1LayoutManager)
        textKit1LayoutManager.addTextContainer(textKit1TextContainer)
        textKit1TextContainer.widthTracksTextView = true
        textKit1TextContainer.heightTracksTextView = false

        super.init(frame: frame, textContainer: textKit1TextContainer)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)

        let textContainerOffset = CGPoint(
            x: textContainerInset.left,
            y: textContainerInset.top
        )
        let locationInTextContainer = CGPoint(
            x: location.x - textContainerOffset.x,
            y: location.y - textContainerOffset.y
        )

        let characterIndex = textKit1LayoutManager.characterIndex(
            for: locationInTextContainer,
            in: textKit1TextContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        guard characterIndex < textKit1TextStorage.length else { return }

        let attributes = textKit1TextStorage.attributes(at: characterIndex, effectiveRange: nil)
        if let tappableIndex = attributes[TSKTappableIndexKey] as? Int {
            onTappableIndexTap?(tappableIndex)
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            textKit1TextStorage.setAttributedString(attributedText ?? NSAttributedString())
        }
    }
}

/// Shared verse content view for displaying verse text in sheets/popovers
/// Used by TSKe, Cross References, Lexicon, and Search views
struct VerseSheetContent: View {
    let title: String
    let verseId: Int
    let endVerseId: Int?
    let translation: Translation?
    var onNavigate: (() -> Void)? = nil

    // Optional context support (for search results)
    var contextAmount: SearchContextAmount? = nil

    // Optional highlighting support (for search results)
    var highlightQuery: String? = nil
    var highlightMode: SearchMode? = nil

    init(title: String, verseId: Int, endVerseId: Int? = nil, translation: Translation?, onNavigate: (() -> Void)? = nil) {
        self.title = title
        self.verseId = verseId
        self.endVerseId = endVerseId
        self.translation = translation
        self.onNavigate = onNavigate
    }

    init(title: String, verseId: Int, endVerseId: Int? = nil, translation: Translation?, onNavigate: (() -> Void)? = nil, contextAmount: SearchContextAmount?, highlightQuery: String?, highlightMode: SearchMode?) {
        self.title = title
        self.verseId = verseId
        self.endVerseId = endVerseId
        self.translation = translation
        self.onNavigate = onNavigate
        self.contextAmount = contextAmount
        self.highlightQuery = highlightQuery
        self.highlightMode = highlightMode
    }

    /// Returns the primary (hit) verses without context
    private var primaryVerses: [Verse] {
        guard let translation = translation else { return [] }
        let startId = verseId
        let endId = endVerseId ?? verseId
        // Query through translation's verses list to avoid orphaned verses
        return Array(translation.verses.filter("id >= \(startId) AND id <= \(endId)"))
    }

    /// Returns verses with context if contextAmount is set
    private var versesWithContext: [(verse: Verse, isContext: Bool)] {
        guard let translation = translation else { return [] }

        // If no context requested, just return primary verses
        guard let contextAmount = contextAmount else {
            return primaryVerses.map { ($0, false) }
        }

        let (_, chapter, book) = splitVerseId(verseId)
        let chapterVerses = Array(translation.verses.filter("b == %@ AND c == %@", book, chapter).sorted(byKeyPath: "v"))

        guard let index = chapterVerses.firstIndex(where: { $0.id == verseId }) else {
            return primaryVerses.map { ($0, false) }
        }

        let contextCount: Int
        switch contextAmount {
        case .oneVerse:
            contextCount = 1
        case .threeVerses:
            contextCount = 3
        case .chapter:
            return chapterVerses.map { ($0, $0.id != verseId) }
        }

        let startIndex = max(0, index - contextCount)
        let endIndex = min(chapterVerses.count - 1, index + contextCount)
        return Array(chapterVerses[startIndex...endIndex]).map { ($0, $0.id != verseId) }
    }

    private var versesText: AttributedString {
        let allVerses = versesWithContext
        if allVerses.isEmpty {
            var notFound = AttributedString("Verse not found")
            notFound.foregroundColor = .secondary
            return notFound
        }

        var result = AttributedString()
        for (index, item) in allVerses.enumerated() {
            let verse = item.verse
            let isContext = item.isContext

            // Add verse number as superscript
            var verseNum = AttributedString("\(verse.v)")
            verseNum.font = .caption
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4

            // Add verse text (with optional highlighting)
            let verseTextContent: AttributedString
            if !isContext, let query = highlightQuery, !query.isEmpty {
                if highlightMode == .strongs {
                    verseTextContent = highlightedStrongsAttributedText(verse.t, strongsNum: query.uppercased())
                } else {
                    verseTextContent = highlightedTextAttributedString(stripStrongsAnnotations(verse.t), query: query)
                }
            } else {
                var text = AttributedString(" " + stripStrongsAnnotations(verse.t))
                text.font = .body
                verseTextContent = text
            }

            // Apply muted style to context verses
            if isContext {
                var mutedNum = verseNum
                mutedNum.foregroundColor = .secondary.opacity(0.5)
                result.append(mutedNum)

                var mutedText = verseTextContent
                mutedText.foregroundColor = .secondary.opacity(0.6)
                result.append(mutedText)
            } else {
                result.append(verseNum)
                result.append(verseTextContent)
            }

            // Add space between verses (but not after the last one)
            if index < allVerses.count - 1 {
                result.append(AttributedString("  "))
            }
        }
        return result
    }

    private func highlightedTextAttributedString(_ text: String, query: String) -> AttributedString {
        var result = AttributedString(" ")
        let lowercaseText = text.lowercased()
        let lowercaseQuery = query.lowercased()

        guard lowercaseText.contains(lowercaseQuery) else {
            var plain = AttributedString(text)
            plain.font = .body
            result.append(plain)
            return result
        }

        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            if let range = text.range(of: query, options: .caseInsensitive, range: currentIndex..<text.endIndex) {
                if currentIndex < range.lowerBound {
                    var before = AttributedString(String(text[currentIndex..<range.lowerBound]))
                    before.font = .body
                    result.append(before)
                }
                var highlight = AttributedString(String(text[range]))
                highlight.font = .body.bold()
                highlight.foregroundColor = .accentColor
                result.append(highlight)
                currentIndex = range.upperBound
            } else {
                var remaining = AttributedString(String(text[currentIndex..<text.endIndex]))
                remaining.font = .body
                result.append(remaining)
                break
            }
        }

        return result
    }

    private func highlightedStrongsAttributedText(_ text: String, strongsNum: String) -> AttributedString {
        var result = AttributedString(" ")

        let pattern = "\\{([^|]+)\\|([^}]+)\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            var plain = AttributedString(stripStrongsAnnotations(text))
            plain.font = .body
            result.append(plain)
            return result
        }

        let nsText = text as NSString
        var currentIndex = 0
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            if match.range.location > currentIndex {
                let beforeText = nsText.substring(with: NSRange(location: currentIndex, length: match.range.location - currentIndex))
                var before = AttributedString(beforeText)
                before.font = .body
                result.append(before)
            }

            let wordRange = match.range(at: 1)
            let annotationRange = match.range(at: 2)
            let word = nsText.substring(with: wordRange)
            let annotation = nsText.substring(with: annotationRange)

            if annotationContainsStrongs(annotation, strongsNum: strongsNum) {
                var highlight = AttributedString(word)
                highlight.font = .body.bold()
                highlight.foregroundColor = .accentColor
                result.append(highlight)
            } else {
                var plain = AttributedString(word)
                plain.font = .body
                result.append(plain)
            }

            currentIndex = match.range.location + match.range.length
        }

        if currentIndex < nsText.length {
            let remainingText = nsText.substring(from: currentIndex)
            var remaining = AttributedString(remainingText)
            remaining.font = .body
            result.append(remaining)
        }

        return result
    }

    private func annotationContainsStrongs(_ annotation: String, strongsNum: String) -> Bool {
        let parts = annotation.components(separatedBy: CharacterSet(charactersIn: ",|"))
        return parts.contains { $0.trimmingCharacters(in: .whitespaces) == strongsNum }
    }

    var body: some View {
        Text(versesText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cross Reference UITextView Types

/// Tappable item for cross references
struct CrossRefTappableItem: Equatable, Identifiable {
    let index: Int
    let sv: Int
    let ev: Int?
    let displayText: String

    var id: Int { index }
}

/// Sheet state for cross reference navigation
struct CrossRefSheetState: Equatable, Identifiable {
    let currentItem: CrossRefTappableItem
    let allItems: [CrossRefTappableItem]
    var totalCount: Int? = nil

    var id: String { "crossref-sheet" }

    var currentIndex: Int {
        allItems.firstIndex(where: { $0.index == currentItem.index }) ?? 0
    }

    var displayCount: Int { totalCount ?? allItems.count }

    var canNavigatePrev: Bool { currentIndex > 0 }
    var canNavigateNext: Bool { currentIndex < allItems.count - 1 }

    func withPrev() -> CrossRefSheetState? {
        guard canNavigatePrev else { return nil }
        return CrossRefSheetState(currentItem: allItems[currentIndex - 1], allItems: allItems, totalCount: totalCount)
    }

    func withNext() -> CrossRefSheetState? {
        guard canNavigateNext else { return nil }
        return CrossRefSheetState(currentItem: allItems[currentIndex + 1], allItems: allItems, totalCount: totalCount)
    }
}

/// Custom attribute key for cross reference tappable indices
private let CrossRefTappableIndexKey = NSAttributedString.Key("crossRefTappableIndex")

/// SwiftUI view that renders cross references using UITextView with tappable refs
struct CrossRefLinkedText: View {
    let crossRefs: [CrossReference]
    let translation: Translation
    let fontSize: Int
    var onNavigateToVerse: ((Int) -> Void)?

    // Shared state for cross-segment navigation
    var baseOffset: Int = 0
    var sharedSheetState: Binding<CrossRefSheetState?>? = nil
    var sharedAllItems: Binding<[CrossRefTappableItem]>? = nil
    var totalCount: Int? = nil

    @State private var tappableItems: [CrossRefTappableItem] = []
    @State private var localSheetState: CrossRefSheetState? = nil

    private var effectiveSheetState: Binding<CrossRefSheetState?> {
        sharedSheetState ?? $localSheetState
    }

    private func navigateToPrev() {
        guard let current = effectiveSheetState.wrappedValue, let newState = current.withPrev() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    private func navigateToNext() {
        guard let current = effectiveSheetState.wrappedValue, let newState = current.withNext() else { return }
        effectiveSheetState.wrappedValue = newState
    }

    var body: some View {
        CrossRefLinkedTextView(
            crossRefs: crossRefs,
            fontSize: fontSize,
            baseOffset: baseOffset,
            onLinkTap: { index in
                if let item = tappableItems.first(where: { $0.index == index }) {
                    let allItems = sharedAllItems?.wrappedValue ?? tappableItems
                    effectiveSheetState.wrappedValue = CrossRefSheetState(currentItem: item, allItems: allItems, totalCount: totalCount)
                }
            },
            onItemsParsed: { items in
                tappableItems = items
                if let sharedItems = sharedAllItems {
                    let otherItems = sharedItems.wrappedValue.filter { item in
                        item.index < baseOffset || item.index >= baseOffset + items.count
                    }
                    sharedItems.wrappedValue = (otherItems + items).sorted { $0.index < $1.index }
                }
            }
        )
        .sheet(item: sharedSheetState == nil ? $localSheetState : .constant(nil)) { state in
            sheetContent(state: state)
                .presentationDetents([.fraction(0.325), .medium, .large])
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
        }
    }

    @ViewBuilder
    private func sheetContent(state: CrossRefSheetState) -> some View {
        let item = state.currentItem
        NavigationStack {
            ScrollView {
                CrossRefVerseContent(
                    title: item.displayText,
                    verseId: item.sv,
                    endVerseId: item.ev,
                    translation: translation
                )
                .padding()
            }
            .id("\(item.sv)-\(item.ev ?? 0)")
            .navigationTitle(item.displayText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        effectiveSheetState.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if onNavigateToVerse != nil {
                        Button {
                            effectiveSheetState.wrappedValue = nil
                            onNavigateToVerse?(item.sv)
                        } label: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if state.allItems.count > 1 {
                        Button(action: navigateToPrev) {
                            Image(systemName: "chevron.left")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigatePrev)

                        Spacer()

                        Text("\(state.currentIndex + 1) of \(state.displayCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.horizontal, 8)

                        Spacer()

                        Button(action: navigateToNext) {
                            Image(systemName: "chevron.right")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canNavigateNext)
                    }
                }
            }
        }
    }
}

/// UIViewRepresentable for cross reference linked text
private struct CrossRefLinkedTextView: UIViewRepresentable {
    let crossRefs: [CrossReference]
    let fontSize: Int
    let baseOffset: Int
    let onLinkTap: (Int) -> Void
    let onItemsParsed: ([CrossRefTappableItem]) -> Void

    func makeUIView(context: Context) -> CrossRefTappableTextView {
        let textView = CrossRefTappableTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.onTappableIndexTap = context.coordinator.handleTap

        // Performance optimization: Draw on background thread
        textView.layer.drawsAsynchronously = true

        return textView
    }

    func updateUIView(_ textView: CrossRefTappableTextView, context: Context) {
        let refsKey = crossRefs.map { "\($0.sv)-\($0.ev ?? 0)" }.joined(separator: ",")
        if context.coordinator.lastRefsKey != refsKey || context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastRefsKey = refsKey
            context.coordinator.lastFontSize = fontSize
            context.coordinator.cachedSize = nil  // Invalidate size cache
            let (attrString, items) = buildAttributedString()
            textView.attributedText = attrString
            context.coordinator.onLinkTap = onLinkTap
            textView.invalidateIntrinsicContentSize()

            DispatchQueue.main.async {
                onItemsParsed(items)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLinkTap: onLinkTap)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CrossRefTappableTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width

        // Return cached size if width hasn't changed significantly
        if let cached = context.coordinator.cachedSize,
           abs(cached.width - width) < 1 {
            return cached
        }

        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        let result = CGSize(width: width, height: size.height)
        context.coordinator.cachedSize = result
        return result
    }

    private func buildAttributedString() -> (NSAttributedString, [CrossRefTappableItem]) {
        let result = NSMutableAttributedString()
        var tappableItems: [CrossRefTappableItem] = []
        var itemIndex = baseOffset
        let uiFont = UIFont.systemFont(ofSize: CGFloat(fontSize))

        // Add paragraph spacing for better readability
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4

        for (index, crossRef) in crossRefs.enumerated() {
            let displayText = buildRefDescription(sv: crossRef.sv, ev: crossRef.ev)

            result.append(NSAttributedString(string: displayText, attributes: [
                .font: uiFont,
                .foregroundColor: UIColor.tintColor,
                .paragraphStyle: paragraphStyle,
                CrossRefTappableIndexKey: itemIndex
            ]))

            tappableItems.append(CrossRefTappableItem(index: itemIndex, sv: crossRef.sv, ev: crossRef.ev, displayText: displayText))
            itemIndex += 1

            // Add comma separator (except for last item)
            if index < crossRefs.count - 1 {
                result.append(NSAttributedString(string: ", ", attributes: [
                    .font: uiFont,
                    .foregroundColor: UIColor.secondaryLabel,
                    .paragraphStyle: paragraphStyle
                ]))
            }
        }

        return (result, tappableItems)
    }

    private func buildRefDescription(sv: Int, ev: Int?) -> String {
        let (startVerse, startChapter, startBook) = splitVerseId(sv)
        let startOsisId = BookOsisCache.shared.getOsisId(for: startBook)

        if let ev = ev {
            let (endVerse, endChapter, endBook) = splitVerseId(ev)
            if startBook == endBook && startChapter == endChapter {
                return "\(startOsisId) \(startChapter):\(startVerse)-\(endVerse)"
            } else {
                let endOsisId = BookOsisCache.shared.getOsisId(for: endBook)
                return "\(startOsisId) \(startChapter):\(startVerse) - \(endOsisId) \(endChapter):\(endVerse)"
            }
        } else {
            return "\(startOsisId) \(startChapter):\(startVerse)"
        }
    }

    class Coordinator {
        var onLinkTap: (Int) -> Void
        var lastRefsKey: String = ""
        var lastFontSize: Int = 0
        var cachedSize: CGSize?

        init(onLinkTap: @escaping (Int) -> Void) {
            self.onLinkTap = onLinkTap
        }

        func handleTap(_ index: Int) {
            onLinkTap(index)
        }
    }
}

/// UITextView subclass using TextKit 1 for cross reference tap handling
private class CrossRefTappableTextView: UITextView {
    var onTappableIndexTap: ((Int) -> Void)?

    private let textKit1LayoutManager = NSLayoutManager()
    private let textKit1TextContainer = NSTextContainer()
    private let textKit1TextStorage = NSTextStorage()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        textKit1TextStorage.addLayoutManager(textKit1LayoutManager)
        textKit1LayoutManager.addTextContainer(textKit1TextContainer)
        textKit1TextContainer.widthTracksTextView = true
        textKit1TextContainer.heightTracksTextView = false

        super.init(frame: frame, textContainer: textKit1TextContainer)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tapGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)

        let textContainerOffset = CGPoint(
            x: textContainerInset.left,
            y: textContainerInset.top
        )
        let locationInTextContainer = CGPoint(
            x: location.x - textContainerOffset.x,
            y: location.y - textContainerOffset.y
        )

        let characterIndex = textKit1LayoutManager.characterIndex(
            for: locationInTextContainer,
            in: textKit1TextContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        guard characterIndex < textKit1TextStorage.length else { return }

        let attributes = textKit1TextStorage.attributes(at: characterIndex, effectiveRange: nil)
        if let tappableIndex = attributes[CrossRefTappableIndexKey] as? Int {
            onTappableIndexTap?(tappableIndex)
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            textKit1TextStorage.setAttributedString(attributedText ?? NSAttributedString())
        }
    }
}

/// Verse content for cross reference sheets (paragraph format)
struct CrossRefVerseContent: View {
    let title: String
    let verseId: Int
    let endVerseId: Int?
    let translation: Translation

    private var verses: [Verse] {
        let startId = verseId
        let endId = endVerseId ?? verseId
        return Array(RealmManager.shared.realm.objects(Verse.self)
            .filter("tr == \(translation.id) AND id >= \(startId) AND id <= \(endId)"))
    }

    private var versesText: AttributedString {
        if verses.isEmpty {
            var notFound = AttributedString("Verse not found")
            notFound.foregroundColor = .secondary
            return notFound
        }

        var result = AttributedString()
        for (index, verse) in verses.enumerated() {
            var verseNum = AttributedString("\(verse.v)")
            verseNum.font = .caption
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4

            var text = AttributedString(" " + stripStrongsAnnotations(verse.t))
            text.font = .body

            result.append(verseNum)
            result.append(text)

            if index < verses.count - 1 {
                result.append(AttributedString("  "))
            }
        }
        return result
    }

    var body: some View {
        Text(versesText)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    ToolPanelView(
        book: 43,
        chapter: 3,
        currentVerse: 16,
        user: RealmManager.shared.realm.objects(User.self).first!
    )
}
