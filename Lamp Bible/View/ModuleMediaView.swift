//
//  ModuleMediaView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import SwiftUI

/// Displays a book's media (image or audio), found by core's rules for a
/// book's pictures (`ModuleMediaStorage.bookMediaURL`)
struct ModuleMediaView: View {
    let mediaRef: MediaReference
    let moduleId: String
    let caption: String?
    let alignment: MediaAlignment

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadError = false
    @State private var showFullScreen = false

    init(
        mediaRef: MediaReference,
        moduleId: String,
        caption: String? = nil,
        alignment: MediaAlignment = .center
    ) {
        self.mediaRef = mediaRef
        self.moduleId = moduleId
        self.caption = caption
        self.alignment = alignment
    }

    var body: some View {
        Group {
            switch mediaRef.type {
            case .image:
                imageView
            case .audio:
                audioView
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let image = loadedImage {
                ModuleFullScreenImageView(image: image, caption: caption, isPresented: $showFullScreen)
            }
        }
    }

    // MARK: - Image View

    @ViewBuilder
    private var imageView: some View {
        VStack(alignment: horizontalAlignment, spacing: 8) {
            if isLoading {
                ProgressView()
                    .frame(height: 200)
                    .frame(maxWidth: maxWidth)
            } else if loadError {
                errorView
            } else if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth)
                    .cornerRadius(8)
                    .onTapGesture {
                        showFullScreen = true
                    }
                    .accessibilityLabel(mediaRef.alt ?? "Image")
            }

            if let caption = caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: maxWidth, alignment: frameAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .onAppear {
            loadImage()
        }
    }

    // MARK: - Audio View

    @ViewBuilder
    private var audioView: some View {
        ModuleAudioPlayerView(
            mediaRef: mediaRef,
            moduleId: moduleId,
            caption: caption
        )
    }

    // MARK: - Error View

    @ViewBuilder
    private var errorView: some View {
        VStack(spacing: 8) {
            Image(systemName: mediaRef.type == .image ? "photo" : "waveform")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(mediaRef.type == .image ? "Failed to load image" : "Failed to load audio")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(height: 200)
        .frame(maxWidth: maxWidth)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }

    // MARK: - Layout Helpers

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case .left: return .leading
        case .center, .full: return .center
        case .right: return .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .left: return .leading
        case .center, .full: return .center
        case .right: return .trailing
        }
    }

    private var maxWidth: CGFloat? {
        switch alignment {
        case .full: return .infinity
        case .left, .right: return 250
        case .center: return 400
        }
    }

    // MARK: - Image Loading

    private func loadImage() {
        guard mediaRef.type == .image else {
            isLoading = false
            return
        }

        // Found by core's rules for a book's pictures: here, or on the web.
        let url = ModuleMediaStorage.shared.bookMediaURL(for: mediaRef, moduleId: moduleId)
        Task {
            var image: UIImage?
            if let url { image = await ModuleMediaStorage.bookImage(at: url) }
            loadedImage = image
            loadError = image == nil
            isLoading = false
        }
    }
}

/// Audio player component for module media
struct ModuleAudioPlayerView: View {
    let mediaRef: MediaReference
    let moduleId: String
    let caption: String?

    @StateObject private var player = AudioPlayer()

    /// The recording, where a book's pictures are found; one only on the web
    /// can't be played, as the player reads files.
    private var playableURL: URL? {
        ModuleMediaStorage.shared.bookMediaURL(for: mediaRef, moduleId: moduleId).flatMap { $0.isFileURL ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Play/Pause button
                Button {
                    if let url = playableURL {
                        if !player.isLoaded(url: url) {
                            player.load(url: url)
                        }
                        player.togglePlayback()
                    }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    // Waveform or progress bar
                    if let waveform = mediaRef.waveform, !waveform.isEmpty {
                        WaveformView(samples: waveform, progress: player.progress)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        let progress = value.location.x / UIScreen.main.bounds.width * 1.2
                                        player.seek(to: max(0, min(1, progress)))
                                    }
                            )
                    } else {
                        ProgressView(value: player.progress)
                            .progressViewStyle(.linear)
                    }

                    // Time display
                    HStack {
                        Text(AudioPlayer.formatTime(player.currentTime))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Text(AudioPlayer.formatTime(mediaRef.duration ?? player.duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if let caption = caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .onAppear {
            if let url = playableURL {
                player.load(url: url)
            }
        }
        .onDisappear {
            player.pause()
        }
    }
}

/// Full screen image viewer for module media
struct ModuleFullScreenImageView: View {
    let image: UIImage
    let caption: String?
    @Binding var isPresented: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = lastScale * value
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale < 1.0 {
                                    withAnimation {
                                        scale = 1.0
                                        lastScale = 1.0
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation {
                            if scale > 1.0 {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.0
                                lastScale = 2.0
                            }
                        }
                    }

                if let caption = caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding()
                }
            }

            // Close button
            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .statusBar(hidden: true)
    }
}

/// Sheet view for displaying media tapped in commentary/dictionary/notes text
struct ModuleMediaSheet: View {
    let mediaRef: MediaReference
    let moduleId: String
    let caption: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ModuleMediaView(
                    mediaRef: mediaRef,
                    moduleId: moduleId,
                    caption: caption,
                    alignment: .full
                )
                .padding()
            }
            .navigationTitle(mediaRef.type == .image ? "Image" : "Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        ModuleMediaView(
            mediaRef: MediaReference(
                id: "test",
                type: .image,
                filename: "test.jpg",
                mimeType: "image/jpeg"
            ),
            moduleId: "test-module",
            caption: "Test image caption",
            alignment: .center
        )

        ModuleMediaView(
            mediaRef: MediaReference(
                id: "test-audio",
                type: .audio,
                filename: "test.m4a",
                mimeType: "audio/mp4",
                duration: 125.5,
                waveform: (0..<100).map { _ in Float.random(in: 0.1...1.0) }
            ),
            moduleId: "test-module",
            caption: "Test audio caption",
            alignment: .center
        )
    }
    .padding()
}
