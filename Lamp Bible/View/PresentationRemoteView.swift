import LampCore
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
                case let .failed(message):
                    failureView(message)
                }
            }
            .navigationTitle("Presentation Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if client.phase != .browsing && client.phase != .stopped {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Change") {
                            pairingCode = ""
                            client.startBrowsing()
                        }
                    }
                }
            }
        }
        .onAppear {
            if client.phase == .stopped { client.startBrowsing() }
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

            Spacer()
        }
        .padding(28)
    }

    private var presenterView: some View {
        Group {
            if let state = client.presentationState {
                ScrollView {
                    VStack(spacing: 18) {
                        presenterHeader(state)

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
                    .padding(.bottom, 96)
                }
                .safeAreaInset(edge: .bottom) {
                    remoteControls(state)
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

    private func presenterHeader(_ state: LampPresentationRemoteState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.deckTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text("Slide \(state.currentSlideIndex + 1) of \(state.slideCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if state.isBlackout {
                Label("Audience black", systemImage: "moon.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            Text(elapsedTime(state.elapsedSeconds))
                .font(.system(.headline, design: .monospaced))
                .contentTransition(.numericText())

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
    }

    private func slideColumn(_ state: LampPresentationRemoteState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let slide = state.currentSlide {
                RemoteSemanticSlideView(
                    slide: slide,
                    theme: state.theme,
                    aspectRatio: state.aspectRatio,
                    isCompact: false
                )
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            }

            if let next = state.nextSlide {
                HStack(spacing: 12) {
                    RemoteSemanticSlideView(
                        slide: next,
                        theme: state.theme,
                        aspectRatio: state.aspectRatio,
                        isCompact: true
                    )
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

    private func remoteControls(_ state: LampPresentationRemoteState) -> some View {
        HStack(spacing: 12) {
            Button {
                client.send(.init(action: .toggleBlackout))
            } label: {
                Image(systemName: state.isBlackout ? "sun.max.fill" : "moon.fill")
                    .frame(width: 30, height: 38)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(state.isBlackout ? "Restore audience slide" : "Black out audience screen")

            Button {
                client.send(.init(action: .previous))
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .frame(minHeight: 38)
            }
            .buttonStyle(.bordered)
            .disabled(!state.canGoPrevious)

            Button {
                client.send(.init(action: .next))
            } label: {
                Label("Next", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.canGoNext)
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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

private struct RemoteSemanticSlideView: View {
    let slide: LampPresentationSlide
    let theme: LampPresentationTheme
    let aspectRatio: LampPresentationAspectRatio
    let isCompact: Bool

    private var background: Color { Color(hex: theme.backgroundColor) ?? .black }
    private var foreground: Color { Color(hex: theme.foregroundColor) ?? .white }
    private var accent: Color { Color(hex: theme.accentColor) ?? .orange }

    var body: some View {
        VStack(alignment: slide.layout == .title || slide.layout == .closing ? .center : .leading,
               spacing: isCompact ? 3 : 10) {
            Spacer(minLength: 0)
            ForEach(slide.blocks) { block in
                blockView(block)
            }
            Spacer(minLength: 0)
        }
        .padding(isCompact ? 8 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(foreground)
        .background(background)
        .aspectRatio(aspectRatio.ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: isCompact ? 7 : 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slide.displayTitle)
    }

    @ViewBuilder
    private func blockView(_ block: LampPresentationBlock) -> some View {
        switch block.kind {
        case .title:
            Text(block.text)
                .font(isCompact ? .caption.bold() : .title2.bold())
                .multilineTextAlignment(slide.layout == .title || slide.layout == .closing ? .center : .leading)
                .minimumScaleFactor(0.6)
        case .subtitle:
            Text(block.text)
                .font(isCompact ? .caption2 : .headline)
                .foregroundStyle(accent)
                .multilineTextAlignment(.center)
        case .scripture, .quotation:
            Text(block.text)
                .font(isCompact ? .caption2 : .title3)
                .italic()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.6)
        case .citation, .caption:
            Text(block.text)
                .font(isCompact ? .system(size: 6) : .caption)
                .foregroundStyle(accent)
        case .image:
            Image(systemName: "photo")
                .font(isCompact ? .caption : .title)
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
        case .body:
            Text(block.text)
                .font(isCompact ? .system(size: 7) : .body)
                .lineLimit(isCompact ? 3 : nil)
                .minimumScaleFactor(0.65)
        }
    }
}
