import LampCore
import LampPresentationUI
import SwiftUI
import UIKit

/// A widescreen slide letterboxes badly on an upright phone — more than half
/// the screen goes to black bands — so the viewer asks for landscape the way a
/// presentation player is expected to, and gives the orientation back on the
/// way out.
///
/// iPad is left alone: it has the room, and it may be sharing the screen with
/// another app, where seizing the orientation would be rude.
@MainActor
private enum DeckViewerOrientation {
    static func requestLandscape() {
        request(.landscape)
    }

    /// Hand the orientation back. Widening the mask alone is not enough: UIKit
    /// only re-evaluates on device motion, so a phone resting on a desk — or
    /// one with rotation lock on — would keep showing the rest of the app
    /// sideways. Ask for upright unless the phone really is being held that way.
    static func release() {
        request(UIDevice.current.orientation.isLandscape ? .allButUpsideDown : .portrait)
        LampBibleAppDelegate.supportedOrientations = .allButUpsideDown
    }

    private static func request(_ orientations: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        // Narrow what the app allows first: a geometry request is granted only
        // within the supported set, and UIKit would otherwise rotate straight
        // back to match the device.
        LampBibleAppDelegate.supportedOrientations = orientations
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Reads a deck one slide at a time.
///
/// Hidden slides are skipped, as they are in the Mac presenter, so what the
/// room would see is what this shows. The slide keeps its authored aspect ratio
/// and letterboxes rather than reflowing — a deck read on a phone should look
/// like the deck, not like a web page.
struct DeckViewerView: View {
    let deck: LampPresentationDeck
    var store: LampPresentationDeckStore = PresentationDeckStorage.shared.syncedStore

    @Environment(\.dismiss) private var dismiss

    @State private var index = 0
    /// Where the deck opens; the library's outline can open it partway.
    var initialIndex = 0
    @State private var didApplyInitialIndex = false
    @State private var showsChrome = true
    @State private var showsNotes = false
    @State private var showsSlideList = false

    private var slides: [LampPresentationSlide] {
        deck.slides.filter { !$0.isHidden }
    }

    private var currentSlide: LampPresentationSlide? {
        slides.indices.contains(index) ? slides[index] : nil
    }

    private var currentNotes: String? {
        let notes = currentSlide?.speakerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes?.isEmpty == false ? notes : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = ChromeLayout(
                screen: proxy.size,
                safeArea: proxy.safeAreaInsets,
                slideRatio: deck.aspectRatio.ratio
            )
            ZStack {
                Color.black

                if slides.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Show",
                        systemImage: "rectangle.on.rectangle.slash",
                        description: Text("Every slide in this deck is hidden.")
                    )
                    .foregroundStyle(.white)
                    .overlay(alignment: .topLeading) {
                        closeButton.padding(.leading, max(proxy.safeAreaInsets.leading, 16)).padding(.top, 12)
                    }
                } else if layout.usesSideBands {
                    // A widescreen slide on a phone held sideways leaves a band
                    // of black either side. The controls live there, so the
                    // slide keeps the full height of the screen and nothing is
                    // laid over it.
                    slidePager
                    if showsChrome {
                        sideBandChrome(layout)
                            .transition(.opacity)
                    }
                } else {
                    // No room beside the slide: the bar insets it rather than
                    // floating over it, since an overlay would hide the one
                    // line most worth reading, the slide's title.
                    slidePager
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if showsChrome {
                                chromeBar.transition(.opacity)
                            }
                        }
                }
            }
        }
        // Measured edge to edge: the black bands beside the slide run into
        // the rounded corners and the sensor housing, and the controls are
        // placed within them clear of both.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .sheet(isPresented: $showsNotes) { notesSheet }
        .sheet(isPresented: $showsSlideList) { slideListSheet }
        .onAppear {
            DeckViewerOrientation.requestLandscape()
            if !didApplyInitialIndex {
                didApplyInitialIndex = true
                index = min(max(initialIndex, 0), max(slides.count - 1, 0))
            }
        }
        .onDisappear { DeckViewerOrientation.release() }
    }

    /// Where the controls go: beside the slide when the black bands either
    /// side are wide enough for a button, otherwise in a bar above it.
    private struct ChromeLayout {
        let screen: CGSize
        let safeArea: EdgeInsets
        let slideRatio: CGFloat

        /// The slide at the screen's full height.
        var slideWidth: CGFloat { screen.height * slideRatio }
        var bandWidth: CGFloat { (screen.width - slideWidth) / 2 }
        var usesSideBands: Bool { bandWidth >= DeckViewerView.controlSize + 16 }
    }

    static let controlSize: CGFloat = 44

    // MARK: - Slides

    private var slidePager: some View {
        TabView(selection: $index) {
            ForEach(Array(slides.enumerated()), id: \.element.id) { position, slide in
                LampPresentationSlideCanvas(slide: slide, deck: deck, store: store)
                    .aspectRatio(deck.aspectRatio.ratio, contentMode: .fit)
                    // The slide's own ground stays inside the slide, rather
                    // than spilling into the home indicator's margin.
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .tag(position)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
        }
    }

    // MARK: - Chrome

    /// Close at the top of the left band; the slide list, presenter notes and
    /// the position at the right, as a player keeps them out of the picture.
    private func sideBandChrome(_ layout: ChromeLayout) -> some View {
        HStack(spacing: 0) {
            VStack {
                closeButton
                Spacer()
            }
            .frame(width: layout.bandWidth)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                slideListButton
                if currentNotes != nil {
                    notesButton
                }
                Spacer()
                positionLabel
                    .padding(.bottom, 4)
            }
            .frame(width: layout.bandWidth)
        }
        .padding(.vertical, 22)
    }

    private var chromeBar: some View {
        HStack(spacing: 14) {
            closeButton

            VStack(alignment: .leading, spacing: 1) {
                Text(deck.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if !slides.isEmpty {
                    Text("Slide \(index + 1) of \(slides.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.white)

            Spacer(minLength: 0)

            if currentNotes != nil {
                notesButton
            }
            slideListButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: Self.controlSize, height: Self.controlSize)
        }
        .foregroundStyle(.white)
        .deckControlSurface()
        .accessibilityLabel("Close deck")
    }

    private var slideListButton: some View {
        Button {
            showsSlideList = true
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.body.weight(.semibold))
                .frame(width: Self.controlSize, height: Self.controlSize)
        }
        .foregroundStyle(.white)
        .deckControlSurface()
        .accessibilityLabel("Choose slide")
        .disabled(slides.isEmpty)
    }

    private var notesButton: some View {
        Button {
            showsNotes = true
        } label: {
            Image(systemName: "text.bubble")
                .font(.body.weight(.semibold))
                .frame(width: Self.controlSize, height: Self.controlSize)
        }
        .foregroundStyle(.white)
        .deckControlSurface()
        .accessibilityLabel("Presenter notes")
    }

    /// The slide's place in the deck as a ring filling round, with the number
    /// inside and the count under it. It is a control: a tap opens the slide
    /// list.
    private var positionLabel: some View {
        Button {
            showsSlideList = true
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.22), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(index + 1) / CGFloat(max(slides.count, 1)))
                        .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(index + 1)")
                        .font(.headline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: Self.controlSize, height: Self.controlSize)
                .animation(.easeOut(duration: 0.25), value: index)
                Text("of \(slides.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Slide \(index + 1) of \(slides.count)")
        .accessibilityHint("Opens the list of slides")
    }

    // MARK: - Sheets

    private var notesSheet: some View {
        NavigationStack {
            ScrollView {
                Text(currentNotes ?? "")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Presenter Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsNotes = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var slideListSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 148), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(Array(slides.enumerated()), id: \.element.id) { position, slide in
                        Button {
                            index = position
                            showsSlideList = false
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                LampPresentationSlideCanvas(
                                    slide: slide,
                                    deck: deck,
                                    store: store,
                                    compact: true
                                )
                                .aspectRatio(deck.aspectRatio.ratio, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(
                                            position == index ? Color.accentColor : Color.clear,
                                            lineWidth: 3
                                        )
                                }
                                Text("\(position + 1). \(slide.displayTitle)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle(deck.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsSlideList = false }
                }
            }
        }
    }
}

extension DeckViewerView {
    /// Opens a stored deck, its images resolved wherever it was kept.
    init(entry: PresentationDeckEntry, startingAt initialIndex: Int = 0) {
        self.init(deck: entry.deck, store: PresentationDeckStorage.shared.store(for: entry), initialIndex: initialIndex)
    }
}

private extension View {
    /// Liquid Glass where the OS has it; the app still ships to iOS 17, which
    /// gets a dark material in the same circle.
    @ViewBuilder
    func deckControlSurface() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}
