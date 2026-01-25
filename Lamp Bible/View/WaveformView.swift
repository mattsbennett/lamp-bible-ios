//
//  WaveformView.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import SwiftUI

/// Displays an audio waveform visualization
struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    var playedColor: Color = .accentColor
    var unplayedColor: Color = Color.gray.opacity(0.3)
    var barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: barSpacing) {
                ForEach(0..<samples.count, id: \.self) { index in
                    let height = CGFloat(samples[index]) * geometry.size.height
                    let progressIndex = Int(progress * Double(samples.count))

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(index < progressIndex ? playedColor : unplayedColor)
                        .frame(width: barWidth(geometry: geometry), height: max(4, height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func barWidth(geometry: GeometryProxy) -> CGFloat {
        let totalSpacing = CGFloat(max(0, samples.count - 1)) * barSpacing
        let availableWidth = geometry.size.width - totalSpacing
        return max(2, availableWidth / CGFloat(max(1, samples.count)))
    }
}

/// Live waveform visualization during recording
struct LiveWaveformView: View {
    let level: Float
    var color: Color = .accentColor
    var barCount: Int = 30

    @State private var levels: [Float] = []

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let sampleLevel = index < levels.count ? levels[index] : 0
                    let height = CGFloat(sampleLevel) * geometry.size.height

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(width: barWidth(geometry: geometry), height: max(4, height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onChange(of: level) { _, newLevel in
            updateLevels(newLevel)
        }
        .onAppear {
            levels = Array(repeating: 0, count: barCount)
        }
    }

    private func barWidth(geometry: GeometryProxy) -> CGFloat {
        let totalSpacing = CGFloat(max(0, barCount - 1)) * 2
        let availableWidth = geometry.size.width - totalSpacing
        return max(2, availableWidth / CGFloat(barCount))
    }

    private func updateLevels(_ newLevel: Float) {
        // Shift all values left and add new level at the end
        if levels.count >= barCount {
            levels.removeFirst()
        }
        levels.append(newLevel)
    }
}

/// Miniature waveform for compact display
struct MiniWaveformView: View {
    let samples: [Float]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(0..<min(samples.count, 50), id: \.self) { index in
                    let sampleIndex = index * samples.count / 50
                    let height = CGFloat(samples[sampleIndex]) * geometry.size.height

                    Rectangle()
                        .fill(color)
                        .frame(width: 2, height: max(2, height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Preview

#Preview("Static Waveform") {
    let samples: [Float] = (0..<100).map { _ in Float.random(in: 0.1...1.0) }
    return WaveformView(samples: samples, progress: 0.4)
        .frame(height: 60)
        .padding()
}

#Preview("Live Waveform") {
    LiveWaveformView(level: 0.5)
        .frame(height: 60)
        .padding()
}
