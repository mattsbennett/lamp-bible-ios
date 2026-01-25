//
//  DevotionalMediaStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import Foundation
import UIKit
import AVFoundation
import Accelerate

/// Manages storage and retrieval of media files for devotionals
class DevotionalMediaStorage {
    static let shared = DevotionalMediaStorage()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Directory Management

    /// Get the base media directory in Documents
    private var mediaBaseDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DevotionalMedia")
    }

    /// Get the media directory for a specific module
    func mediaDirectory(moduleId: String) -> URL {
        mediaBaseDirectory.appendingPathComponent(moduleId)
    }

    /// Get the media directory for a specific devotional
    func mediaDirectory(devotionalId: String, moduleId: String) -> URL {
        mediaDirectory(moduleId: moduleId).appendingPathComponent(devotionalId)
    }

    /// Ensure the media directory exists for a devotional
    func ensureMediaDirectory(devotionalId: String, moduleId: String) throws {
        let dir = mediaDirectory(devotionalId: devotionalId, moduleId: moduleId)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - File Path Helpers

    /// Get the local file URL for a media reference
    func getMediaURL(for mediaRef: DevotionalMediaReference, devotionalId: String, moduleId: String) -> URL? {
        let dir = mediaDirectory(devotionalId: devotionalId, moduleId: moduleId)
        let fileURL = dir.appendingPathComponent(mediaRef.filename)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Get the expected file URL for a media reference (may not exist yet)
    func expectedMediaURL(for mediaRef: DevotionalMediaReference, devotionalId: String, moduleId: String) -> URL {
        mediaDirectory(devotionalId: devotionalId, moduleId: moduleId).appendingPathComponent(mediaRef.filename)
    }

    // MARK: - Image Operations

    /// Save an image and create a media reference
    func saveImage(
        _ image: UIImage,
        id: String = UUID().uuidString,
        devotionalId: String,
        moduleId: String,
        quality: CGFloat = 0.8
    ) throws -> DevotionalMediaReference {
        try ensureMediaDirectory(devotionalId: devotionalId, moduleId: moduleId)

        // Determine format and data
        let filename: String
        let data: Data
        let mimeType: String

        if let pngData = image.pngData(), image.hasTransparency {
            filename = "\(id).png"
            data = pngData
            mimeType = "image/png"
        } else if let jpegData = image.jpegData(compressionQuality: quality) {
            filename = "\(id).jpg"
            data = jpegData
            mimeType = "image/jpeg"
        } else {
            throw MediaStorageError.encodingFailed
        }

        // Write to file
        let fileURL = mediaDirectory(devotionalId: devotionalId, moduleId: moduleId).appendingPathComponent(filename)
        try data.write(to: fileURL)

        return DevotionalMediaReference(
            id: id,
            type: .image,
            filename: filename,
            mimeType: mimeType,
            size: data.count,
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale)
        )
    }

    /// Load an image from a media reference
    func loadImage(for mediaRef: DevotionalMediaReference, devotionalId: String, moduleId: String) -> UIImage? {
        guard let url = getMediaURL(for: mediaRef, devotionalId: devotionalId, moduleId: moduleId) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Audio Operations

    /// Save an audio file and create a media reference
    func saveAudio(
        from sourceURL: URL,
        id: String = UUID().uuidString,
        devotionalId: String,
        moduleId: String,
        generateWaveform: Bool = true
    ) async throws -> DevotionalMediaReference {
        try ensureMediaDirectory(devotionalId: devotionalId, moduleId: moduleId)

        // Determine filename and mime type
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let filename: String
        let mimeType: String

        switch sourceExtension {
        case "m4a":
            filename = "\(id).m4a"
            mimeType = "audio/mp4"
        case "mp3":
            filename = "\(id).mp3"
            mimeType = "audio/mpeg"
        case "wav":
            filename = "\(id).wav"
            mimeType = "audio/wav"
        case "aac":
            filename = "\(id).aac"
            mimeType = "audio/aac"
        default:
            filename = "\(id).m4a"
            mimeType = "audio/mp4"
        }

        // Copy to destination
        let destURL = mediaDirectory(devotionalId: devotionalId, moduleId: moduleId).appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)

        // Get file size
        let attributes = try fileManager.attributesOfItem(atPath: destURL.path)
        let size = attributes[.size] as? Int

        // Extract audio metadata
        let (duration, waveform) = try await extractAudioMetadata(from: destURL, generateWaveform: generateWaveform)

        return DevotionalMediaReference(
            id: id,
            type: .audio,
            filename: filename,
            mimeType: mimeType,
            size: size,
            duration: duration,
            waveform: waveform
        )
    }

    /// Extract duration and optionally generate waveform from audio file
    private func extractAudioMetadata(from url: URL, generateWaveform: Bool) async throws -> (duration: Double, waveform: [Float]?) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        var waveform: [Float]? = nil
        if generateWaveform {
            waveform = try await generateWaveformData(from: url)
        }

        return (durationSeconds, waveform)
    }

    /// Generate waveform data from audio file
    func generateWaveformData(from audioURL: URL, samples: Int = 100) async throws -> [Float] {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw MediaStorageError.waveformGenerationFailed
        }

        try file.read(into: buffer)

        guard let floatData = buffer.floatChannelData?[0] else {
            throw MediaStorageError.waveformGenerationFailed
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return Array(repeating: 0, count: samples)
        }

        let samplesPerBucket = max(1, frameLength / samples)
        var waveform: [Float] = []

        for i in 0..<samples {
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, frameLength)
            guard start < frameLength else { break }

            // Calculate RMS for this bucket
            var sum: Float = 0
            let slice = UnsafeBufferPointer(start: floatData + start, count: end - start)
            vDSP_svesq(slice.baseAddress!, 1, &sum, vDSP_Length(slice.count))
            let rms = sqrt(sum / Float(slice.count))

            // Normalize to 0-1 range (assuming max RMS of ~0.5)
            waveform.append(min(1, rms * 2))
        }

        // Pad if needed
        while waveform.count < samples {
            waveform.append(0)
        }

        return waveform
    }

    // MARK: - Delete Operations

    /// Delete a media file
    func deleteMedia(_ mediaRef: DevotionalMediaReference, devotionalId: String, moduleId: String) throws {
        let url = expectedMediaURL(for: mediaRef, devotionalId: devotionalId, moduleId: moduleId)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Delete all media for a devotional
    func deleteAllMedia(devotionalId: String, moduleId: String) throws {
        let dir = mediaDirectory(devotionalId: devotionalId, moduleId: moduleId)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    /// Delete all media for a module
    func deleteAllMedia(moduleId: String) throws {
        let dir = mediaDirectory(moduleId: moduleId)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Cloud Sync Helpers

    /// Get the iCloud media directory for a module
    func iCloudMediaDirectory(moduleId: String) -> URL? {
        guard let container = fileManager.url(forUbiquityContainerIdentifier: "iCloud.com.neus.lamp-bible") else {
            return nil
        }
        return container.appendingPathComponent("Documents/Devotionals/\(moduleId)/media")
    }

    /// Upload a media file to iCloud
    func uploadMediaToCloud(_ mediaRef: DevotionalMediaReference, devotionalId: String, moduleId: String) async throws {
        guard let cloudDir = iCloudMediaDirectory(moduleId: moduleId) else {
            throw MediaStorageError.cloudNotAvailable
        }

        guard let localURL = getMediaURL(for: mediaRef, devotionalId: devotionalId, moduleId: moduleId) else {
            throw MediaStorageError.fileNotFound
        }

        // Ensure cloud directory exists
        if !fileManager.fileExists(atPath: cloudDir.path) {
            try fileManager.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        }

        let cloudURL = cloudDir.appendingPathComponent(mediaRef.filename)

        // Copy to cloud (setUbiquitous for new files)
        if fileManager.fileExists(atPath: cloudURL.path) {
            try fileManager.removeItem(at: cloudURL)
        }

        // Use temp file for setUbiquitous
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(mediaRef.filename)
        try fileManager.copyItem(at: localURL, to: tempURL)
        try fileManager.setUbiquitous(true, itemAt: tempURL, destinationURL: cloudURL)
    }

    /// Download a media file from iCloud to local cache
    func downloadMediaFromCloud(_ mediaRef: DevotionalMediaReference, devotionalId: String, moduleId: String) async throws {
        guard let cloudDir = iCloudMediaDirectory(moduleId: moduleId) else {
            throw MediaStorageError.cloudNotAvailable
        }

        let cloudURL = cloudDir.appendingPathComponent(mediaRef.filename)
        guard fileManager.fileExists(atPath: cloudURL.path) else {
            throw MediaStorageError.fileNotFound
        }

        try ensureMediaDirectory(devotionalId: devotionalId, moduleId: moduleId)
        let localURL = expectedMediaURL(for: mediaRef, devotionalId: devotionalId, moduleId: moduleId)

        if fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
        }
        try fileManager.copyItem(at: cloudURL, to: localURL)
    }

    // MARK: - Utilities

    /// Calculate total size of all media for a devotional
    func calculateTotalSize(devotionalId: String, moduleId: String) -> Int {
        let dir = mediaDirectory(devotionalId: devotionalId, moduleId: moduleId)
        guard fileManager.fileExists(atPath: dir.path) else { return 0 }

        var totalSize = 0
        if let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += size
                }
            }
        }
        return totalSize
    }
}

// MARK: - Errors

enum MediaStorageError: LocalizedError {
    case encodingFailed
    case waveformGenerationFailed
    case fileNotFound
    case cloudNotAvailable

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode image"
        case .waveformGenerationFailed:
            return "Failed to generate audio waveform"
        case .fileNotFound:
            return "Media file not found"
        case .cloudNotAvailable:
            return "iCloud is not available"
        }
    }
}

// MARK: - UIImage Extension

private extension UIImage {
    var hasTransparency: Bool {
        guard let cgImage = self.cgImage else { return false }
        let alphaInfo = cgImage.alphaInfo
        return alphaInfo == .first || alphaInfo == .last ||
               alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
    }
}
