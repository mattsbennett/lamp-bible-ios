import LampCore
import LampPresentationUI
import SwiftUI

struct PresentationRemoteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var client = PresentationRemoteClient()
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
                ScrollView {
                    VStack(spacing: 18) {
                        if horizontalSizeClass == .regular {
                            HStack(alignment: .top, spacing: 20) {
                                slideColumn(state)
                                    .frame(maxWidth: .infinity)
                                notesCard(state)
                                    .frame(width: 330)
                            }
                        } else {
                            VStack(spacing: 16) {
                                slideColumn(state)
                                notesCard(state)
                            }
                        }
                    }
                    .padding()
                }
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

    private func slideColumn(_ state: LampPresentationRemoteState) -> some View {
        // The same renderer the Mac presents with, so what the remote shows is
        // what the room sees rather than an approximation of it.
        let style = LampPresentationSlideStyle(
            theme: state.theme,
            aspectRatio: state.aspectRatio
        )
        return VStack(alignment: .leading, spacing: 12) {
            if let slide = state.currentSlide {
                LampPresentationSlideCanvas(slide: slide, style: style)
                    .aspectRatio(state.aspectRatio.ratio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            }

            if let next = state.nextSlide {
                HStack(spacing: 12) {
                    LampPresentationSlideCanvas(slide: next, style: style, compact: true)
                        .aspectRatio(state.aspectRatio.ratio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .frame(width: 132)
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
            Label("Presenter Notes", systemImage: "note.text")
                .font(.headline)

            Divider()

            if let notes = state.currentSlide?.speakerNotes,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(notes)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text("No notes for this slide.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
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
