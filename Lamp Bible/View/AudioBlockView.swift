//
//  AudioBlockView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import SwiftUI

/// Displays an audio block within a devotional
struct AudioBlockView: View {
    let block: DevotionalContentBlock
    let mediaRef: DevotionalMediaReference?
    let audioURL: URL?
    let showWaveform: Bool

    @StateObject private var player = AudioPlayer()
    @State private var showFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Play/Pause button
                Button {
                    if let url = audioURL, !player.isLoaded(url: url) {
                        player.load(url: url)
                    }
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    // Waveform or progress bar
                    if showWaveform, let waveform = mediaRef?.waveform, !waveform.isEmpty {
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
                        Text(AudioPlayer.formatTime(mediaRef?.duration ?? player.duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if let caption = block.caption {
                DevotionalAnnotatedTextView(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .onAppear {
            if let url = audioURL {
                player.load(url: url)
            }
        }
        .onDisappear {
            player.pause()
        }
    }
}

/// Compact audio player for list views
struct CompactAudioBlockView: View {
    let mediaRef: DevotionalMediaReference?
    let audioURL: URL?

    @StateObject private var player = AudioPlayer()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let url = audioURL, !player.isLoaded(url: url) {
                    player.load(url: url)
                }
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            if let waveform = mediaRef?.waveform, !waveform.isEmpty {
                MiniWaveformView(samples: waveform)
                    .frame(height: 20)
            } else {
                ProgressView(value: player.progress)
                    .progressViewStyle(.linear)
            }

            Text(AudioPlayer.formatTime(mediaRef?.duration ?? 0))
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .onAppear {
            if let url = audioURL {
                player.load(url: url)
            }
        }
    }
}

/// Audio player with autoplay support for present mode
struct PresentModeAudioBlockView: View {
    let block: DevotionalContentBlock
    let mediaRef: DevotionalMediaReference?
    let audioURL: URL?

    @StateObject private var player = AudioPlayer()
    @State private var hasAutoPlayed = false

    var body: some View {
        AudioBlockView(
            block: block,
            mediaRef: mediaRef,
            audioURL: audioURL,
            showWaveform: block.showWaveform ?? true
        )
        .onAppear {
            if block.autoplay == true && !hasAutoPlayed {
                hasAutoPlayed = true
                if let url = audioURL {
                    player.load(url: url)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        player.play()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        AudioBlockView(
            block: DevotionalContentBlock(type: .audio, mediaId: "test"),
            mediaRef: DevotionalMediaReference(
                id: "test",
                type: .audio,
                filename: "test.m4a",
                mimeType: "audio/mp4",
                duration: 125.5,
                waveform: (0..<100).map { _ in Float.random(in: 0.1...1.0) }
            ),
            audioURL: nil,
            showWaveform: true
        )

        CompactAudioBlockView(
            mediaRef: DevotionalMediaReference(
                id: "test",
                type: .audio,
                filename: "test.m4a",
                mimeType: "audio/mp4",
                duration: 65.0,
                waveform: (0..<50).map { _ in Float.random(in: 0.1...1.0) }
            ),
            audioURL: nil
        )
    }
    .padding()
}
