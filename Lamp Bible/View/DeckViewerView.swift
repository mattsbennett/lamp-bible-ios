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
        ZStack {
            Color.black.ignoresSafeArea()

            if slides.isEmpty {
                ContentUnavailableView(
                    "Nothing to Show",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Every slide in this deck is hidden.")
                )
                .foregroundStyle(.white)
            } else {
                // The bar insets the slide rather than floating over it. A
                // widescreen slide fills the height in landscape, so an overlay
                // hides the one line most worth reading — the slide's title.
                slidePager
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if showsChrome {
                            chromeBar.transition(.opacity)
                        }
                    }
            }
        }
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .sheet(isPresented: $showsNotes) { notesSheet }
        .sheet(isPresented: $showsSlideList) { slideListSheet }
        .onAppear { DeckViewerOrientation.requestLandscape() }
        .onDisappear { DeckViewerOrientation.release() }
    }

    // MARK: - Slides

    private var slidePager: some View {
        TabView(selection: $index) {
            ForEach(Array(slides.enumerated()), id: \.element.id) { position, slide in
                LampPresentationSlideCanvas(slide: slide, deck: deck, store: store)
                    .aspectRatio(deck.aspectRatio.ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(position)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showsChrome.toggle() }
        }
    }

    // MARK: - Chrome

    private var chromeBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Close deck")

                VStack(alignment: .leading, spacing: 1) {
                    Text(deck.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !slides.isEmpty {
                        Text("Slide \(index + 1) of \(slides.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if currentNotes != nil {
                    Button {
                        showsNotes = true
                    } label: {
                        Image(systemName: "note.text")
                            .font(.headline)
                            .frame(width: 34, height: 34)
                    }
                    .accessibilityLabel("Presenter notes")
                }

                Button {
                    showsSlideList = true
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Choose slide")
                .disabled(slides.isEmpty)
            }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
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
            .navigationTitle("Slides")
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
    init(entry: PresentationDeckEntry) {
        self.init(deck: entry.deck, store: PresentationDeckStorage.shared.store(for: entry))
    }
}
