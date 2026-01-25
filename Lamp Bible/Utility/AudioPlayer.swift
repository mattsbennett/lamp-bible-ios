//
//  AudioPlayer.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import Foundation
import AVFoundation
import Combine

/// Observable audio player for devotional audio blocks
class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var error: Error?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    override init() {
        super.init()
    }

    deinit {
        stopTimer()
        player?.stop()
    }

    // MARK: - Loading

    /// Load audio from a URL
    func load(url: URL) {
        // Don't reload if already loaded
        if loadedURL == url && player != nil {
            return
        }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            duration = player?.duration ?? 0
            loadedURL = url
            error = nil

            // Reset state
            currentTime = 0
            progress = 0
            isPlaying = false
        } catch {
            self.error = error
            print("[AudioPlayer] Load error: \(error.localizedDescription)")
        }
    }

    /// Check if a URL is currently loaded
    func isLoaded(url: URL) -> Bool {
        return loadedURL == url && player != nil
    }

    // MARK: - Playback Control

    /// Toggle between play and pause
    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Start or resume playback
    func play() {
        guard let player = player else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioPlayer] Audio session error: \(error.localizedDescription)")
        }

        player.play()
        isPlaying = true
        startTimer()
    }

    /// Pause playback
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    /// Stop playback and reset to beginning
    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        stopTimer()
        currentTime = 0
        progress = 0
    }

    // MARK: - Seeking

    /// Seek to a specific progress (0-1)
    func seek(to progress: Double) {
        guard let player = player else { return }
        let clampedProgress = max(0, min(1, progress))
        let time = duration * clampedProgress
        player.currentTime = time
        updateProgress()
    }

    /// Seek to a specific time in seconds
    func seek(toTime time: TimeInterval) {
        guard let player = player else { return }
        let clampedTime = max(0, min(duration, time))
        player.currentTime = clampedTime
        updateProgress()
    }

    /// Skip forward by a number of seconds
    func skipForward(seconds: TimeInterval = 15) {
        seek(toTime: currentTime + seconds)
    }

    /// Skip backward by a number of seconds
    func skipBackward(seconds: TimeInterval = 15) {
        seek(toTime: currentTime - seconds)
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player = player else { return }
        currentTime = player.currentTime
        progress = duration > 0 ? currentTime / duration : 0
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isPlaying = false
            self?.stopTimer()
            self?.progress = 1.0
            self?.currentTime = self?.duration ?? 0
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.error = error
            self?.isPlaying = false
            self?.stopTimer()
        }
    }
}

// MARK: - Time Formatting

extension AudioPlayer {
    /// Format a time interval as mm:ss or h:mm:ss
    static func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }

        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
