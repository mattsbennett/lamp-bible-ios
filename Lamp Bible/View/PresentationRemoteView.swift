import LampCore
import LampPresentationUI
import SwiftUI

/// How the presenter's slide and notes share the space: side by side where
/// the space is wider than it is tall, stacked where it is taller, and split
/// between them where the presenter last dragged the handle between them.
///
/// Chosen by the shape of the space rather than its size class: an iPad held
/// upright is regular in width, and would put the notes in a narrow column
/// beside a slide filling the screen; an iPhone on its side is compact, and
/// would stack a slide taller than the screen above notes out of sight.
///
/// The split is kept as the notes' share of the space, one for each
/// arrangement, since one divides a width and the other a height. What is
/// shown is that share held within each side's minimum, without changing
/// the share kept, so a split chosen with room for it comes back when the
/// room does, after the device is turned or the window narrowed.
struct PresenterLayout: Equatable {
    /// Whether the notes are beside the slide, rather than beneath it.
    var isSideBySide: Bool
    /// The length the split divides, less the handle between the sides.
    var available: CGFloat
    /// The notes' part of it.
    var notes: CGFloat

    /// The handle's breadth between the sides.
    static let gap: CGFloat = 20
    static let standardWideShare = 0.45
    static let standardTallShare = 0.5
    /// The least either side is given: room for the notes' heading and a
    /// few lines, and for a slide still legible as one.
    static let notesMinimum = CGSize(width: 220, height: 150)
    static let slideMinimum = CGSize(width: 200, height: 120)

    init(size: CGSize, wideShare: Double, tallShare: Double) {
        isSideBySide = size.width > size.height
        available = max((isSideBySide ? size.width : size.height) - Self.gap, 0)
        notes = 0
        notes = clamped((available * (isSideBySide ? wideShare : tallShare)).rounded())
    }

    var slide: CGFloat { available - notes }

    /// The notes' share the split stands at, to be kept.
    var share: Double { available > 0 ? Double(notes / available) : 0 }

    /// The split after the handle is dragged `translation` toward the notes,
    /// which gives them that much less.
    func dragged(by translation: CGFloat) -> PresenterLayout {
        var layout = self
        layout.notes = clamped(notes - translation)
        return layout
    }

    /// Whether the slide's column, in `size`, has room for the next slide
    /// beneath the current one at little cost to it: the current slide kept
    /// at `nextSlideCost` or more of the width it would have alone. Where it
    /// has not, the current slide takes the column, being what the room sees.
    func showsNext(in size: CGSize, aspectRatio: CGFloat) -> Bool {
        let column = isSideBySide
            ? CGSize(width: slide, height: size.height)
            : CGSize(width: size.width, height: slide)
        let nextRow = Self.nextThumbnailWidth / aspectRatio + Self.columnSpacing
        let alone = min(column.width, column.height * aspectRatio)
        let withNext = min(column.width, max(column.height - nextRow, 0) * aspectRatio)
        return alone > 0 && withNext >= alone * Self.nextSlideCost
    }

    static let nextSlideCost: CGFloat = 0.85

    /// How wide the current slide is drawn in `size`: as wide as its column,
    /// or as the column's height allows, less the next slide's row where
    /// that is shown.
    func slideWidth(in size: CGSize, aspectRatio: CGFloat) -> CGFloat {
        let column = isSideBySide
            ? CGSize(width: slide, height: size.height)
            : CGSize(width: size.width, height: slide)
        let nextRow = showsNext(in: size, aspectRatio: aspectRatio)
            ? Self.nextThumbnailWidth / aspectRatio + Self.columnSpacing
            : 0
        return min(column.width, max(column.height - nextRow, 0) * aspectRatio)
    }

    /// Below this width a slide is drawn as a thumbnail is, its type held
    /// legible and its words kept from crowding one another; above it,
    /// exactly as the room sees it.
    static let thumbnailWidth: CGFloat = 320

    /// The next slide's thumbnail, and the space above it.
    static let nextThumbnailWidth: CGFloat = 132
    static let columnSpacing: CGFloat = 12

    private func clamped(_ extent: CGFloat) -> CGFloat {
        let notesMinimum = isSideBySide ? Self.notesMinimum.width : Self.notesMinimum.height
        let slideMinimum = isSideBySide ? Self.slideMinimum.width : Self.slideMinimum.height
        // Too little room for both minimums: halves.
        guard available - slideMinimum >= notesMinimum else { return (available / 2).rounded() }
        return min(max(extent, notesMinimum), available - slideMinimum)
    }
}

/// The sizes presenter notes can be read at, stepped through by the notes'
/// own buttons: kept on the device holding the remote, since what suits is a
/// matter of how far it is held from the eyes. Each is the size at the
/// standard text size, and scales with the reader's own text size, as the
/// body text it begins as does.
enum PresenterNotesSize {
    static let sizes: [Double] = [13, 15, 17, 20, 24, 28, 34, 40]
    static let standard: Double = 17

    /// The size `steps` along from `size`: from the nearest, if `size` is not
    /// one of them, and no further than the smallest or largest.
    static func stepped(_ size: Double, by steps: Int) -> Double {
        let nearest = sizes.indices.min { abs(sizes[$0] - size) < abs(sizes[$1] - size) } ?? 0
        return sizes[min(max(nearest + steps, 0), sizes.count - 1)]
    }
}

struct PresentationRemoteView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var client = PresentationRemoteClient()
    @AppStorage("presenterNotesFontSize") private var notesFontSize = PresenterNotesSize.standard
    @AppStorage("presenterNotesWidthShare") private var notesWidthShare = PresenterLayout.standardWideShare
    @AppStorage("presenterNotesHeightShare") private var notesHeightShare = PresenterLayout.standardTallShare
    /// How far the handle between slide and notes has been dragged, toward
    /// the notes, while it is.
    @GestureState private var splitDrag: CGFloat = 0
    @State private var pairingCode = ""
    @State private var showingScanner = false
    @State private var scannerError: String?
    @FocusState private var pairingCodeFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch client.phase {
                case .stopped, .browsing:
                    discoveryView
                case .connecting, .awaitingPairing, .pairing:
                    pairingView
                case .presenting:
                    presenterView
                case .ended:
                    failureView("The presentation has ended on the Mac.")
                case let .failed(message):
                    failureView(message)
                }
            }
            .navigationTitle("Presentation Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                if client.phase == .presenting, let state = client.presentationState {
                    // While presenting the bars carry everything but the slide
                    // and notes: the deck, place and time up top, the controls
                    // floating below as the system's glass bottom bar.
                    ToolbarItem(placement: .principal) {
                        presentingTitle(state)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        slideMenu(state)
                    }
                    remoteControls(state)
                }
            }
        }
        .onAppear {
            if client.phase == .stopped { client.startBrowsing() }
        }
        // When the Mac quits or ends the presentation there is nothing left
        // to control, so the remote goes too.
        .onChange(of: client.phase) { _, phase in
            if phase == .ended { dismiss() }
        }
        .onDisappear { client.stop() }
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    PresentationPairingScanner(
                        onCode: { code in
                            pairingCode = code
                            showingScanner = false
                            client.pair(code: code)
                        },
                        onFailure: { message in
                            scannerError = message
                            showingScanner = false
                        }
                    )
                    .ignoresSafeArea()

                    Text("Point the camera at the pairing QR code shown on the Mac.")
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding()
                }
                .navigationTitle("Scan Pairing Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingScanner = false }
                    }
                }
            }
        }
    }

    private var discoveryView: some View {
        List {
            Section {
                if client.presenters.isEmpty {
                    HStack(spacing: 14) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Looking for presentations…")
                                .font(.headline)
                            Text("Start Presenter on a Mac running Lamp Bible.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 14)
                } else {
                    ForEach(client.presenters) { presenter in
                        Button {
                            client.connect(to: presenter)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(presenter.name)
                                        .foregroundStyle(.primary)
                                    Text("Available on this network")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "play.rectangle.on.rectangle")
                                    .font(.title2)
                            }
                        }
                    }
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Both devices must be on the same local network. Nearby peer-to-peer discovery is also supported.")
            }
        }
        .refreshable { client.startBrowsing() }
    }

    private var pairingView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "lock.laptopcomputer")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text(client.phase == .connecting ? "Connecting…" : "Pair with the Mac")
                    .font(.title2.bold())
                Text(client.phase == .connecting
                     ? client.selectedPresenterName
                     : "Scan the code shown in the Mac presenter controls. The manual code is available as a fallback.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if client.phase == .connecting {
                ProgressView()
                    .controlSize(.large)
            } else {
                if PresentationPairingScanner.isAvailable {
                    Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                        scannerError = nil
                        showingScanner = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 320)
                }

                HStack {
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(.quaternary)
                    Text("or enter manually")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: 320)

                TextField("ABCDEFGHJKLMNPQR", text: $pairingCode)
                    .keyboardType(.asciiCapable)
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($pairingCodeFocused)
                    .frame(maxWidth: 260)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .onChange(of: pairingCode) { _, value in
                        pairingCode = LampPresentationRemotePairing.sanitizedCode(value)
                    }
                    .onSubmit { pair() }

                if let scannerError {
                    Label(scannerError, systemImage: "camera.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 360)
                }

                if let pairingError = client.pairingError {
                    Label(pairingError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                Button {
                    pair()
                } label: {
                    if client.phase == .pairing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Pair Remote")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    LampPresentationRemotePairing.normalizedCode(pairingCode) == nil
                        || client.phase == .pairing
                )
                .frame(maxWidth: 320)
            }

            // Back to the nearby Macs, for a wrong choice. Only here, before
            // a presentation is open: once it is, there's nothing to change.
            Button("Choose a Different Mac") { changePresenter() }
                .font(.subheadline)

            Spacer()
        }
        .padding(28)
    }

    private var presenterView: some View {
        Group {
            if let state = client.presentationState {
                // Nothing scrolls but the notes, so they keep their share of
                // the space however long they run.
                GeometryReader { geometry in
                    let resting = PresenterLayout(
                        size: geometry.size,
                        wideShare: notesWidthShare,
                        tallShare: notesHeightShare
                    )
                    let layout = resting.dragged(by: splitDrag)
                    let showsNext = layout.showsNext(in: geometry.size, aspectRatio: state.aspectRatio.ratio)
                    let compact = layout.slideWidth(in: geometry.size, aspectRatio: state.aspectRatio.ratio)
                        < PresenterLayout.thumbnailWidth
                    if layout.isSideBySide {
                        HStack(spacing: 0) {
                            slideColumn(state, showsNext: showsNext, compact: compact)
                                .frame(width: layout.slide, alignment: .topLeading)
                                .frame(maxHeight: .infinity, alignment: .top)
                            splitHandle(resting)
                            notesCard(state)
                                .frame(width: layout.notes)
                        }
                    } else {
                        VStack(spacing: 0) {
                            slideColumn(state, showsNext: showsNext, compact: compact)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .frame(height: layout.slide, alignment: .top)
                            splitHandle(resting)
                            notesCard(state)
                                .frame(height: layout.notes)
                        }
                    }
                }
                .padding()
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Waiting for the first slide…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The deck, where it has got to, and how long it has run, in the space
    /// a navigation title takes.
    private func presentingTitle(_ state: LampPresentationRemoteState) -> some View {
        VStack(spacing: 1) {
            Text(state.deckTitle)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("Slide \(state.currentSlideIndex + 1) of \(state.slideCount)")
                Text("·")
                Text(elapsedTime(state.elapsedSeconds))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if state.isBlackout {
                    Text("·")
                    Label("Black", systemImage: "moon.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Audience screen is black")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func slideMenu(_ state: LampPresentationRemoteState) -> some View {
        Menu {
            ForEach(state.slideReferences) { slide in
                Button {
                    client.send(.init(action: .goTo, slideIndex: slide.index))
                } label: {
                    if slide.index == state.currentSlideIndex {
                        Label("\(slide.index + 1). \(slide.title)", systemImage: "checkmark")
                    } else {
                        Text("\(slide.index + 1). \(slide.title)")
                    }
                }
            }
        } label: {
            Image(systemName: "list.number")
        }
        .accessibilityLabel("Choose slide")
    }

    /// The handle between slide and notes: dragged, it moves the split, and
    /// the notes' share it is left at is kept for this arrangement.
    private func splitHandle(_ resting: PresenterLayout) -> some View {
        let sideBySide = resting.isSideBySide
        return ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: sideBySide ? 5 : 40, height: sideBySide ? 40 : 5)
        }
        .frame(width: sideBySide ? PresenterLayout.gap : nil, height: sideBySide ? nil : PresenterLayout.gap)
        .frame(maxWidth: sideBySide ? nil : .infinity, maxHeight: sideBySide ? .infinity : nil)
        // A touch's breadth either side, over the edges of the sides.
        .contentShape(Rectangle().inset(by: -12))
        .zIndex(1)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($splitDrag) { value, drag, _ in
                    drag = sideBySide ? value.translation.width : value.translation.height
                }
                .onEnded { value in
                    let moved = resting.dragged(by: sideBySide ? value.translation.width : value.translation.height)
                    keep(moved)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Notes size")
        .accessibilityValue("\(Int((resting.share * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = resting.available * 0.05
            keep(resting.dragged(by: direction == .increment ? -step : step))
        }
    }

    private func keep(_ layout: PresenterLayout) {
        if layout.isSideBySide {
            notesWidthShare = layout.share
        } else {
            notesHeightShare = layout.share
        }
    }

    private func slideColumn(_ state: LampPresentationRemoteState, showsNext: Bool, compact: Bool) -> some View {
        // The same renderer the Mac presents with, so what the remote shows is
        // what the room sees rather than an approximation of it.
        let style = LampPresentationSlideStyle(
            theme: state.theme,
            aspectRatio: state.aspectRatio
        )
        return VStack(alignment: .leading, spacing: PresenterLayout.columnSpacing) {
            if let slide = state.currentSlide {
                LampPresentationSlideCanvas(slide: slide, style: style, compact: compact)
                    .aspectRatio(state.aspectRatio.ratio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                    // A tap on the slide moves on, as a click on the screen
                    // presenting it does: the largest target there is, for a
                    // presenter whose eyes are on the room.
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .onTapGesture {
                        if state.canGoNext { client.send(.init(action: .next)) }
                    }
                    .accessibilityAction(named: Text("Next Slide")) {
                        if state.canGoNext { client.send(.init(action: .next)) }
                    }
            }

            if showsNext, let next = state.nextSlide {
                HStack(spacing: 12) {
                    LampPresentationSlideCanvas(slide: next, style: style, compact: true)
                        .aspectRatio(state.aspectRatio.ratio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .frame(width: PresenterLayout.nextThumbnailWidth)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("UP NEXT")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(next.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    Spacer()
                }
            }
        }
    }

    private func notesCard(_ state: LampPresentationRemoteState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Presenter Notes", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                notesSizeButtons
            }

            Divider()

            ScrollView {
                if let notes = state.currentSlide?.speakerNotes,
                   !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(notes)
                        .font(.system(size: UIFontMetrics(forTextStyle: .body).scaledValue(for: notesFontSize)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text("No notes for this slide.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // A new slide's notes are read from their start.
            .id(state.currentSlide?.id)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var notesSizeButtons: some View {
        HStack(spacing: 14) {
            Button {
                notesFontSize = PresenterNotesSize.stepped(notesFontSize, by: -1)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .disabled(notesFontSize <= PresenterNotesSize.sizes[0])
            .accessibilityLabel("Smaller notes")

            Button {
                notesFontSize = PresenterNotesSize.stepped(notesFontSize, by: 1)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .disabled(notesFontSize >= PresenterNotesSize.sizes[PresenterNotesSize.sizes.count - 1])
            .accessibilityLabel("Larger notes")
        }
        .buttonStyle(.borderless)
        .font(.body)
    }

    @ToolbarContentBuilder
    private func remoteControls(_ state: LampPresentationRemoteState) -> some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                client.send(.init(action: .toggleBlackout))
            } label: {
                Image(systemName: state.isBlackout ? "sun.max.fill" : "moon.fill")
            }
            .accessibilityLabel(state.isBlackout ? "Restore audience slide" : "Black out audience screen")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            Button {
                client.send(.init(action: .previous))
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(!state.canGoPrevious)

            Button {
                client.send(.init(action: .next))
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.canGoNext)
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Remote Unavailable", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Look Again") { client.startBrowsing() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func changePresenter() {
        pairingCode = ""
        client.startBrowsing()
    }

    private func pair() {
        pairingCodeFocused = false
        client.pair(code: pairingCode)
    }

    private func elapsedTime(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
