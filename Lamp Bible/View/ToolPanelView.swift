//
//  ToolPanelView.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-27.
//

import Foundation
import GRDB
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
    // Full verseId (BBCCCVVV) -> yPosition (set by ReaderScrollSpyView)
    private var readerVersePositions: [Int: CGFloat] = [:]
    // Sorted full verseIds for closest-preceding binary search
    private var sortedReaderVerseIds: [Int] = []

    // Current state
    private(set) var currentVerse: Int = 1
    private(set) var activeScroller: ScrollSource = .none
    private var lastReportedReaderVerse: Int = 0

    /// Temporarily pause scroll sync (e.g., during keyboard display)
    var isPaused: Bool = false

    /// Whether toolbars are hidden (affects scroll offset calculation)
    var toolbarsHidden: Bool = false

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
        sortedReaderVerseIds = positions.keys.sorted()
    }

    func registerToolPanel(_ controller: any ToolPanelScrollable) {
        toolPanelController = controller
    }

    /// Called by reader when user scrolls - direct from UIKit
    func readerDidScrollToVerse(_ verse: Int) {
        guard isScrollLinked && !isPaused else { return }
        guard activeScroller != .toolPanel else { return }
        // Update currentVerse for state tracking
        currentVerse = verse
        activeScroller = .reader
        // Direct call - no throttling since we're using lightweight setContentOffset
        toolPanelController?.scrollToVerse(verse, animated: false)
    }

    /// Called by tool panel when user scrolls
    func toolPanelDidScrollToVerse(_ verse: Int) {
        guard isScrollLinked && !isPaused else { return }
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

        // Find matching y or closest preceding verseId using cached lookup.
        var targetY: CGFloat? = readerVersePositions[verse]
        if targetY == nil, !sortedReaderVerseIds.isEmpty {
            // Binary search for last verseId <= verse (BBCCCVVV sorts naturally)
            var low = 0
            var high = sortedReaderVerseIds.count - 1
            var best: Int? = nil
            while low <= high {
                let mid = (low + high) / 2
                let v = sortedReaderVerseIds[mid]
                if v <= verse {
                    best = v
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            if let best, let y = readerVersePositions[best] {
                targetY = y
            }
        }

        if let y = targetY {
            // Account for safe area (notch) plus SwiftUI navigation toolbar when visible
            let toolbarHeight: CGFloat = toolbarsHidden ? 0 : 44
            let topOffset = scrollView.safeAreaInsets.top + toolbarHeight
            let adjustedY = y - topOffset

            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            let clampedY = min(max(0, adjustedY), maxY)

            // Skip tiny adjustments to avoid churn.
            if abs(scrollView.contentOffset.y - clampedY) > 0.5 {
                scrollView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
            }
        }
    }

    /// Scroll the reader to a specific verse ID (book*1000000 + chapter*1000 + verse)
    /// Returns true if scroll was performed, false if scroll view not ready or position not found
    @discardableResult
    func scrollReaderToVerseId(_ verseId: Int) -> Bool {
        guard let scrollView = readerScrollView else { return false }

        // Try exact match first
        var targetY: CGFloat? = readerVersePositions[verseId]

        // If no exact match, find closest preceding verse in the same chapter
        if targetY == nil {
            let targetVerse = verseId % 1000
            let chapterPrefix = verseId / 1000 * 1000

            let chapterPositions = readerVersePositions.filter { ($0.key / 1000 * 1000) == chapterPrefix }
            if let closest = chapterPositions
                .filter({ ($0.key % 1000) <= targetVerse })
                .max(by: { $0.key < $1.key }) {
                targetY = closest.value
            }
        }

        guard let y = targetY else { return false }

        // Account for safe area plus navigation toolbar
        let topOffset = scrollView.safeAreaInsets.top + 44
        let adjustedY = y - topOffset

        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let clampedY = min(max(0, adjustedY), maxY)

        scrollView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: false)
        return true
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
    private var isPullNavigationTriggered: Bool = false // Suppress progress after navigation triggers

    // Cached sorted positions for fast lookup during scrolling
    private var sortedVersePositions: [(verseId: Int, yPos: CGFloat)] = []

    // Optional callback for SwiftUI to observe verse changes without doing expensive geometry tracking
    var onVerseIdChange: ((Int) -> Void)?

    // Optional callback fired when user scroll ends (drag end without decel, or decel end)
    // Provides the last reported verseId (full id, not just verse number).
    var onUserScrollEndedAtVerseId: ((Int) -> Void)?

    // Optional callback fired when user scroll completely stops (including deceleration)
    var onScrollFullyStopped: (() -> Void)?

    // Pull-to-refresh callbacks (triggered when user releases while overscrolled)
    var onPullToLoadPrevious: (() -> Void)?
    var onPullToLoadNext: (() -> Void)?

    // Pull progress callbacks (0.0 to 1.0+, for scaling arrows)
    var onPullProgressTop: ((CGFloat) -> Void)?
    var onPullProgressBottom: ((CGFloat) -> Void)?

    // Threshold for triggering pull-to-refresh (in points)
    private let pullToRefreshThreshold: CGFloat = 84

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

        // Report pull progress for arrow scaling
        reportPullProgress(scrollView: scrollView)

        // Skip during initial load
        guard isReady else { return }

        // Skip if tool panel is in control
        guard coordinator.activeScroller != .toolPanel else { return }

        // Calculate which verse is at the top of the visible area
        let offset = scrollView.contentOffset.y + scrollView.safeAreaInsets.top

        if let verseId = findVerseIdAtOffset(offset) {
            // Use full verse ID for multi-chapter support
            if verseId != lastReportedVerseId {
                lastReportedVerseId = verseId
                lastProcessedOffset = offset
                // Direct sync using full verse ID (handles multi-chapter readings)
                coordinator.readerDidScrollToVerse(verseId)
            }
        }
    }

    /// Report pull progress for arrow scaling effect
    private func reportPullProgress(scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        let contentHeight = scrollView.contentSize.height
        let viewportHeight = scrollView.bounds.height

        // Guard against invalid state (during layout or before content is sized)
        guard viewportHeight > 0, contentHeight > 0 else {
            onPullProgressTop?(0)
            onPullProgressBottom?(0)
            return
        }

        // Only report progress when user is actively scrolling (not programmatic)
        // Also suppress if navigation was just triggered (waiting for new chapter to load)
        guard !isPullNavigationTriggered,
              isUserScrolling || scrollView.isTracking || scrollView.isDragging else {
            onPullProgressTop?(0)
            onPullProgressBottom?(0)
            return
        }

        // Account for content insets (toolbars, safe areas)
        let topInset = scrollView.adjustedContentInset.top
        let bottomInset = scrollView.adjustedContentInset.bottom

        // Pull down at top (negative offset = overscrolled past top)
        // Top overscroll starts when offset goes below -topInset
        if offset < -topInset {
            let overscroll = -(offset + topInset)
            let progress = min(2.0, overscroll / pullToRefreshThreshold)
            onPullProgressTop?(progress)
        } else {
            onPullProgressTop?(0)
        }

        // Pull up at bottom (offset past content end)
        // Account for bottom inset (toolbar height)
        let maxOffset = contentHeight - viewportHeight + bottomInset
        if maxOffset > 0 && offset > maxOffset {
            let overscroll = offset - maxOffset
            let progress = min(2.0, overscroll / pullToRefreshThreshold)
            onPullProgressBottom?(progress)
        } else {
            onPullProgressBottom?(0)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        originalDelegate?.scrollViewWillBeginDragging?(scrollView)
        isUserScrolling = true
        isPullNavigationTriggered = false  // Reset flag for new scroll gesture
        coordinator.readerBeganScrolling()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        originalDelegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)

        // Check for pull-to-refresh gestures
        checkPullToRefresh(scrollView: scrollView)

        if !decelerate {
            // Scroll stopped immediately - sync tool panel now
            isUserScrolling = false
            coordinator.scrollEnded(from: .reader)
            coordinator.readerDidScrollToVerse(lastReportedVerseId)
            onUserScrollEndedAtVerseId?(lastReportedVerseId)
            onScrollFullyStopped?()
            onVerseIdChange?(lastReportedVerseId)
        }
    }

    /// Check if user released while overscrolled past threshold and trigger pull-to-refresh
    private func checkPullToRefresh(scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        let contentHeight = scrollView.contentSize.height
        let viewportHeight = scrollView.bounds.height

        // Account for content insets (toolbars, safe areas) - must match reportPullProgress
        let topInset = scrollView.adjustedContentInset.top
        let bottomInset = scrollView.adjustedContentInset.bottom

        // Pull down at top - check if overscroll exceeds threshold
        // Top overscroll starts when offset goes below -topInset
        if offset < -topInset {
            let overscroll = -(offset + topInset)
            if overscroll >= pullToRefreshThreshold {
                isPullNavigationTriggered = true
                onPullProgressTop?(0)
                onPullProgressBottom?(0)
                onPullToLoadPrevious?()
                return
            }
        }

        // Pull up at bottom - check if overscroll exceeds threshold
        let maxOffset = contentHeight - viewportHeight + bottomInset
        if maxOffset > 0 && offset > maxOffset {
            let overscroll = offset - maxOffset
            if overscroll >= pullToRefreshThreshold {
                isPullNavigationTriggered = true
                onPullProgressTop?(0)
                onPullProgressBottom?(0)
                onPullToLoadNext?()
            }
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        originalDelegate?.scrollViewDidEndDecelerating?(scrollView)
        // Deceleration finished - sync tool panel now
        isUserScrolling = false
        coordinator.scrollEnded(from: .reader)
        coordinator.readerDidScrollToVerse(lastReportedVerseId)
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
    var onPullToLoadPrevious: (() -> Void)? = nil
    var onPullToLoadNext: (() -> Void)? = nil
    var onPullProgressTop: ((CGFloat) -> Void)? = nil
    var onPullProgressBottom: ((CGFloat) -> Void)? = nil

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
        uiView.onPullToLoadPrevious = onPullToLoadPrevious
        uiView.onPullToLoadNext = onPullToLoadNext
        uiView.onPullProgressTop = onPullProgressTop
        uiView.onPullProgressBottom = onPullProgressBottom
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
    var additionalTopOffset: CGFloat = 0  // Extra offset for collapsed header in horizontal split

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
        uiViewController.additionalTopOffset = additionalTopOffset

        // Ensure this controller is registered for scroll sync (re-register on every update
        // in case SwiftUI recreated the view or another panel was active)
        ScrollSyncCoordinator.shared.registerToolPanel(uiViewController)

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

    // Additional top offset for collapsed header in horizontal split
    var additionalTopOffset: CGFloat = 0

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Overscroll padding: allows last item to scroll up for scroll-sync
        let bottomInset = max(0, collectionView.bounds.height - 150)
        if collectionView.contentInset.bottom != bottomInset {
            collectionView.contentInset.bottom = bottomInset
        }
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
        let oldItems = self.items
        self.items = newItems
        self.rawData = rawData

        var snapshot = NSDiffableDataSourceSnapshot<Int, VerseItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(newItems)

        // Find items that exist in both old and new (same id) - these need reconfiguring
        // because their underlying data may have changed (e.g., footnotes edited)
        let oldIds = Set(oldItems.map { $0.id })
        let itemsToReconfigure = newItems.filter { oldIds.contains($0.id) }
        if !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }

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
            // Account for safe area (notch) plus any additional offset (collapsed header)
            let topInset = collectionView.safeAreaInsets.top + additionalTopOffset
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

/// Gap info for verse gaps in notes
struct NoteGapInfo: Equatable {
    let gapStart: Int
    let gapEnd: Int
}

/// Data for a single note section in the UIKit list
struct NoteSectionData: Equatable {
    let verse: Int  // verseStart or 0 for general section
    let section: NoteSection
    let sectionIndex: Int
    let gapBefore: NoteGapInfo?  // Gap to show before this section

    static func == (lhs: NoteSectionData, rhs: NoteSectionData) -> Bool {
        lhs.verse == rhs.verse &&
        lhs.sectionIndex == rhs.sectionIndex &&
        lhs.section.id == rhs.section.id &&
        lhs.section.content == rhs.section.content &&
        lhs.gapBefore == rhs.gapBefore &&
        lhs.section.footnotes?.count == rhs.section.footnotes?.count &&
        lhs.section.footnotes?.map { $0.id } == rhs.section.footnotes?.map { $0.id } &&
        lhs.section.footnotes?.map { $0.content.plainText } == rhs.section.footnotes?.map { $0.content.plainText }
    }
}

/// Cell view for notes in UIKit list - creates binding from callbacks
struct NoteSectionCell: View {
    let data: NoteSectionData
    let isReadOnly: Bool
    let fontSize: Int
    let translationId: String
    let lastCursorPosition: Int?  // Last known cursor position for this section

    // Callbacks
    let onAddGap: ((Int, Int) -> Void)?  // (gapStart, gapEnd)
    let onContentChange: (Int, String) -> Void  // (sectionIndex, newContent)
    let onCursorPositionChange: ((Int, Int) -> Void)?  // (sectionIndex, cursorPosition)
    let onNavigateToVerse: ((Int) -> Void)?
    let onNavigateToVerseId: ((Int) -> Void)?
    let onEditVerseRange: ((Int) -> Void)?  // (sectionIndex)
    let onShowFootnotePicker: ((Int, Int?) -> Void)?  // (sectionIndex, cursorPosition?)
    let onEditFootnote: ((Int, UserNotesFootnote) -> Void)?  // (sectionIndex, footnote)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Gap button before this section
            if let gap = data.gapBefore, !isReadOnly {
                Button {
                    onAddGap?(gap.gapStart, gap.gapEnd)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        if gap.gapStart == gap.gapEnd {
                            Text("Add note for verse \(gap.gapStart)")
                        } else {
                            Text("Add note for verses \(gap.gapStart)-\(gap.gapEnd)")
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                }
                .padding(.vertical, 4)
            }

            // Section header
            if !data.section.displayTitle.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Text(data.section.displayTitle)
                        .font(.system(size: CGFloat(fontSize)))
                        .foregroundColor(.secondary)

                    if !isReadOnly {
                        Spacer()

                        Button {
                            onShowFootnotePicker?(data.sectionIndex, lastCursorPosition)
                        } label: {
                            Image(systemName: "note.text.badge.plus")
                                .font(.system(size: CGFloat(fontSize)))
                                .foregroundColor(.secondary)
                        }

                        // Only show verse range edit for non-general sections
                        if !data.section.isGeneral {
                            Button {
                                onEditVerseRange?(data.sectionIndex)
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: CGFloat(fontSize)))
                                    .foregroundColor(.secondary)
                                    .offset(y: -2.5)
                            }
                        }
                    }
                }
            }

            // Content
            if isReadOnly {
                let placeholder = data.section.isGeneral ? "No introduction notes" : "No notes"
                if data.section.content.isEmpty {
                    Text(placeholder)
                        .font(.system(size: CGFloat(fontSize)))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .foregroundStyle(.tertiary)
                } else {
                    InteractiveNoteContentView(
                        content: data.section.content,
                        fontSize: fontSize,
                        translationId: translationId,
                        onNavigateToVerse: onNavigateToVerseId
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                // For editing, use a binding created from callback
                NoteTextEditorCell(
                    content: data.section.content,
                    sectionIndex: data.sectionIndex,
                    fontSize: CGFloat(fontSize),
                    onContentChange: onContentChange,
                    onCursorPositionChange: onCursorPositionChange.map { callback in
                        { cursorPosition in callback(data.sectionIndex, cursorPosition) }
                    },
                    onShowFootnotePicker: onShowFootnotePicker.map { callback in
                        { cursorPosition in callback(data.sectionIndex, cursorPosition) }
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 60)
            }

            // Footnotes section
            let footnotes = data.section.footnotes ?? []
            if !footnotes.isEmpty || !isReadOnly {
                VStack(alignment: .leading, spacing: 4) {
                    if !footnotes.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(footnotes) { footnote in
                        HStack(alignment: .top, spacing: 4) {
                            Text("[\(footnote.id)]")
                                .font(.system(size: CGFloat(fontSize) * 0.8))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            InteractiveNoteContentView(
                                content: footnote.content.plainText,
                                fontSize: Int(Double(fontSize) * 0.9),
                                translationId: translationId,
                                onNavigateToVerse: onNavigateToVerse
                            )
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isReadOnly {
                                onEditFootnote?(data.sectionIndex, footnote)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// TextEditor wrapper that uses callbacks instead of binding
struct NoteTextEditorCell: View {
    let content: String
    let sectionIndex: Int
    let fontSize: CGFloat
    let onContentChange: (Int, String) -> Void
    let onCursorPositionChange: ((Int) -> Void)?  // (cursorPosition)
    let onShowFootnotePicker: ((Int) -> Void)?  // (cursorPosition)

    @State private var localContent: String

    init(content: String, sectionIndex: Int, fontSize: CGFloat,
         onContentChange: @escaping (Int, String) -> Void,
         onCursorPositionChange: ((Int) -> Void)?,
         onShowFootnotePicker: ((Int) -> Void)?) {
        self.content = content
        self.sectionIndex = sectionIndex
        self.fontSize = fontSize
        self.onContentChange = onContentChange
        self.onCursorPositionChange = onCursorPositionChange
        self.onShowFootnotePicker = onShowFootnotePicker
        self._localContent = State(initialValue: content)
    }

    var body: some View {
        NoteTextEditor(
            text: Binding(
                get: { localContent },
                set: { newValue in
                    localContent = newValue
                    onContentChange(sectionIndex, newValue)
                }
            ),
            fontSize: fontSize,
            placeholder: "Add your notes...",
            onTextChange: {},
            onCursorPositionChange: onCursorPositionChange,
            onShowFootnotePicker: onShowFootnotePicker
        )
        .onChange(of: content) { _, newContent in
            // Sync external changes (e.g., from footnote insertion)
            if newContent != localContent {
                localContent = newContent
            }
        }
    }
}

enum ToolPanelMode: String, CaseIterable {
    case notes = "Notes"
    case commentary = "Commentary"
    case devotionals = "Devotionals"
}

enum FootnoteInsertMode: String, CaseIterable {
    case createNew = "Create New"
    case useExisting = "Use Existing"
}

struct ToolPanelView: View {
    let book: Int
    let chapter: Int
    let currentVerse: Int
    var startChapter: Int? = nil  // For multi-chapter plan readings (overrides chapter for commentary range)
    var endChapter: Int? = nil    // For multi-chapter plan readings
    var onNavigateToVerse: ((Int) -> Void)?
    @Binding var toolbarsHidden: Bool
    var hideHeader: Bool = false  // Hide header when in horizontal split mode
    @Binding var requestAddNoteForVerse: Int?  // External trigger to add note for a specific verse

    // User settings for translation ID
    @State private var userSettings: UserSettings = UserDatabase.shared.getSettings()

    // Direct coordinator reference for scroll sync
    private let scrollCoordinator = ScrollSyncCoordinator.shared

    @AppStorage("toolPanelMode") private var panelMode: ToolPanelMode = .commentary
    @AppStorage("notesPanelVisible") private var notesPanelVisible: Bool = false
    @AppStorage("toolPanelScrollLinked") private var isScrollLinked: Bool = true
    @AppStorage("bottomToolbarMode") private var bottomToolbarMode: BottomToolbarMode = .navigation
    @AppStorage("notesPanelOrientation") private var notesPanelOrientation: String = "bottom"
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Current scroll position ID for each content type (verse number or index)
    @State private var scrollPosition: Int? = nil
    /// Last verse we reported to prevent duplicate callbacks
    @State private var lastReportedVerse: Int = 0
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

    // Footnote editing state
    @State private var showingFootnoteEditor: Bool = false
    @State private var editingFootnoteId: String? = nil
    @State private var editingFootnoteSectionIndex: Int? = nil
    @State private var footnoteContent: String = ""

    // Footnote insert mode (create new vs use existing)
    @State private var footnoteInsertMode: FootnoteInsertMode = .createNew
    @State private var selectedExistingFootnoteId: String? = nil
    @State private var pendingFootnoteInsertCursor: Int? = nil
    @State private var lastCursorPositions: [Int: Int] = [:]  // sectionIndex -> cursorPosition

    // Edit state
    @AppStorage("notesIsReadOnly") private var isReadOnly: Bool = true
    @State private var isProgrammaticScroll: Bool = false

    // Keyboard state (to disable scroll-linking while editing)
    @State private var isKeyboardVisible: Bool = false
    @State private var keyboardHeight: CGFloat = 0

    // UI state
    @State private var isMaximized: Bool = false
    @State private var showingOptionsMenu: Bool = false
    @AppStorage("toolFontSize") private var toolFontSize: Int = 16

    // Sync status
    @State private var syncStatus: ModuleSyncStatus = .synced
    @State private var syncCheckTask: Task<Void, Never>?

    // UIKit scroll target (verse to scroll to)
    @State private var scrollToVerseTarget: Int? = nil

    // Module storage
    private let moduleDatabase = ModuleDatabase.shared
    @ObservedObject private var moduleSyncManager = ModuleSyncManager.shared
    @AppStorage("selectedNotesModuleId") private var notesModuleId: String = "notes"
    @State private var notesModules: [(id: String, name: String)] = []
    @State private var showingConflictSheet: Bool = false

    // Commentary state
    @State private var commentarySeries: [String] = []
    @AppStorage("selectedCommentarySeries") private var selectedCommentarySeries: String = ""
    @State private var commentaryStrongsKey: String? = nil
    @State private var commentaryPreviewState: PreviewSheetState? = nil
    @State private var commentaryFootnote: CommentaryFootnote? = nil

    // Commentary Data State
    @State private var commentaryUnits: [CommentaryUnit] = []
    @State private var commentaryBook: CommentaryBook? = nil
    @State private var commentarySeriesHasCoverage: Bool = false
    @State private var isCommentaryLoading: Bool = false
    @State private var allCommentaryItems: [PreviewItem] = []  // All tappable items for prev/next navigation

    // Devotionals state
    @State private var showingDevotionalPicker: Bool = true
    @State private var selectedDevotional: Devotional? = nil
    @State private var devotionalViewMode: DevotionalViewMode = .read
    @State private var devotionalsModules: [(id: String, name: String)] = []
    @AppStorage("selectedDevotionalsModuleId") private var devotionalsModuleId: String = "devotionals"

    var bookName: String {
        (try? BundledModuleDatabase.shared.getBook(id: book))?.name ?? "Unknown"
    }

    /// Display name for current panel mode - shows module/series name
    private var currentPanelModeDisplayName: String {
        if panelMode == .commentary {
            return selectedCommentarySeries.isEmpty ? "Commentary" : selectedCommentarySeries
        } else if panelMode == .notes {
            return notesModules.first(where: { $0.id == notesModuleId })?.name ?? "Notes"
        } else if panelMode == .devotionals {
            return devotionalsModules.first(where: { $0.id == devotionalsModuleId })?.name ?? "Devotionals"
        }
        return panelMode.rawValue
    }

    var maxVerseInChapter: Int {
        let translationId = UserDatabase.shared.getSettings().readerTranslationId
        return (try? TranslationDatabase.shared.getVerseCount(translationId: translationId, book: book, chapter: chapter)) ?? 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Content layer
            VStack(spacing: 0) {
                // Spacer for header height (only when showing our own header)
                // In horizontal split (hideHeader), no spacer - content scrolls under the shared toolbar
                if !hideHeader {
                    if toolbarsHidden {
                        Color.clear.frame(height: 24)
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }

                if panelMode == .notes {
                    notesContent
                } else if panelMode == .devotionals {
                    devotionalsContent
                } else {
                    commentaryContent
                }
            }
            // In horizontal split, add content margins so content starts below toolbar but scrolls under it
            .contentMargins(.top, hideHeader ? (toolbarsHidden ? 24 : 56) : 0, for: .scrollContent)

            // Transparent top area for horizontal split mode - content scrolls under with no overlay
            // (The reader's navigation bar provides the visual treatment)

            // Header overlay layer (hidden in horizontal split mode - controls are in main toolbar)
            if !hideHeader {
            VStack(spacing: 0) {
                if toolbarsHidden {
                    Text(currentPanelModeDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.systemBackground))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toolbarsHidden = false
                        }
                } else {
                HStack {
                    Menu {
                    // Notes modules shown by name
                    if !notesModules.isEmpty {
                        ForEach(notesModules, id: \.id) { module in
                            Button {
                                notesModuleId = module.id
                                panelMode = .notes
                            } label: {
                                if panelMode == .notes && notesModuleId == module.id {
                                    Label(module.name, systemImage: "checkmark")
                                } else {
                                    Text(module.name)
                                }
                            }
                        }
                    } else {
                        // Fallback if no modules loaded yet
                        Button {
                            panelMode = .notes
                        } label: {
                            if panelMode == .notes {
                                Label(ToolPanelMode.notes.rawValue, systemImage: "checkmark")
                            } else {
                                Text(ToolPanelMode.notes.rawValue)
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

                    // Devotionals modules shown by name
                    if !devotionalsModules.isEmpty {
                        Divider()
                        ForEach(devotionalsModules, id: \.id) { module in
                            Button {
                                devotionalsModuleId = module.id
                                panelMode = .devotionals
                                showingDevotionalPicker = true
                                selectedDevotional = nil
                            } label: {
                                if panelMode == .devotionals && devotionalsModuleId == module.id {
                                    Label(module.name, systemImage: "checkmark")
                                } else {
                                    Text(module.name)
                                }
                            }
                        }
                    } else {
                        // Fallback if no devotionals modules loaded yet
                        Divider()
                        Button {
                            panelMode = .devotionals
                            showingDevotionalPicker = true
                            selectedDevotional = nil
                        } label: {
                            if panelMode == .devotionals {
                                Label(ToolPanelMode.devotionals.rawValue, systemImage: "checkmark")
                            } else {
                                Text(ToolPanelMode.devotionals.rawValue)
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

                    // Add note button (visible when not read-only)
                    if !isReadOnly {
                        Button {
                            newVerseStart = currentVerse
                            newVerseEnd = nil
                            showingAddVerseSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 22, height: 22)
                                .contentShape(Circle())
                        }
                        .buttonBorderShape(.circle)
                        .modifier(ConditionalGlassButtonStyle())
                    }
                }

                // Options menu
                Button {
                    showingOptionsMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonBorderShape(.circle)
                .modifier(ConditionalGlassButtonStyle())
                .popover(isPresented: $showingOptionsMenu) {
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

                        // Split direction toggle (iPad only)
                        if horizontalSizeClass != .compact {
                            Button {
                                notesPanelOrientation = notesPanelOrientation == "right" ? "bottom" : "right"
                                showingOptionsMenu = false
                            } label: {
                                Label(
                                    notesPanelOrientation == "right" ? "Split Below" : "Split Right",
                                    systemImage: notesPanelOrientation == "right" ? "rectangle.split.1x2" : "rectangle.split.2x1"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(14)
                        }

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
                }
                .padding(.horizontal)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .background(Color(UIColor.systemBackground))
                }

                // Gradient fade below header
                LinearGradient(
                    colors: [Color(UIColor.systemBackground), Color(UIColor.systemBackground).opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 15)
            }
            } // end if !hideHeader
        }
        // In horizontal split mode, extend to top of screen so content scrolls under the shared toolbar
        .ignoresSafeArea(edges: hideHeader ? .top : [])
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
        .sheet(isPresented: Binding(
            get: { !isMaximized && showingFootnoteEditor },
            set: { showingFootnoteEditor = $0 }
        )) {
            footnoteEditorSheet
        }
        .sheet(isPresented: $showingConflictSheet) {
            NoteConflictView()
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
                await loadNote()
            }
            // Scroll to current verse after content loads
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollPosition = currentVerse
            }
        }
        .onChange(of: notesModuleId) { _, _ in
            // Reload notes when module changes
            Task {
                await loadNote()
            }
        }
        .onChange(of: moduleSyncManager.pendingConflicts.count) { oldCount, newCount in
            // Auto-show conflict sheet when new conflicts are detected
            if oldCount == 0 && newCount > 0 && panelMode == .notes {
                showingConflictSheet = true
            }
        }
        .onChange(of: requestAddNoteForVerse) { _, newValue in
            // External trigger to add note for a specific verse
            if let verse = newValue {
                panelMode = .notes
                newVerseStart = verse
                newVerseEnd = nil
                showingAddVerseSheet = true
                requestAddNoteForVerse = nil  // Reset the trigger
            }
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            isKeyboardVisible = true
            if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = keyboardFrame.height
            }
            // Pause scroll sync to prevent keyboard push-up from triggering sync
            scrollCoordinator.isPaused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
            keyboardHeight = 0
            // Resume scroll sync
            scrollCoordinator.isPaused = false
        }
        .onAppear {
            isReadOnly = true // Default to read-only when panel opens
            userSettings = UserDatabase.shared.getSettings()
        }
        .task {
            // Load notes modules, devotionals modules, and commentary series early for picker
            await loadNotesModules()
            await loadDevotionalsModules()
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

    @State private var showingStatusPopover: Bool = false
    @State private var showingMaximizedStatusPopover: Bool = false

    @ViewBuilder
    private var notesStatusIndicator: some View {
        Button {
            showingStatusPopover = true
        } label: {
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
        .modifier(ConditionalGlassButtonStyle())
        .popover(isPresented: $showingStatusPopover) {
            statusPopoverContent
        }
    }

    @ViewBuilder
    private var statusPopoverContent: some View {
        HStack {
            let backendName = SyncCoordinator.shared.settings.backend.displayName
            switch syncStatus {
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .foregroundStyle(.green)
                Text("Synced to \(backendName)")
            case .syncing:
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    .foregroundStyle(.secondary)
                Text("Syncing...")
            case .notSynced:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text("Waiting to sync")
            case .notAvailable:
                Image(systemName: "xmark.icloud")
                    .foregroundStyle(.red)
                Text("Sync unavailable")
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
                .sheet(isPresented: $showingFootnoteEditor) {
                    footnoteEditorSheet
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

            // Build items for UIKit list with gap info
            let items: [(verse: Int, data: NoteSectionData)] = sections.enumerated().compactMap { index, section in
                // Calculate gap before this section
                var gapBefore: NoteGapInfo? = nil
                if !isReadOnly && !section.isGeneral {
                    if let gap = gaps.first(where: { $0.after == nil && section.verseStart == $0.gapEnd + 1 }) {
                        gapBefore = NoteGapInfo(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                    } else if let prevIndex = sections.prefix(index).lastIndex(where: { !$0.isGeneral }),
                              let prevEnd = sections[prevIndex].verseEnd ?? sections[prevIndex].verseStart,
                              let gap = gaps.first(where: { $0.after == prevEnd }) {
                        gapBefore = NoteGapInfo(gapStart: gap.gapStart, gapEnd: gap.gapEnd)
                    }
                }

                let verseNum = section.verseStart ?? 0
                let verse = book * 1000000 + chapter * 1000 + verseNum
                return (verse: verse, data: NoteSectionData(
                    verse: verseNum,
                    section: section,
                    sectionIndex: index,
                    gapBefore: gapBefore
                ))
            }

            VStack(spacing: 0) {
                // Conflict banner (above the list)
                if !moduleSyncManager.pendingConflicts.isEmpty {
                    Button {
                        showingConflictSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("\(moduleSyncManager.pendingConflicts.count) sync conflict\(moduleSyncManager.pendingConflicts.count == 1 ? "" : "s")")
                                .fontWeight(.medium)
                            Spacer()
                            Text("Resolve")
                                .foregroundColor(.blue)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // Main content
                if sections.isEmpty || (isReadOnly && !sections.contains(where: { !$0.isGeneral })) {
                    // Empty state - offset up to account for bottom toolbar
                    VStack(spacing: 12) {
                        Image(systemName: "note.text")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("No verse notes")
                            .font(.system(size: CGFloat(toolFontSize)))
                            .foregroundStyle(.tertiary)
                        if !isReadOnly {
                            Button {
                                showingAddVerseSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("Add verse note")
                                }
                                .foregroundColor(.blue)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: -28)
                } else {
                    // UIKit-based notes list for performance and scroll sync
                    UIKitVerseList(
                        items: items,
                        cellContent: { data in
                            NoteSectionCell(
                                data: data,
                                isReadOnly: isReadOnly,
                                fontSize: toolFontSize,
                                translationId: userSettings.readerTranslationId,
                                lastCursorPosition: lastCursorPositions[data.sectionIndex],
                                onAddGap: { gapStart, gapEnd in
                                    addVerseSectionWithRange(start: gapStart, end: gapEnd > gapStart ? gapEnd : nil)
                                },
                                onContentChange: { sectionIndex, newContent in
                                    if sectionIndex < sections.count {
                                        sections[sectionIndex].content = newContent
                                        scheduleSave()
                                    }
                                },
                                onCursorPositionChange: { sectionIndex, cursorPosition in
                                    lastCursorPositions[sectionIndex] = cursorPosition
                                },
                                onNavigateToVerse: { verse in
                                    if isMaximized { isMaximized = false }
                                    let verseId = book * 1000000 + chapter * 1000 + verse
                                    onNavigateToVerse?(verseId)
                                },
                                onNavigateToVerseId: { verseId in
                                    if isMaximized { isMaximized = false }
                                    onNavigateToVerse?(verseId)
                                },
                                onEditVerseRange: { sectionIndex in
                                    if sectionIndex < sections.count && !sections[sectionIndex].isGeneral {
                                        startEditingSection(sections[sectionIndex], at: sectionIndex)
                                    }
                                },
                                onShowFootnotePicker: { sectionIndex, cursorPosition in
                                    showFootnotePicker(forSectionAt: sectionIndex, cursorPosition: cursorPosition)
                                },
                                onEditFootnote: { sectionIndex, footnote in
                                    editFootnote(footnote, inSectionAt: sectionIndex)
                                }
                            )
                        },
                        listId: "notes_\(book)_\(chapter)_\(toolFontSize)_\(isReadOnly)_\(sections.count)",
                        additionalTopOffset: hideHeader && toolbarsHidden ? 36 : 0
                    )

                    // Trailing gap button (after last verse section)
                    if !isReadOnly {
                        if let lastVerseSection = sections.last(where: { !$0.isGeneral }),
                           let lastEnd = lastVerseSection.verseEnd ?? lastVerseSection.verseStart,
                           let gap = gaps.first(where: { $0.after == lastEnd }) {
                            Button {
                                addVerseSectionWithRange(start: gap.gapStart, end: gap.gapEnd > gap.gapStart ? gap.gapEnd : nil)
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    if gap.gapStart == gap.gapEnd {
                                        Text("Add note for verse \(gap.gapStart)")
                                    } else {
                                        Text("Add note for verses \(gap.gapStart)-\(gap.gapEnd)")
                                    }
                                }
                                .font(.subheadline)
                                .foregroundColor(.blue)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        // General add button (when header is hidden)
                        if hideHeader {
                            Button {
                                newVerseStart = currentVerse
                                newVerseEnd = nil
                                showingAddVerseSheet = true
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("Add verse note")
                                }
                                .font(.subheadline)
                                .foregroundColor(.blue)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
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
            .foregroundColor(.blue)
        }
        .padding(.vertical, 4)
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
                    .id("commentaryScroll_\(book)_\(startChapter ?? chapter)_\(endChapter ?? chapter)")
            }
        }
        .id("commentary_\(book)_\(startChapter ?? chapter)_\(endChapter ?? chapter)_\(selectedCommentarySeries)")
        .task(id: book) { await loadCommentaryContent() }
        .task(id: chapter) { await loadCommentaryContent() }
        .task(id: startChapter) { await loadCommentaryContent() }
        .task(id: endChapter) { await loadCommentaryContent() }
        .task(id: selectedCommentarySeries) { await loadCommentaryContent() }
        .sheet(item: Binding(
            get: { commentaryStrongsKey.map { CommentaryStrongsSheetItem(key: $0) } },
            set: { commentaryStrongsKey = $0?.key }
        )) { item in
            LexiconSheetView(
                word: "",
                strongs: [item.key],
                morphology: nil,
                translationId: userSettings.readerTranslationId,
                onNavigateToVerse: { verseId in
                    commentaryStrongsKey = nil
                    onNavigateToVerse?(verseId)
                }
            )
            .presentationDetents([.fraction(0.325), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
        }
        .sheet(item: $commentaryPreviewState) { _ in
            PreviewSheet(
                state: $commentaryPreviewState,
                translationId: userSettings.readerTranslationId,
                onNavigateToVerse: onNavigateToVerse
            )
        }
        .sheet(item: $commentaryFootnote) { footnote in
            commentaryFootnoteSheetContent(footnote: footnote)
        }
    }

    @ViewBuilder
    private func commentaryScrollView(units: [CommentaryUnit], commentaryBook: CommentaryBook?) -> some View {
        // Build items for UIKit list
        let items: [(verse: Int, data: CommentaryUnitData)] = units.enumerated().map { index, unit in
            (verse: unit.sv, data: CommentaryUnitData(
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
                        // Find matching item in allCommentaryItems for prev/next navigation
                        if let matchingItem = allCommentaryItems.first(where: {
                            if case .verse(let itemSv, let itemEv, _, _) = $0.type {
                                return itemSv == sv && itemEv == ev
                            }
                            return false
                        }) {
                            // Use all verse items for prev/next navigation
                            let verseItems = allCommentaryItems.filter {
                                if case .verse = $0.type { return true }
                                return false
                            }
                            commentaryPreviewState = PreviewSheetState(currentItem: matchingItem, allItems: verseItems.isEmpty ? [matchingItem] : verseItems)
                        } else {
                            // Fallback: create single item
                            let displayText = formatVerseRangeReference(sv, endVerseId: ev)
                            let item = PreviewItem.verse(index: 0, verseId: sv, endVerseId: ev, displayText: displayText)
                            commentaryPreviewState = PreviewSheetState(currentItem: item, allItems: [item])
                        }
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
            listId: "commentary_\(book)_\(startChapter ?? chapter)_\(endChapter ?? chapter)_\(selectedCommentarySeries)_\(toolFontSize)",
            additionalTopOffset: hideHeader && toolbarsHidden ? 36 : 0
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
        let firstChapter = startChapter ?? chapter
        let lastChapter = endChapter ?? chapter
        let userDatabase = moduleDatabase
        let bundledDb = BundledModuleDatabase.shared

        let (coverage, bookInfo, units) = await Task.detached(priority: .userInitiated) {
            // Try bundled database first
            let bundledCoverage = (try? bundledDb.bundledSeriesHasCoverageForBook(seriesFull: series, bookNumber: b)) ?? false
            if bundledCoverage {
                let bookInfo = try? bundledDb.getBundledCommentaryBook(seriesFull: series, bookNumber: b)
                var allUnits: [CommentaryUnit] = []
                for c in firstChapter...lastChapter {
                    let chapterUnits = (try? bundledDb.getBundledCommentaryUnitsForChapter(seriesFull: series, book: b, chapter: c)) ?? []
                    allUnits.append(contentsOf: chapterUnits)
                }
                return (true, bookInfo, allUnits)
            }

            // Fall back to user module database
            let userCoverage = (try? userDatabase.seriesHasCoverageForBook(seriesFull: series, bookNumber: b)) ?? false
            let bookInfo = userCoverage ? (try? userDatabase.getCommentaryBookForSeries(seriesFull: series, bookNumber: b)) : nil
            var allUnits: [CommentaryUnit] = []
            if userCoverage {
                for c in firstChapter...lastChapter {
                    let chapterUnits = (try? userDatabase.getCommentaryUnitsForChapterBySeries(seriesFull: series, book: b, chapter: c)) ?? []
                    allUnits.append(contentsOf: chapterUnits)
                }
            }
            return (userCoverage, bookInfo, allUnits)
        }.value

        // Update state on Main Actor
        commentarySeriesHasCoverage = coverage
        commentaryBook = bookInfo
        commentaryUnits = units

        // Parse all tappable items for prev/next navigation
        allCommentaryItems = parseCommentaryItems(from: units)
    }

    /// Parse all tappable items (verse refs, strongs) from commentary units for prev/next navigation
    private func parseCommentaryItems(from units: [CommentaryUnit]) -> [PreviewItem] {
        var items: [PreviewItem] = []
        var index = 0

        for unit in units {
            // Parse from introduction
            if let intro = unit.introduction {
                for item in parseAnnotatedTextItems(intro, startIndex: &index) {
                    items.append(item)
                }
            }
            // Parse from translation
            if let translation = unit.translation {
                for item in parseAnnotatedTextItems(translation, startIndex: &index) {
                    items.append(item)
                }
            }
            // Parse from commentary
            if let commentary = unit.commentary {
                for item in parseAnnotatedTextItems(commentary, startIndex: &index) {
                    items.append(item)
                }
            }
        }

        return items
    }

    /// Parse tappable items from annotated text
    private func parseAnnotatedTextItems(_ annotatedText: AnnotatedText, startIndex: inout Int) -> [PreviewItem] {
        guard let annotations = annotatedText.annotations else { return [] }

        var items: [PreviewItem] = []
        let text = annotatedText.text

        for annotation in annotations {
            // Get display text from annotation range
            let scalars = text.unicodeScalars
            guard annotation.start >= 0, annotation.end > annotation.start,
                  annotation.start < scalars.count, annotation.end <= scalars.count else { continue }

            let startIdx = scalars.index(scalars.startIndex, offsetBy: annotation.start)
            let endIdx = scalars.index(scalars.startIndex, offsetBy: annotation.end)
            let startStringIdx = startIdx.samePosition(in: text) ?? text.startIndex
            let endStringIdx = endIdx.samePosition(in: text) ?? text.endIndex
            let displayText = String(text[startStringIdx..<endStringIdx])

            switch annotation.type {
            case .scripture:
                if let sv = annotation.data?.sv {
                    let ev = annotation.data?.ev
                    items.append(PreviewItem.verse(index: startIndex, verseId: sv, endVerseId: ev, displayText: displayText))
                    startIndex += 1
                }
            case .strongs:
                if let key = annotation.data?.strongs ?? annotation.id {
                    items.append(PreviewItem.strongs(index: startIndex, key: key, displayText: displayText))
                    startIndex += 1
                }
            default:
                break
            }
        }

        return items
    }

    /// Load notes modules for the picker
    private func loadNotesModules() async {
        do {
            let modules = try moduleDatabase.getAllModules(type: .notes)
            notesModules = modules.map { ($0.id, $0.name) }

            // If no modules exist yet, the default will be created on first use
            // If current selection is not in list, select first available
            if !notesModules.isEmpty && !notesModules.contains(where: { $0.id == notesModuleId }) {
                notesModuleId = notesModules.first?.id ?? "notes"
            }
        } catch {
            print("Failed to load notes modules: \(error)")
        }
    }

    /// Load devotionals modules for the picker
    private func loadDevotionalsModules() async {
        do {
            let modules = try moduleDatabase.getAllModules(type: .devotional)
            devotionalsModules = modules.map { ($0.id, $0.name) }

            // If no modules exist yet, the default will be created on first use
            // If current selection is not in list, select first available
            if !devotionalsModules.isEmpty && !devotionalsModules.contains(where: { $0.id == devotionalsModuleId }) {
                devotionalsModuleId = devotionalsModules.first?.id ?? "devotionals"
            }

            // If still empty, try to create default module
            if devotionalsModules.isEmpty {
                try await ModuleSyncManager.shared.ensureDefaultDevotionalsModule()
                // Reload after creating default
                let updatedModules = try moduleDatabase.getAllModules(type: .devotional)
                devotionalsModules = updatedModules.map { ($0.id, $0.name) }
            }
        } catch {
            print("Failed to load devotionals modules: \(error)")
        }
    }

    /// Load just the commentary series list (for picker availability check)
    /// Combines bundled commentaries and user module commentaries
    private func loadCommentarySeriesOnly() async {
        do {
            // Load bundled commentary series names
            let bundledSeries = try BundledModuleDatabase.shared.getBundledCommentarySeriesNames()

            // Load user module commentary series names
            let userSeries = try moduleDatabase.getCommentarySeriesNames()

            // Combine and deduplicate (bundled first, then user modules)
            var allSeries = bundledSeries
            for series in userSeries {
                if !allSeries.contains(series) {
                    allSeries.append(series)
                }
            }

            commentarySeries = allSeries
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

        let bookName = (try? BundledModuleDatabase.shared.getBook(id: bookId))?.name ?? "?"
        return "\(bookName) \(chapter):\(verse)"
    }

    /// Format verse range reference (e.g., "Matt 1:1-5" or "Matt 1:1" or "Matt 1" for whole chapter)
    private func formatVerseRangeReference(_ verseId: Int, endVerseId: Int?) -> String {
        let bookId = verseId / 1000000
        let chapter = (verseId % 1000000) / 1000
        let verse = verseId % 1000

        let bookName = (try? BundledModuleDatabase.shared.getBook(id: bookId))?.name ?? "?"

        if let ev = endVerseId {
            let endChapter = (ev % 1000000) / 1000
            let endVerse = ev % 1000

            // Handle cross-chapter ranges
            if endChapter != chapter {
                // Cross-chapter: show "Book ch1:v1-ch2:v2" or "Book ch1-ch2" for whole chapters
                if verse == 1 && endVerse >= 900 {
                    return "\(bookName) \(chapter)-\(endChapter)"
                }
                return "\(bookName) \(chapter):\(verse)-\(endChapter):\(endVerse)"
            }

            // Same chapter
            if endVerse >= 900 {
                // Whole chapter sentinel (999) - show "Book chapter" without verse
                if verse == 1 {
                    return "\(bookName) \(chapter)"
                }
                // Partial chapter from verse N to end - just show start
                return "\(bookName) \(chapter):\(verse)+"
            }

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
                            // Find matching item in allCommentaryItems for prev/next navigation
                            if let matchingItem = allCommentaryItems.first(where: {
                                if case .verse(let itemSv, let itemEv, _, _) = $0.type {
                                    return itemSv == sv && itemEv == ev
                                }
                                return false
                            }) {
                                let verseItems = allCommentaryItems.filter {
                                    if case .verse = $0.type { return true }
                                    return false
                                }
                                commentaryPreviewState = PreviewSheetState(currentItem: matchingItem, allItems: verseItems.isEmpty ? [matchingItem] : verseItems)
                            } else {
                                let displayText = formatVerseRangeReference(sv, endVerseId: ev)
                                let item = PreviewItem.verse(index: 0, verseId: sv, endVerseId: ev, displayText: displayText)
                                commentaryPreviewState = PreviewSheetState(currentItem: item, allItems: [item])
                            }
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

        do {
            // Ensure default notes module exists
            try await moduleSyncManager.ensureDefaultNotesModule()

            // Load notes from SQLite for this chapter
            print("[Notes] Loading notes for book=\(book), chapter=\(chapter), moduleId=\(notesModuleId)")
            let entries = try moduleDatabase.getNotesForChapter(moduleId: notesModuleId, book: book, chapter: chapter)
            print("[Notes] Found \(entries.count) entries for this chapter")

            // Convert NoteEntry records to NoteSection for UI
            sections = convertEntriesToSections(entries)

            // If no entries, start with empty general section
            if sections.isEmpty {
                sections = [.general(content: "")]
            }
        } catch {
            print("[Notes] Failed to load notes: \(error)")
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
            // Parse footnotes from JSON if present
            var footnotes: [UserNotesFootnote]? = nil
            if let footnotesJson = entry.footnotesJson,
               let data = footnotesJson.data(using: .utf8) {
                footnotes = try? JSONDecoder().decode([UserNotesFootnote].self, from: data)
            }

            if entry.verse == 0 {
                // General notes (chapter-level / introduction)
                result.insert(.general(content: entry.content, footnotes: footnotes), at: 0)
            } else if let verseRefs = entry.verseRefs, let endVerse = verseRefs.first, endVerse != entry.verse {
                // Verse range - endVerse stored in verseRefs
                result.append(.verseRange(start: entry.verse, end: endVerse, content: entry.content, footnotes: footnotes))
            } else {
                // Single verse
                result.append(.verse(entry.verse, content: entry.content, footnotes: footnotes))
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
                lastModified: Int(Date().timeIntervalSince1970),
                footnotes: section.footnotes
            )
            entries.append(entry)
        }

        return entries
    }

    private func checkSyncStatus() async {
        let fileName = "\(notesModuleId).lamp"
        if let storage = SyncCoordinator.shared.activeStorage {
            syncStatus = await storage.getSyncStatus(type: .notes, fileName: fileName)
        } else {
            syncStatus = .notAvailable
        }
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

            // Export to cloud storage
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

    // MARK: - Devotionals Content

    @ViewBuilder
    private var devotionalsContent: some View {
        if showingDevotionalPicker {
            DevotionalPickerView(
                isFullScreen: false,
                showNewProminent: false,
                initialModuleId: devotionalsModuleId,
                onSelect: { devotional in
                    selectedDevotional = devotional
                    showingDevotionalPicker = false
                    devotionalViewMode = .read
                },
                onBack: {
                    // Switch back to commentary mode when backing out of picker
                    panelMode = .commentary
                }
            )
        } else if let devotional = selectedDevotional {
            DevotionalView(
                devotional: devotional,
                moduleId: devotionalsModuleId,
                onBack: {
                    showingDevotionalPicker = true
                    selectedDevotional = nil
                },
                onNavigateToVerse: onNavigateToVerse
            )
        } else {
            // Fallback: show picker
            DevotionalPickerView(
                isFullScreen: false,
                showNewProminent: false,
                initialModuleId: devotionalsModuleId,
                onSelect: { devotional in
                    selectedDevotional = devotional
                    showingDevotionalPicker = false
                    devotionalViewMode = .read
                },
                onBack: {
                    panelMode = .commentary
                }
            )
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

    // MARK: - Footnote Editing

    private var footnoteEditorSheet: some View {
        // Check if we're editing an existing footnote (vs inserting new)
        let isEditingExisting: Bool = {
            guard let sectionIndex = editingFootnoteSectionIndex,
                  let footnoteId = editingFootnoteId,
                  sectionIndex < sections.count,
                  let footnotes = sections[sectionIndex].footnotes,
                  let footnote = footnotes.first(where: { $0.id == footnoteId }) else {
                return false
            }
            // It's existing if it has non-empty content (not just created)
            return !footnote.content.plainText.isEmpty
        }()

        // Get existing footnotes for the picker
        let existingFootnotes: [UserNotesFootnote] = {
            guard let sectionIndex = editingFootnoteSectionIndex,
                  sectionIndex < sections.count else { return [] }
            return sections[sectionIndex].footnotes ?? []
        }()

        return NavigationStack {
            Form {
                // Show mode picker only when inserting (not editing existing)
                if !isEditingExisting && !existingFootnotes.isEmpty {
                    Picker("", selection: $footnoteInsertMode) {
                        ForEach(FootnoteInsertMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if footnoteInsertMode == .useExisting && !isEditingExisting && !existingFootnotes.isEmpty {
                    // Use existing footnote picker
                    Section {
                        Picker("Select Footnote", selection: $selectedExistingFootnoteId) {
                            Text("Select...").tag(nil as String?)
                            ForEach(existingFootnotes, id: \.id) { footnote in
                                let preview = footnote.content.plainText.prefix(40)
                                let truncated = footnote.content.plainText.count > 40
                                Text("[\(footnote.id)] \(preview)\(truncated ? "..." : "")")
                                    .tag(footnote.id as String?)
                            }
                        }
                        .pickerStyle(.menu)
                    } footer: {
                        Text("Insert a reference to an existing footnote.")
                    }
                } else {
                    // Create new footnote editor
                    Section {
                        TextEditor(text: $footnoteContent)
                            .frame(minHeight: 100)
                    } header: {
                        if isEditingExisting, let id = editingFootnoteId {
                            Text("Footnote [\(id)]")
                        } else {
                            Text("New Footnote")
                        }
                    } footer: {
                        Text("Enter the footnote content.")
                    }

                    // Delete button for existing footnotes
                    if isEditingExisting, let sectionIndex = editingFootnoteSectionIndex, let footnoteId = editingFootnoteId {
                        Section {
                            Button(role: .destructive) {
                                deleteFootnote(id: footnoteId, fromSectionAt: sectionIndex)
                                showingFootnoteEditor = false
                                resetFootnoteForm()
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("Delete Footnote")
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditingExisting ? "Edit Footnote" : "Insert Footnote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelFootnoteEditor()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(footnoteInsertMode == .useExisting && !isEditingExisting ? "Insert" : "Save") {
                        if footnoteInsertMode == .useExisting && !isEditingExisting {
                            insertSelectedExistingFootnote()
                        } else {
                            saveFootnote()
                        }
                    }
                    .disabled(footnoteInsertMode == .useExisting && !isEditingExisting
                              ? selectedExistingFootnoteId == nil
                              : footnoteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func insertSelectedExistingFootnote() {
        guard let sectionIndex = editingFootnoteSectionIndex,
              let footnoteId = selectedExistingFootnoteId,
              sectionIndex < sections.count else {
            showingFootnoteEditor = false
            resetFootnoteForm()
            return
        }

        let marker = "[^\(footnoteId)]"

        // Insert marker at cursor position or end of content
        if let cursor = pendingFootnoteInsertCursor {
            var content = sections[sectionIndex].content
            let insertIndex = content.index(content.startIndex, offsetBy: min(cursor, content.count))
            content.insert(contentsOf: marker, at: insertIndex)
            sections[sectionIndex].content = content
        } else {
            // Append to end
            if !sections[sectionIndex].content.isEmpty && !sections[sectionIndex].content.hasSuffix(" ") {
                sections[sectionIndex].content += " "
            }
            sections[sectionIndex].content += marker
        }

        scheduleSave()
        showingFootnoteEditor = false
        resetFootnoteForm()
    }

    private func cancelFootnoteEditor() {
        // If we created an empty footnote (from long-press), delete it and its marker
        if let sectionIndex = editingFootnoteSectionIndex,
           let footnoteId = editingFootnoteId,
           sectionIndex < sections.count {
            // Check if this footnote is empty (just created)
            if let footnotes = sections[sectionIndex].footnotes,
               let footnote = footnotes.first(where: { $0.id == footnoteId }),
               footnote.content.plainText.isEmpty {
                // Delete the empty footnote
                deleteFootnote(id: footnoteId, fromSectionAt: sectionIndex)
            }
        }

        showingFootnoteEditor = false
        resetFootnoteForm()
    }

    /// Show footnote editor to insert existing or create new footnote
    private func showFootnotePicker(forSectionAt index: Int, cursorPosition: Int? = nil) {
        guard index < sections.count else { return }
        editingFootnoteSectionIndex = index
        editingFootnoteId = nil
        footnoteContent = ""
        footnoteInsertMode = .createNew
        selectedExistingFootnoteId = nil
        pendingFootnoteInsertCursor = cursorPosition
        showingFootnoteEditor = true
    }

    private func editFootnote(_ footnote: UserNotesFootnote, inSectionAt index: Int) {
        editingFootnoteSectionIndex = index
        editingFootnoteId = footnote.id
        footnoteContent = footnote.content.plainText
        showingFootnoteEditor = true
    }

    private func deleteFootnote(id: String, fromSectionAt index: Int) {
        guard index < sections.count else { return }

        var footnotes = sections[index].footnotes ?? []
        footnotes.removeAll { $0.id == id }

        // Re-number remaining footnotes
        var renumbered: [UserNotesFootnote] = []
        for (i, footnote) in footnotes.enumerated() {
            let newId = String(i + 1)
            renumbered.append(UserNotesFootnote(id: newId, content: footnote.content))
        }

        sections[index].footnotes = renumbered.isEmpty ? nil : renumbered

        // Update footnote markers in content (remove deleted, renumber remaining)
        updateFootnoteMarkersInContent(sectionIndex: index, deletedId: id)

        scheduleSave()
    }

    private func saveFootnote() {
        guard let sectionIndex = editingFootnoteSectionIndex,
              sectionIndex < sections.count else {
            showingFootnoteEditor = false
            resetFootnoteForm()
            return
        }

        let trimmedContent = footnoteContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }

        var footnotes = sections[sectionIndex].footnotes ?? []

        if let existingId = editingFootnoteId {
            // Update existing footnote
            if let idx = footnotes.firstIndex(where: { $0.id == existingId }) {
                footnotes[idx] = UserNotesFootnote(id: existingId, content: .text(trimmedContent))
            }
        } else {
            // Add new footnote
            let newId = String(footnotes.count + 1)
            let newFootnote = UserNotesFootnote(id: newId, content: .text(trimmedContent))
            footnotes.append(newFootnote)

            // Insert footnote marker at cursor position or end of content
            let marker = "[^\(newId)]"
            if let cursor = pendingFootnoteInsertCursor {
                var content = sections[sectionIndex].content
                let insertIndex = content.index(content.startIndex, offsetBy: min(cursor, content.count))
                content.insert(contentsOf: marker, at: insertIndex)
                sections[sectionIndex].content = content
            } else {
                if !sections[sectionIndex].content.isEmpty && !sections[sectionIndex].content.hasSuffix(" ") {
                    sections[sectionIndex].content += " "
                }
                sections[sectionIndex].content += marker
            }
        }

        sections[sectionIndex].footnotes = footnotes

        showingFootnoteEditor = false
        resetFootnoteForm()
        scheduleSave()
    }

    private func resetFootnoteForm() {
        editingFootnoteSectionIndex = nil
        editingFootnoteId = nil
        footnoteContent = ""
        footnoteInsertMode = .createNew
        selectedExistingFootnoteId = nil
        pendingFootnoteInsertCursor = nil
    }

    private func updateFootnoteMarkersInContent(sectionIndex: Int, deletedId: String) {
        guard sectionIndex < sections.count else { return }

        var content = sections[sectionIndex].content

        // Remove the deleted footnote's marker
        content = content.replacingOccurrences(of: "[^\(deletedId)]", with: "")

        // Renumber remaining markers to match new footnote IDs
        // Old IDs that were higher than deleted get decremented
        if let deletedNum = Int(deletedId) {
            // Find all markers with numbers higher than deleted and decrement them
            let pattern = #"\[\^(\d+)\]"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsContent = content as NSString
                let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

                // Process matches in reverse order to avoid range shifting issues
                for match in matches.reversed() {
                    if let numRange = Range(match.range(at: 1), in: content) {
                        if let num = Int(content[numRange]), num > deletedNum {
                            let newNum = num - 1
                            let fullRange = Range(match.range, in: content)!
                            content.replaceSubrange(fullRange, with: "[^\(newNum)]")
                        }
                    }
                }
            }
        }

        // Clean up double spaces
        while content.contains("  ") {
            content = content.replacingOccurrences(of: "  ", with: " ")
        }

        sections[sectionIndex].content = content.trimmingCharacters(in: .whitespaces)
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
    let translationId: String
    let onContentChange: () -> Void
    var onNavigateToVerse: ((Int) -> Void)?
    var onNavigateToVerseId: ((Int) -> Void)?
    var onEditVerseRange: (() -> Void)?
    var onShowFootnotePicker: (() -> Void)?  // Shows picker to insert existing or create new
    var onEditFootnote: ((UserNotesFootnote) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            if !section.displayTitle.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Text(section.displayTitle)
                        .font(.system(size: CGFloat(fontSize)))
                        .foregroundColor(.secondary)

                    if !section.isGeneral && !isReadOnly {
                        Spacer()

                        if let onFootnote = onShowFootnotePicker {
                            Button {
                                onFootnote()
                            } label: {
                                Image(systemName: "note.text.badge.plus")
                                    .font(.system(size: CGFloat(fontSize)))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let onEdit = onEditVerseRange {
                            Button {
                                onEdit()
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: CGFloat(fontSize)))
                                    .foregroundColor(.secondary)
                                    .padding(.bottom, 2)
                            }
                        }
                    }
                }
            }

            // Text editor or read-only text
            if isReadOnly {
                let placeholder = section.isGeneral ? "No introduction notes" : "No notes"
                if section.content.isEmpty {
                    Text(placeholder)
                        .font(.system(size: CGFloat(fontSize)))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .foregroundStyle(.tertiary)
                } else {
                    InteractiveNoteContentView(
                        content: section.content,
                        fontSize: fontSize,
                        translationId: translationId,
                        onNavigateToVerse: onNavigateToVerseId
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                NoteTextEditor(
                    text: $section.content,
                    fontSize: CGFloat(fontSize),
                    placeholder: "Add your notes...",
                    onTextChange: onContentChange,
                    onShowFootnotePicker: nil  // Not used here - header button triggers picker
                )
                .frame(maxWidth: .infinity, minHeight: 60)
            }

            // Footnotes section
            let footnotes = section.footnotes ?? []
            if !footnotes.isEmpty || !isReadOnly {
                VStack(alignment: .leading, spacing: 4) {
                    if !footnotes.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                    }

                    ForEach(footnotes) { footnote in
                        HStack(alignment: .top, spacing: 4) {
                            Text("[\(footnote.id)]")
                                .font(.system(size: CGFloat(fontSize) * 0.8))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            InteractiveNoteContentView(
                                content: footnote.content.plainText,
                                fontSize: Int(Double(fontSize) * 0.9),
                                translationId: translationId,
                                onNavigateToVerse: onNavigateToVerse
                            )
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isReadOnly {
                                onEditFootnote?(footnote)
                            }
                        }
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
        let books = (try? BundledModuleDatabase.shared.getAllBooks()) ?? []
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
        // OT
        bookAbbrevToId["1sam"] = bookNameToId["1 samuel"]
        bookAbbrevToId["2sam"] = bookNameToId["2 samuel"]
        bookAbbrevToId["1ki"] = bookNameToId["1 kings"]
        bookAbbrevToId["2ki"] = bookNameToId["2 kings"]
        bookAbbrevToId["1kgs"] = bookNameToId["1 kings"]
        bookAbbrevToId["2kgs"] = bookNameToId["2 kings"]
        bookAbbrevToId["1chr"] = bookNameToId["1 chronicles"]
        bookAbbrevToId["2chr"] = bookNameToId["2 chronicles"]
        bookAbbrevToId["prov"] = bookNameToId["proverbs"]
        bookAbbrevToId["eccl"] = bookNameToId["ecclesiastes"]
        bookAbbrevToId["ecc"] = bookNameToId["ecclesiastes"]
        bookAbbrevToId["song"] = bookNameToId["song of solomon"]
        bookAbbrevToId["sos"] = bookNameToId["song of solomon"]
        bookAbbrevToId["lam"] = bookNameToId["lamentations"]
        bookAbbrevToId["ezek"] = bookNameToId["ezekiel"]
        bookAbbrevToId["eze"] = bookNameToId["ezekiel"]
        bookAbbrevToId["dan"] = bookNameToId["daniel"]
        bookAbbrevToId["hos"] = bookNameToId["hosea"]
        bookAbbrevToId["mic"] = bookNameToId["micah"]
        bookAbbrevToId["nah"] = bookNameToId["nahum"]
        bookAbbrevToId["hab"] = bookNameToId["habakkuk"]
        bookAbbrevToId["zeph"] = bookNameToId["zephaniah"]
        bookAbbrevToId["hag"] = bookNameToId["haggai"]
        bookAbbrevToId["zech"] = bookNameToId["zechariah"]
        bookAbbrevToId["mal"] = bookNameToId["malachi"]
        // NT
        bookAbbrevToId["mk"] = bookNameToId["mark"]
        bookAbbrevToId["lk"] = bookNameToId["luke"]
        bookAbbrevToId["jn"] = bookNameToId["john"]
        bookAbbrevToId["rom"] = bookNameToId["romans"]
        bookAbbrevToId["1cor"] = bookNameToId["1 corinthians"]
        bookAbbrevToId["2cor"] = bookNameToId["2 corinthians"]
        bookAbbrevToId["gal"] = bookNameToId["galatians"]
        bookAbbrevToId["eph"] = bookNameToId["ephesians"]
        bookAbbrevToId["phil"] = bookNameToId["philippians"]
        bookAbbrevToId["col"] = bookNameToId["colossians"]
        bookAbbrevToId["1thess"] = bookNameToId["1 thessalonians"]
        bookAbbrevToId["2thess"] = bookNameToId["2 thessalonians"]
        bookAbbrevToId["1tim"] = bookNameToId["1 timothy"]
        bookAbbrevToId["2tim"] = bookNameToId["2 timothy"]
        bookAbbrevToId["tit"] = bookNameToId["titus"]
        bookAbbrevToId["phm"] = bookNameToId["philemon"]
        bookAbbrevToId["heb"] = bookNameToId["hebrews"]
        bookAbbrevToId["jas"] = bookNameToId["james"]
        bookAbbrevToId["1pet"] = bookNameToId["1 peter"]
        bookAbbrevToId["2pet"] = bookNameToId["2 peter"]
        bookAbbrevToId["1jn"] = bookNameToId["1 john"]
        bookAbbrevToId["2jn"] = bookNameToId["2 john"]
        bookAbbrevToId["3jn"] = bookNameToId["3 john"]
        bookAbbrevToId["rev"] = bookNameToId["revelation"]
    }

    /// Parse all verse references from text
    /// Supports both bracketed [John 3:16] and unbracketed "John 3:16" formats
    func parse(_ text: String) -> [ParsedVerseReference] {
        var references: [ParsedVerseReference] = []

        // First, try bracketed format [Book Chapter:Verse]
        references.append(contentsOf: parseBracketed(text))

        // Then, try unbracketed format "Book Chapter:Verse"
        references.append(contentsOf: parseUnbracketed(text))

        // Remove duplicates (same range) and sort by position
        var seen = Set<String>()
        return references
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .filter { ref in
                let key = "\(ref.range.lowerBound)-\(ref.range.upperBound)"
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
    }

    /// Parse bracketed references like [John 3:16]
    private func parseBracketed(_ text: String) -> [ParsedVerseReference] {
        var references: [ParsedVerseReference] = []

        // Pattern: [Book Chapter:Verse] or [Book Chapter:Verse-EndVerse]
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

            // Validate that the verse exists (using any translation)
            let verseId = bookId * 1000000 + chapter * 1000 + startVerse
            let translationId = UserDatabase.shared.getSettings().readerTranslationId
            let exists = (try? TranslationDatabase.shared.verseExists(translationId: translationId, ref: verseId)) ?? false

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

    /// Parse unbracketed references like "John 3:16" or "1 Cor 13:4-7"
    private func parseUnbracketed(_ text: String) -> [ParsedVerseReference] {
        var references: [ParsedVerseReference] = []

        // Build pattern from known book names and abbreviations
        // Match: BookName Chapter:Verse or BookName Chapter:Verse-EndVerse
        // Book names can be: Genesis, Gen, 1 John, 1John, 1 Jn, etc.

        // Pattern explanation:
        // - Optional number prefix (1, 2, 3) with optional space
        // - Book name (letters only, at least 2 chars)
        // - Optional period after abbreviation
        // - Required space
        // - Chapter number
        // - Colon
        // - Verse number
        // - Optional dash and end verse
        let pattern = #"(?<!\[)(?<!\w)([1-3]?\s?[A-Za-z]{2,})\.?\s+(\d{1,3}):(\d{1,3})(?:-(\d{1,3}))?(?!\])(?!\w)"#

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

            // Validate that the verse exists (helps filter false positives)
            let verseId = bookId * 1000000 + chapter * 1000 + startVerse
            let translationId = UserDatabase.shared.getSettings().readerTranslationId
            let exists = (try? TranslationDatabase.shared.verseExists(translationId: translationId, ref: verseId)) ?? false

            if exists {
                let displayText = String(text[fullRange])
                references.append(ParsedVerseReference(
                    range: fullRange,
                    displayText: displayText,
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

// MARK: - Note Content Renderer (UIKit-based for performance)

/// Custom attribute key for note tap actions (avoids iOS URL resolution delay)
private let NoteTappableIndexKey = NSAttributedString.Key("noteTappableIndex")

/// Renders note content to NSAttributedString with tappable verse references and styled footnotes
private struct NoteContentRenderer {

    struct RenderResult {
        let attributedString: NSAttributedString
        let previewItems: [PreviewItem]
    }

    /// Render note content with verse references and footnote styling
    static func render(
        _ content: String,
        fontSize: CGFloat,
        references: [ParsedVerseReference]
    ) -> RenderResult {
        let result = NSMutableAttributedString()
        var previewItems: [PreviewItem] = []

        let refs = references.sorted(by: { $0.range.lowerBound < $1.range.lowerBound })
        var currentIndex = content.startIndex

        // Base attributes
        let baseFont = UIFont.systemFont(ofSize: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = fontSize * 0.35

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ]

        for (index, ref) in refs.enumerated() {
            // Add text before this reference (with footnote styling)
            if currentIndex < ref.range.lowerBound {
                let textBefore = String(content[currentIndex..<ref.range.lowerBound])
                let styledText = renderFootnoteText(textBefore, fontSize: fontSize, baseAttributes: baseAttributes)
                result.append(styledText)
            }

            // Add the verse reference as a tappable item
            let verseAttr = NSMutableAttributedString(string: ref.displayText)
            let verseRange = NSRange(location: 0, length: verseAttr.length)
            verseAttr.addAttributes(baseAttributes, range: verseRange)
            verseAttr.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: verseRange)
            verseAttr.addAttribute(NoteTappableIndexKey, value: index, range: verseRange)
            result.append(verseAttr)

            // Track for prev/next navigation
            previewItems.append(PreviewItem.verse(
                index: index,
                verseId: ref.verseId,
                endVerseId: ref.endVerseId,
                displayText: ref.displayText
            ))

            currentIndex = ref.range.upperBound
        }

        // Add remaining text after last reference
        if currentIndex < content.endIndex {
            let textAfter = String(content[currentIndex..<content.endIndex])
            let styledText = renderFootnoteText(textAfter, fontSize: fontSize, baseAttributes: baseAttributes)
            result.append(styledText)
        }

        return RenderResult(attributedString: result, previewItems: previewItems)
    }

    /// Render text with footnote markers [^n] styled as superscript [n]
    private static func renderFootnoteText(
        _ text: String,
        fontSize: CGFloat,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)

        let pattern = "\\[\\^(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return result
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        // Process in reverse to maintain range validity
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }

            let fullRange = match.range
            let numberRange = match.range(at: 1)
            let number = nsText.substring(with: numberRange)

            // Create styled footnote reference
            let styledRef = NSMutableAttributedString(string: "[\(number)]")
            let refRange = NSRange(location: 0, length: styledRef.length)
            styledRef.addAttribute(.font, value: UIFont.systemFont(ofSize: fontSize * 0.7), range: refRange)
            styledRef.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: refRange)
            styledRef.addAttribute(.baselineOffset, value: fontSize * 0.35, range: refRange)

            result.replaceCharacters(in: fullRange, with: styledRef)
        }

        return result
    }
}

/// Custom UITextView that uses tap gestures for note content
private class TappableNoteTextView: UITextView {
    var onTappableIndexTap: ((Int) -> Void)?

    // Use TextKit 1 for reliable character index calculation
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
        tapGesture.cancelsTouchesInView = false
        addGestureRecognizer(tapGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        let textContainerOffset = CGPoint(x: textContainerInset.left, y: textContainerInset.top)
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
        if let tappableIndex = attributes[NoteTappableIndexKey] as? Int {
            onTappableIndexTap?(tappableIndex)
        }
    }

    override var attributedText: NSAttributedString! {
        didSet {
            textKit1TextStorage.setAttributedString(attributedText ?? NSAttributedString())
        }
    }
}

/// UIViewRepresentable for note content with caching
private struct NoteContentTextViewRepresentable: UIViewRepresentable {
    let content: String
    let fontSize: CGFloat
    let references: [ParsedVerseReference]
    let onTap: (Int) -> Void

    func makeUIView(context: Context) -> TappableNoteTextView {
        let textView = TappableNoteTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isUserInteractionEnabled = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.linkTextAttributes = [:]
        textView.dataDetectorTypes = []
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.layer.drawsAsynchronously = true
        return textView
    }

    func updateUIView(_ textView: TappableNoteTextView, context: Context) {
        textView.onTappableIndexTap = onTap

        // Only re-render if content or fontSize changed
        let cacheKey = "\(content.hashValue)_\(fontSize)"
        if context.coordinator.lastCacheKey != cacheKey {
            context.coordinator.lastCacheKey = cacheKey
            context.coordinator.cachedSize = nil

            let renderResult = NoteContentRenderer.render(content, fontSize: fontSize, references: references)
            textView.attributedText = renderResult.attributedString
            context.coordinator.cachedPreviewItems = renderResult.previewItems
            textView.invalidateIntrinsicContentSize()
        }
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TappableNoteTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width

        if let cached = context.coordinator.cachedSize, abs(cached.width - width) < 1 {
            return cached
        }

        let containerWidth = width - uiView.textContainerInset.left - uiView.textContainerInset.right
        if uiView.textContainer.size.width != containerWidth {
            uiView.textContainer.size = CGSize(width: containerWidth, height: .greatestFiniteMagnitude)
        }

        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let result = CGSize(width: width, height: size.height)
        context.coordinator.cachedSize = result
        return result
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastCacheKey: String = ""
        var cachedSize: CGSize?
        var cachedPreviewItems: [PreviewItem] = []
    }
}

// MARK: - Interactive Note Content View

struct InteractiveNoteContentView: View {
    let content: String
    let fontSize: Int
    let translationId: String
    var onNavigateToVerse: ((Int) -> Void)?

    @State private var previewState: PreviewSheetState? = nil
    @State private var parsedData: (content: String, refs: [ParsedVerseReference], items: [PreviewItem])?

    // Get or compute cached references
    private var references: [ParsedVerseReference] {
        if let data = parsedData, data.content == content {
            return data.refs
        }
        return VerseReferenceParser.shared.parse(content)
    }

    // Get or compute cached preview items
    private var previewItems: [PreviewItem] {
        if let data = parsedData, data.content == content {
            return data.items
        }
        return references.enumerated().map { index, ref in
            PreviewItem.verse(
                index: index,
                verseId: ref.verseId,
                endVerseId: ref.endVerseId,
                displayText: ref.displayText
            )
        }
    }

    var body: some View {
        let refs = references  // Compute once per body evaluation
        NoteContentTextViewRepresentable(
            content: content,
            fontSize: CGFloat(fontSize),
            references: refs,
            onTap: { index in
                let items = previewItems
                if index < items.count {
                    previewState = PreviewSheetState(
                        currentItem: items[index],
                        allItems: items
                    )
                }
            }
        )
        .onAppear {
            updateCacheIfNeeded()
        }
        .onChange(of: content) { _, _ in
            updateCacheIfNeeded()
        }
        .sheet(item: $previewState) { _ in
            PreviewSheet(
                state: $previewState,
                translationId: translationId,
                onNavigateToVerse: onNavigateToVerse
            )
        }
    }

    private func updateCacheIfNeeded() {
        if parsedData?.content != content {
            let refs = VerseReferenceParser.shared.parse(content)
            let items = refs.enumerated().map { index, ref in
                PreviewItem.verse(
                    index: index,
                    verseId: ref.verseId,
                    endVerseId: ref.endVerseId,
                    displayText: ref.displayText
                )
            }
            parsedData = (content, refs, items)
        }
    }

    /// Count the number of verse references in this content
    var referenceCount: Int {
        references.count
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

// MARK: - Commentary Sheet Items

/// Sheet item for Strong's number from commentary
struct CommentaryStrongsSheetItem: Identifiable {
    let key: String
    var id: String { key }
}

/// Shared verse content view for displaying verse text in sheets/popovers
/// Used by TSKe, Cross References, Lexicon, and Search views
struct VerseSheetContent: View {
    let title: String
    let verseId: Int
    let endVerseId: Int?
    let translationId: String?  // GRDB translation ID
    var onNavigate: (() -> Void)? = nil

    // Optional context support (for search results)
    var contextAmount: SearchContextAmount? = nil

    // Optional highlighting support (for search results)
    var highlightQuery: String? = nil
    var highlightMode: SearchMode? = nil

    init(title: String, verseId: Int, endVerseId: Int? = nil, translationId: String?, onNavigate: (() -> Void)? = nil) {
        self.title = title
        self.verseId = verseId
        self.endVerseId = endVerseId
        self.translationId = translationId
        self.onNavigate = onNavigate
    }

    init(title: String, verseId: Int, endVerseId: Int? = nil, translationId: String?, onNavigate: (() -> Void)? = nil, contextAmount: SearchContextAmount?, highlightQuery: String?, highlightMode: SearchMode?) {
        self.title = title
        self.verseId = verseId
        self.endVerseId = endVerseId
        self.translationId = translationId
        self.onNavigate = onNavigate
        self.contextAmount = contextAmount
        self.highlightQuery = highlightQuery
        self.highlightMode = highlightMode
    }

    /// Returns the primary (hit) verses without context
    private var primaryVerses: [TranslationVerse] {
        guard let translationId = translationId else { return [] }
        let startId = verseId
        let endId = endVerseId ?? verseId
        return (try? TranslationDatabase.shared.getVerseRange(translationId: translationId, startRef: startId, endRef: endId)) ?? []
    }

    /// Returns verses with context if contextAmount is set
    private var versesWithContext: [(verse: TranslationVerse, isContext: Bool)] {
        guard let translationId = translationId else { return [] }

        // If no context requested, just return primary verses
        guard let contextAmount = contextAmount else {
            return primaryVerses.map { ($0, false) }
        }

        let (_, startChapter, book) = splitVerseId(verseId)
        let endId = endVerseId ?? verseId
        let (_, endChapter, _) = splitVerseId(endId)

        // Helper to check if a verse ref is within the primary range
        let isPrimary: (Int) -> Bool = { ref in ref >= verseId && ref <= endId }

        // For cross-chapter ranges or whole-chapter context, just return primary verses without context
        // (adding context to multi-chapter ranges gets complicated)
        if endChapter != startChapter || contextAmount == .chapter {
            return primaryVerses.map { ($0, false) }
        }

        // Single chapter with verse-level context
        let chapterContent = (try? TranslationDatabase.shared.getChapter(translationId: translationId, book: book, chapter: startChapter)) ?? ChapterContent(verses: [], headings: [])
        let chapterVerses = chapterContent.verses

        guard let startIdx = chapterVerses.firstIndex(where: { $0.ref == verseId }) else {
            return primaryVerses.map { ($0, false) }
        }

        // Find the end index of the primary range
        let endIdx = chapterVerses.lastIndex(where: { isPrimary($0.ref) }) ?? startIdx

        let contextCount: Int
        switch contextAmount {
        case .oneVerse:
            contextCount = 1
        case .threeVerses:
            contextCount = 3
        case .chapter:
            return chapterVerses.map { ($0, !isPrimary($0.ref)) }
        }

        // Context window spans from before the start to after the end of the range
        let windowStart = max(0, startIdx - contextCount)
        let windowEnd = min(chapterVerses.count - 1, endIdx + contextCount)
        return Array(chapterVerses[windowStart...windowEnd]).map { ($0, !isPrimary($0.ref)) }
    }

    private var versesText: AttributedString {
        let allVerses = versesWithContext
        if allVerses.isEmpty {
            var notFound = AttributedString("Verse not found")
            notFound.foregroundColor = .secondary
            return notFound
        }

        var result = AttributedString()
        var currentChapter: Int? = nil

        for (index, item) in allVerses.enumerated() {
            let verse = item.verse
            let isContext = item.isContext

            // Add chapter heading when chapter changes (for multi-chapter ranges)
            if verse.chapter != currentChapter {
                if currentChapter != nil {
                    // Add line break before new chapter (not before first)
                    result.append(AttributedString("\n\n"))
                }
                currentChapter = verse.chapter

                // Only show chapter heading if there are multiple chapters
                let hasMultipleChapters = allVerses.contains { $0.verse.chapter != allVerses.first?.verse.chapter }
                if hasMultipleChapters {
                    var chapterHeading = AttributedString("Chapter \(verse.chapter)\n\n")
                    chapterHeading.font = .headline
                    chapterHeading.foregroundColor = .secondary
                    result.append(chapterHeading)
                }
            }

            // Add verse number as superscript
            var verseNum = AttributedString("\(verse.verse)")
            verseNum.font = .caption
            verseNum.foregroundColor = .secondary
            verseNum.baselineOffset = 4

            // Add verse text (with optional highlighting)
            let verseTextContent: AttributedString
            if !isContext, let query = highlightQuery, !query.isEmpty {
                if highlightMode == .strongs {
                    verseTextContent = highlightedStrongsAttributedText(verse.text, annotationsJson: verse.annotationsJson, strongsNum: query.uppercased())
                } else {
                    verseTextContent = highlightedTextAttributedString(verse.text, query: query)
                }
            } else {
                var text = AttributedString(" " + verse.text)
                text.font = .body
                verseTextContent = text
            }

            // Apply muted style to context verses
            if isContext {
                var mutedNum = verseNum
                mutedNum.foregroundColor = .secondary.opacity(0.7)
                result.append(mutedNum)

                var mutedText = verseTextContent
                mutedText.foregroundColor = .secondary.opacity(0.8)
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
                highlight.foregroundColor = .blue
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

    private func highlightedStrongsAttributedText(_ text: String, annotationsJson: String?, strongsNum: String) -> AttributedString {
        var result = AttributedString(" ")

        // Parse annotations to find matching Strong's number ranges
        var highlightRanges: [(start: Int, end: Int)] = []
        if let json = annotationsJson,
           let data = json.data(using: .utf8),
           let annotations = try? JSONDecoder().decode([VerseAnnotation].self, from: data) {
            for annotation in annotations {
                if let strongs = annotation.data?.strongs, strongsNumbersMatch(strongs, strongsNum) {
                    highlightRanges.append((annotation.start, annotation.end))
                }
            }
        }

        // If no highlights found, return plain text
        guard !highlightRanges.isEmpty else {
            var plain = AttributedString(text)
            plain.font = .body
            result.append(plain)
            return result
        }

        // Sort ranges by start position
        let sortedRanges = highlightRanges.sorted { $0.start < $1.start }

        // Build attributed string with highlights
        var currentIndex = 0
        for range in sortedRanges {
            let start = max(0, min(range.start, text.count))
            let end = max(start, min(range.end, text.count))

            // Add text before highlight
            if currentIndex < start {
                let startIdx = text.index(text.startIndex, offsetBy: currentIndex)
                let endIdx = text.index(text.startIndex, offsetBy: start)
                var before = AttributedString(String(text[startIdx..<endIdx]))
                before.font = .body
                result.append(before)
            }

            // Add highlighted text
            if start < end {
                let startIdx = text.index(text.startIndex, offsetBy: start)
                let endIdx = text.index(text.startIndex, offsetBy: end)
                var highlight = AttributedString(String(text[startIdx..<endIdx]))
                highlight.font = .body.bold()
                highlight.foregroundColor = .purple
                result.append(highlight)
            }

            currentIndex = end
        }

        // Add remaining text after last highlight
        if currentIndex < text.count {
            let startIdx = text.index(text.startIndex, offsetBy: currentIndex)
            var remaining = AttributedString(String(text[startIdx...]))
            remaining.font = .body
            result.append(remaining)
        }

        return result
    }

    /// Compare Strong's numbers, normalizing leading zeros (H0216 matches H216)
    private func strongsNumbersMatch(_ a: String, _ b: String) -> Bool {
        let pattern = "^(TH|H|G)(\\d+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return a.uppercased() == b.uppercased()
        }

        let aRange = NSRange(a.startIndex..., in: a)
        let bRange = NSRange(b.startIndex..., in: b)

        guard let aMatch = regex.firstMatch(in: a, range: aRange),
              let bMatch = regex.firstMatch(in: b, range: bRange),
              let aPrefixRange = Range(aMatch.range(at: 1), in: a),
              let aNumRange = Range(aMatch.range(at: 2), in: a),
              let bPrefixRange = Range(bMatch.range(at: 1), in: b),
              let bNumRange = Range(bMatch.range(at: 2), in: b) else {
            return a.uppercased() == b.uppercased()
        }

        let aPrefix = a[aPrefixRange].uppercased()
        let bPrefix = b[bPrefixRange].uppercased()
        let aNum = Int(a[aNumRange]) ?? 0
        let bNum = Int(b[bNumRange]) ?? 0

        return aPrefix == bPrefix && aNum == bNum
    }

    /// Get the translation name for display
    private var translationName: String? {
        guard let translationId = translationId else { return nil }
        return (try? TranslationDatabase.shared.getTranslation(id: translationId))?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(versesText)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let name = translationName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

// MARK: - Unified Preview Sheet System

/// A preview item that can represent verse references or other content types
struct PreviewItem: Equatable, Identifiable {
    let index: Int
    let type: ItemType

    var id: Int { index }

    enum ItemType: Equatable {
        case verse(verseId: Int, endVerseId: Int?, displayText: String, translationId: String?)
        case strongs(key: String, displayText: String)
    }

    var displayText: String {
        switch type {
        case .verse(_, _, let text, _): return text
        case .strongs(_, let text): return text
        }
    }

    /// Navigation title that formats short references (like "v1") into full references
    var navigationTitle: String {
        switch type {
        case .verse(let verseId, let endVerseId, let text, _):
            let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            // If display text is short and lacks uppercase letters (like "v1", "1-5"), format full reference
            if trimmed.count < 10 && !trimmed.contains(where: { $0.isLetter && $0.isUppercase }) {
                return PreviewItem.formatVerseRangeReference(verseId, endVerseId: endVerseId)
            }
            return trimmed
        case .strongs(_, let text):
            return text
        }
    }

    /// Format verse range reference (e.g., "Matt 1:1-5" or "Matt 1:1" or "Matt 1" for whole chapter)
    private static func formatVerseRangeReference(_ verseId: Int, endVerseId: Int?) -> String {
        let bookId = verseId / 1000000
        let chapter = (verseId % 1000000) / 1000
        let verse = verseId % 1000

        let bookName = (try? BundledModuleDatabase.shared.getBook(id: bookId))?.name ?? "?"

        if let ev = endVerseId {
            let endChapter = (ev % 1000000) / 1000
            let endVerse = ev % 1000

            // Handle cross-chapter ranges
            if endChapter != chapter {
                if verse == 1 && endVerse >= 900 {
                    return "\(bookName) \(chapter)-\(endChapter)"
                }
                return "\(bookName) \(chapter):\(verse)-\(endChapter):\(endVerse)"
            }

            // Same chapter - handle 999 sentinel for whole chapter
            if endVerse >= 900 {
                if verse == 1 {
                    return "\(bookName) \(chapter)"
                }
                return "\(bookName) \(chapter):\(verse)+"
            }

            if endVerse != verse {
                return "\(bookName) \(chapter):\(verse)-\(endVerse)"
            }
        }
        return "\(bookName) \(chapter):\(verse)"
    }

    var verseId: Int? {
        if case .verse(let id, _, _, _) = type { return id }
        return nil
    }

    var endVerseId: Int? {
        if case .verse(_, let end, _, _) = type { return end }
        return nil
    }

    var translationId: String? {
        if case .verse(_, _, _, let translation) = type { return translation }
        return nil
    }

    var strongsKey: String? {
        if case .strongs(let key, _) = type { return key }
        return nil
    }

    static func verse(index: Int, verseId: Int, endVerseId: Int? = nil, displayText: String, translationId: String? = nil) -> PreviewItem {
        PreviewItem(index: index, type: .verse(verseId: verseId, endVerseId: endVerseId, displayText: displayText, translationId: translationId))
    }

    static func strongs(index: Int, key: String, displayText: String) -> PreviewItem {
        PreviewItem(index: index, type: .strongs(key: key, displayText: displayText))
    }
}

/// Navigation state for preview sheets
struct PreviewSheetState: Equatable, Identifiable {
    let currentItem: PreviewItem
    let allItems: [PreviewItem]
    var totalCount: Int? = nil

    var id: String { "preview-sheet" }

    var currentIndex: Int {
        allItems.firstIndex(where: { $0.index == currentItem.index }) ?? 0
    }

    var displayCount: Int { totalCount ?? allItems.count }
    var canNavigatePrev: Bool { currentIndex > 0 }
    var canNavigateNext: Bool { currentIndex < allItems.count - 1 }

    func withPrev() -> PreviewSheetState? {
        guard canNavigatePrev else { return nil }
        return PreviewSheetState(currentItem: allItems[currentIndex - 1], allItems: allItems, totalCount: totalCount)
    }

    func withNext() -> PreviewSheetState? {
        guard canNavigateNext else { return nil }
        return PreviewSheetState(currentItem: allItems[currentIndex + 1], allItems: allItems, totalCount: totalCount)
    }
}

/// Shared sheet wrapper for previews with navigation support
/// Used by cross references, TSK, note references, commentary refs, etc.
struct PreviewSheet: View {
    @Binding var state: PreviewSheetState?
    let translationId: String?
    var onNavigateToVerse: ((Int) -> Void)?
    var onSearchStrongs: ((String) -> Void)?

    // Optional context/highlighting for search results
    var contextAmount: SearchContextAmount? = nil
    var highlightQuery: String? = nil
    var highlightMode: SearchMode? = nil

    private var item: PreviewItem? { state?.currentItem }

    var body: some View {
        NavigationStack {
            if let item = item {
                ScrollView {
                    switch item.type {
                    case .verse(let verseId, let endVerseId, _, let itemTranslationId):
                        VerseSheetContent(
                            title: item.displayText,
                            verseId: verseId,
                            endVerseId: endVerseId,
                            translationId: itemTranslationId ?? translationId,
                            onNavigate: nil,
                            contextAmount: contextAmount,
                            highlightQuery: highlightQuery,
                            highlightMode: highlightMode
                        )
                        .padding()
                    case .strongs(let key, _):
                        StrongsSheetContent(strongsKey: key)
                            .padding()
                    }
                }
                .id("\(item.index)")
                .navigationTitle(item.navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            state = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if let verseId = item.verseId, onNavigateToVerse != nil {
                            Button {
                                state = nil
                                onNavigateToVerse?(verseId)
                            } label: {
                                Image(systemName: "arrow.up.right")
                            }
                        } else if let key = item.strongsKey, onSearchStrongs != nil {
                            Button {
                                state = nil
                                onSearchStrongs?(key)
                            } label: {
                                Image(systemName: "arrow.up.right")
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if let currentState = state, currentState.allItems.count > 1 {
                            Button {
                                if let prev = currentState.withPrev() {
                                    state = prev
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!currentState.canNavigatePrev)

                            Spacer()

                            Text("\(currentState.currentIndex + 1) of \(currentState.displayCount)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .padding(.horizontal, 8)

                            Spacer()

                            Button {
                                if let next = currentState.withNext() {
                                    state = next
                                }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!currentState.canNavigateNext)
                        }
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.4), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
    }
}

/// Simple Strongs content placeholder for PreviewSheet
private struct StrongsSheetContent: View {
    let strongsKey: String

    var body: some View {
        // This would show the Strongs entry - for now just placeholder
        // In practice, lexicon views have their own more complete implementation
        Text("Strongs: \(strongsKey)")
            .foregroundStyle(.secondary)
    }
}

// MARK: - Note Text Editor with Cursor Tracking

/// UITextView wrapper that supports cursor position tracking and edit menu footnote insertion
struct NoteTextEditor: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let placeholder: String
    var onTextChange: (() -> Void)?
    var onCursorPositionChange: ((Int) -> Void)?  // Reports cursor position changes
    var onShowFootnotePicker: ((Int) -> Void)?  // (cursorPosition) - shows picker to insert existing or new

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> NoteTextView {
        let textView = NoteTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: fontSize)
        textView.backgroundColor = .clear
        textView.layer.cornerRadius = 8
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.isScrollEnabled = false
        textView.alwaysBounceVertical = false
        textView.keyboardDismissMode = .none

        // Enable text wrapping by making text container track text view width
        textView.textContainer.widthTracksTextView = true
        textView.textContainer.heightTracksTextView = false

        // Allow horizontal compression for proper width constraints
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Store coordinator reference for menu actions
        textView.coordinator = context.coordinator
        context.coordinator.textView = textView

        return textView
    }

    func updateUIView(_ textView: NoteTextView, context: Context) {
        // Update parent reference
        context.coordinator.parent = self

        // Only update if text actually changed (avoid cursor jump)
        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.attributedText = styledAttributedText(from: text)
            // Try to restore cursor position
            if selectedRange.location <= text.count {
                textView.selectedRange = selectedRange
            }
        }

        // Update placeholder visibility
        context.coordinator.updatePlaceholder()
    }

    /// Creates attributed text with styled footnote references
    func styledAttributedText(from text: String) -> NSAttributedString {
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor.label
        ]

        let attributedString = NSMutableAttributedString(string: text, attributes: baseAttributes)

        // Style footnote references [^n] as superscript with secondary color
        let pattern = "\\[\\^(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return attributedString
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            // Style the visible parts [n] as superscript
            let footnoteAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize * 0.7),
                .foregroundColor: UIColor.secondaryLabel,
                .baselineOffset: fontSize * 0.35
            ]
            attributedString.addAttributes(footnoteAttributes, range: match.range)

            // Hide the ^ by making it invisible (zero-width)
            let caretLocation = match.range.location + 1  // Position after [
            let caretRange = NSRange(location: caretLocation, length: 1)
            attributedString.addAttributes([
                .font: UIFont.systemFont(ofSize: 0.01),
                .foregroundColor: UIColor.clear
            ], range: caretRange)
        }

        return attributedString
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: NoteTextEditor
        weak var textView: NoteTextView?
        private var placeholderLabel: UILabel?

        init(_ parent: NoteTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let plainText = textView.text ?? ""
            parent.text = plainText
            parent.onTextChange?()
            updatePlaceholder()

            // Reapply footnote styling after edit
            let selectedRange = textView.selectedRange
            textView.attributedText = parent.styledAttributedText(from: plainText)
            textView.selectedRange = selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            updatePlaceholder()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            updatePlaceholder()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Report cursor position changes
            let cursorPosition = textView.selectedRange.location
            parent.onCursorPositionChange?(cursorPosition)
        }

        func updatePlaceholder() {
            guard let textView = textView else { return }

            if placeholderLabel == nil {
                let label = UILabel()
                label.text = parent.placeholder
                label.font = .systemFont(ofSize: parent.fontSize)
                label.textColor = UIColor.tertiaryLabel
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 8)
                ])
                placeholderLabel = label
            }

            placeholderLabel?.isHidden = !textView.text.isEmpty || textView.isFirstResponder
        }

        // MARK: - Edit Menu Customization (iOS 16+)

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard parent.onShowFootnotePicker != nil else {
                return UIMenu(children: suggestedActions)
            }

            let insertAction = UIAction(title: "Insert Footnote", image: UIImage(systemName: "note.text.badge.plus")) { [weak self] _ in
                self?.showFootnotePicker()
            }

            // Insert at the beginning - system actions come after
            return UIMenu(children: [insertAction] + suggestedActions)
        }

        func showFootnotePicker() {
            guard let textView = textView else { return }

            // Get current cursor position (or start of selection)
            let cursorPosition = textView.selectedRange.location

            // Show the picker - parent will handle inserting the marker
            parent.onShowFootnotePicker?(cursorPosition)
        }
    }
}

/// Custom UITextView subclass that supports the Insert Footnote menu action
class NoteTextView: UITextView {
    weak var coordinator: NoteTextEditor.Coordinator?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupKeyboardToolbar()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupKeyboardToolbar()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Set text container width for proper text wrapping
        let insets = textContainerInset
        let containerWidth = bounds.width - insets.left - insets.right - textContainer.lineFragmentPadding * 2
        if containerWidth > 0 && textContainer.size.width != containerWidth {
            textContainer.size.width = containerWidth
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let fixedWidth = bounds.width
        guard fixedWidth > 0 else { return super.intrinsicContentSize }
        let size = sizeThatFits(CGSize(width: fixedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: fixedWidth, height: max(size.height, 60))
    }

    private func setupKeyboardToolbar() {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()

        let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let doneButton = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            style: .plain,
            target: self,
            action: #selector(dismissKeyboardAction)
        )
        doneButton.tintColor = .label

        toolbar.items = [flexSpace, doneButton]
        self.inputAccessoryView = toolbar
    }

    @objc private func dismissKeyboardAction() {
        self.resignFirstResponder()
    }

    // Override to show Insert Footnote even without text selection
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(insertFootnoteAction) {
            return coordinator?.parent.onShowFootnotePicker != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func insertFootnoteAction() {
        coordinator?.showFootnotePicker()
    }
}

#Preview {
    ToolPanelView(
        book: 43,
        chapter: 3,
        currentVerse: 16,
        toolbarsHidden: .constant(false),
        requestAddNoteForVerse: .constant(nil)
    )
}
