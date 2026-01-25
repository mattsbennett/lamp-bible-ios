//
//  ModuleMediaStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-19.
//

import Foundation
import UIKit
import AVFoundation
import Accelerate

/// Handles media file storage for all module types (commentaries, dictionaries, notes)
/// Media files are stored in a local cache directory and can be synced to/from cloud storage
class ModuleMediaStorage {
    static let shared = ModuleMediaStorage()

    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Directory Management

    /// Base directory for all module media cache
    private var mediaBaseDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ModuleMediaCache")
    }

    /// Get the media directory for a specific module
    func mediaDirectory(for moduleId: String) -> URL {
        return mediaBaseDirectory.appendingPathComponent(moduleId)
    }

    /// Ensure media directory exists for a module
    func ensureMediaDirectory(for moduleId: String) throws {
        let dir = mediaDirectory(for: moduleId)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: - File Access

    /// Get the local file URL for a media reference
    /// Returns nil if the file doesn't exist locally
    func getMediaURL(for mediaRef: MediaReference, moduleId: String) -> URL? {
        let fileURL = mediaDirectory(for: moduleId).appendingPathComponent(mediaRef.filename)
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }

    /// Get the expected local file URL for a media reference (may not exist yet)
    func expectedMediaURL(for mediaRef: MediaReference, moduleId: String) -> URL {
        return mediaDirectory(for: moduleId).appendingPathComponent(mediaRef.filename)
    }

    // MARK: - Image Operations

    /// Save an image and return a MediaReference
    func saveImage(
        _ image: UIImage,
        id: String = UUID().uuidString,
        moduleId: String,
        quality: CGFloat = 0.8
    ) throws -> MediaReference {
        try ensureMediaDirectory(for: moduleId)

        let filename = "\(id).jpg"
        let fileURL = mediaDirectory(for: moduleId).appendingPathComponent(filename)

        guard let data = image.jpegData(compressionQuality: quality) else {
            throw ModuleMediaError.imageConversionFailed
        }

        try data.write(to: fileURL)

        return MediaReference(
            id: id,
            type: .image,
            filename: filename,
            mimeType: "image/jpeg",
            size: data.count,
            width: Int(image.size.width * image.scale),
            height: Int(image.size.height * image.scale),
            created: Int(Date().timeIntervalSince1970)
        )
    }

    /// Load an image from a media reference
    func loadImage(for mediaRef: MediaReference, moduleId: String) -> UIImage? {
        guard let url = getMediaURL(for: mediaRef, moduleId: moduleId) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    // MARK: - Audio Operations

    /// Save an audio file and return a MediaReference with waveform
    func saveAudio(
        from sourceURL: URL,
        id: String = UUID().uuidString,
        moduleId: String,
        generateWaveform: Bool = true
    ) async throws -> MediaReference {
        try ensureMediaDirectory(for: moduleId)

        let ext = sourceURL.pathExtension.lowercased()
        let mimeType = mimeTypeForExtension(ext)
        let filename = "\(id).\(ext)"
        let destURL = mediaDirectory(for: moduleId).appendingPathComponent(filename)

        // Copy the file
        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)

        // Get file size
        let attributes = try fileManager.attributesOfItem(atPath: destURL.path)
        let size = attributes[.size] as? Int

        // Extract audio metadata
        let duration = try await getAudioDuration(from: destURL)

        // Generate waveform if requested
        var waveform: [Float]? = nil
        if generateWaveform {
            waveform = try? await generateWaveformSamples(from: destURL)
        }

        return MediaReference(
            id: id,
            type: .audio,
            filename: filename,
            mimeType: mimeType,
            size: size,
            duration: duration,
            waveform: waveform,
            created: Int(Date().timeIntervalSince1970)
        )
    }

    /// Get audio duration
    private func getAudioDuration(from url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// Generate waveform samples from an audio file
    func generateWaveformSamples(from audioURL: URL, sampleCount: Int = 100) async throws -> [Float] {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ModuleMediaError.waveformGenerationFailed
        }

        try file.read(into: buffer)

        guard let floatData = buffer.floatChannelData?[0] else {
            throw ModuleMediaError.waveformGenerationFailed
        }

        let frameLength = Int(buffer.frameLength)
        let samplesPerBucket = frameLength / sampleCount

        guard samplesPerBucket > 0 else {
            return Array(repeating: 0.5, count: sampleCount)
        }

        var waveform: [Float] = []

        for i in 0..<sampleCount {
            let start = i * samplesPerBucket
            let end = min(start + samplesPerBucket, frameLength)
            let slice = Array(UnsafeBufferPointer(start: floatData + start, count: end - start))

            // RMS of this bucket
            var sum: Float = 0
            vDSP_svesq(slice, 1, &sum, vDSP_Length(slice.count))
            let rms = sqrt(sum / Float(slice.count))

            // Normalize to 0-1 range (assuming max RMS of ~0.5)
            waveform.append(min(1, rms * 2))
        }

        return waveform
    }

    // MARK: - Deletion

    /// Delete a media file
    func deleteMedia(_ mediaRef: MediaReference, moduleId: String) throws {
        let url = expectedMediaURL(for: mediaRef, moduleId: moduleId)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Delete all media for a module
    func deleteAllMedia(for moduleId: String) throws {
        let dir = mediaDirectory(for: moduleId)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    // MARK: - Import from Bundle

    /// Import media files from a bundle (e.g., .lamp file) into local storage
    func importMediaFromBundle(
        bundleMediaDir: URL,
        mediaRefs: [MediaReference],
        moduleId: String
    ) throws {
        try ensureMediaDirectory(for: moduleId)

        for mediaRef in mediaRefs {
            let sourceURL = bundleMediaDir.appendingPathComponent(mediaRef.filename)
            let destURL = expectedMediaURL(for: mediaRef, moduleId: moduleId)

            if fileManager.fileExists(atPath: sourceURL.path) {
                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destURL)
            }
        }
    }

    /// Export media files to a directory for bundling
    func exportMediaToDirectory(
        mediaRefs: [MediaReference],
        moduleId: String,
        targetDir: URL
    ) throws {
        for mediaRef in mediaRefs {
            guard let sourceURL = getMediaURL(for: mediaRef, moduleId: moduleId) else {
                continue
            }

            let destURL = targetDir.appendingPathComponent(mediaRef.filename)
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destURL)
        }
    }

    // MARK: - Helpers

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Errors

enum ModuleMediaError: Error, LocalizedError {
    case imageConversionFailed
    case waveformGenerationFailed
    case fileNotFound
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            return "Failed to convert image to JPEG format"
        case .waveformGenerationFailed:
            return "Failed to generate audio waveform"
        case .fileNotFound:
            return "Media file not found"
        case .importFailed(let reason):
            return "Media import failed: \(reason)"
        }
    }
}
