//
//  AudioRecorder.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import Foundation
import AVFoundation
import Combine

/// Observable audio recorder for devotional audio recording
class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordingTime: TimeInterval = 0
    @Published var audioLevel: Float = 0
    @Published var recordingURL: URL?
    @Published var error: Error?
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    override init() {
        super.init()
    }

    deinit {
        stopTimer()
        recorder?.stop()
    }

    // MARK: - Permission

    /// Request microphone permission
    func requestPermission() async -> Bool {
        let status = AVAudioSession.sharedInstance().recordPermission

        switch status {
        case .granted:
            return true
        case .denied:
            await MainActor.run {
                permissionDenied = true
            }
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    Task { @MainActor in
                        self.permissionDenied = !granted
                    }
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Recording Control

    /// Start recording
    func start() {
        Task {
            let granted = await requestPermission()
            guard granted else { return }

            await MainActor.run {
                startRecording()
            }
        }
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            // Generate unique filename
            let filename = UUID().uuidString + ".m4a"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.delegate = self
            recorder?.record()

            recordingURL = url
            isRecording = true
            recordingTime = 0
            error = nil
            startTimer()

        } catch {
            self.error = error
            print("[AudioRecorder] Start error: \(error.localizedDescription)")
        }
    }

    /// Stop recording and keep the file
    func stop() {
        recorder?.stop()
        isRecording = false
        stopTimer()

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Cancel recording and delete the file
    func cancel() {
        recorder?.stop()

        // Delete the recording
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }

        recordingURL = nil
        isRecording = false
        recordingTime = 0
        audioLevel = 0
        stopTimer()

        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Pause recording (iOS 15+)
    func pause() {
        recorder?.pause()
        isRecording = false
        stopTimer()
    }

    /// Resume recording after pause
    func resume() {
        recorder?.record()
        isRecording = true
        startTimer()
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateMeters()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateMeters() {
        guard let recorder = recorder, recorder.isRecording else { return }

        recordingTime = recorder.currentTime
        recorder.updateMeters()

        // Convert dB to 0-1 range
        // Average power typically ranges from -160 dB (silence) to 0 dB (max)
        // We'll use -60 dB as our "silence" threshold for better visualization
        let db = recorder.averagePower(forChannel: 0)
        let normalizedLevel = max(0, min(1, (db + 60) / 60))
        audioLevel = normalizedLevel
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            if !flag {
                self?.error = AudioRecorderError.recordingFailed
            }
            self?.isRecording = false
            self?.stopTimer()
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.error = error ?? AudioRecorderError.encodingFailed
            self?.isRecording = false
            self?.stopTimer()
        }
    }
}

// MARK: - Errors

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case recordingFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is required to record audio"
        case .recordingFailed:
            return "Failed to record audio"
        case .encodingFailed:
            return "Failed to encode audio"
        }
    }
}

// MARK: - Time Formatting

extension AudioRecorder {
    /// Format recording time as mm:ss or h:mm:ss
    static func formatTime(_ time: TimeInterval) -> String {
        AudioPlayer.formatTime(time)
    }
}
