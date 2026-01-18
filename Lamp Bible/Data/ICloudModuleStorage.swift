//
//  ICloudModuleStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import CryptoKit

class ICloudModuleStorage: ModuleStorage {
    static let shared = ICloudModuleStorage()

    private let containerIdentifier = "iCloud.com.neus.lamp-bible"
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Container Access

    private var containerURL: URL? {
        fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    private var documentsURL: URL? {
        guard let container = containerURL else { return nil }
        return container.appendingPathComponent("Documents")
    }

    func directoryURL(for type: ModuleType) -> URL? {
        guard let docs = documentsURL else { return nil }
        return docs.appendingPathComponent(directoryName(for: type))
    }

    // MARK: - Availability Check

    func isAvailable() async -> Bool {
        guard fileManager.ubiquityIdentityToken != nil else { return false }
        guard let container = containerURL else { return false }
        return fileManager.fileExists(atPath: container.path)
    }

    // MARK: - Directory Management

    func ensureDirectoryExists(type: ModuleType) async throws {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        if !fileManager.fileExists(atPath: dirURL.path) {
            do {
                try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
            } catch {
                throw ModuleStorageError.directoryCreationFailed
            }
        }
    }

    // MARK: - List Module Files

    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        // Ensure directory exists
        try await ensureDirectoryExists(type: type)

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var moduleFiles: [ModuleFileInfo] = []

        for fileURL in contents {
            let fileName = fileURL.lastPathComponent
            let fileExtension = fileURL.pathExtension.lowercased()

            // Support .lamp (new), .db.zlib (legacy), .db, and .json files
            let isLamp = fileName.hasSuffix(".lamp")
            let isDbZlib = fileName.hasSuffix(".db.zlib")
            guard fileExtension == "json" || fileExtension == "db" || fileExtension == "lamp" || isDbZlib else { continue }

            let id: String
            if fileExtension == "json" {
                id = String(fileName.dropLast(5)) // Remove .json
            } else if isLamp {
                id = String(fileName.dropLast(5)) // Remove .lamp
            } else if isDbZlib {
                id = String(fileName.dropLast(8)) // Remove .db.zlib
            } else {
                id = String(fileName.dropLast(3)) // Remove .db
            }

            let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let hash = try? await calculateHash(at: fileURL)

            moduleFiles.append(ModuleFileInfo(
                id: id,
                type: type,
                filePath: fileName,
                fileHash: hash,
                modificationDate: modDate
            ))
        }

        return moduleFiles
    }

    // MARK: - Read Module File

    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ModuleStorageError.fileNotFound(fileName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var error: NSError?

            coordinator.coordinate(readingItemAt: fileURL, options: [], error: &error) { url in
                do {
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = error {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Write Module File

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        // Ensure directory exists
        try await ensureDirectoryExists(type: type)

        let fileURL = dirURL.appendingPathComponent(fileName)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var error: NSError?

            if fileManager.fileExists(atPath: fileURL.path) {
                // Update existing file
                coordinator.coordinate(writingItemAt: fileURL, options: .forReplacing, error: &error) { url in
                    do {
                        try data.write(to: url)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } else {
                // New file - write to temp then move to iCloud
                let fileExtension = (fileName as NSString).pathExtension
                let tempURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(fileExtension)")

                do {
                    try data.write(to: tempURL)
                    try fileManager.setUbiquitous(true, itemAt: tempURL, destinationURL: fileURL)
                    continuation.resume()
                } catch {
                    // Clean up temp file if it exists
                    try? fileManager.removeItem(at: tempURL)
                    continuation.resume(throwing: error)
                }
            }

            if let error = error {
                continuation.resume(throwing: ModuleStorageError.fileCoordinationFailed)
            }
        }
    }

    // MARK: - Delete Module File

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return // Already deleted
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var error: NSError?

            coordinator.coordinate(writingItemAt: fileURL, options: .forDeleting, error: &error) { url in
                do {
                    try self.fileManager.removeItem(at: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = error {
                continuation.resume(throwing: ModuleStorageError.fileCoordinationFailed)
            }
        }
    }

    // MARK: - File Hash

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try await calculateHash(at: fileURL)
    }

    private func calculateHash(at url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var error: NSError?

            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { url in
                do {
                    let data = try Data(contentsOf: url)
                    let hash = SHA256.hash(data: data)
                    let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
                    continuation.resume(returning: hashString)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = error {
                continuation.resume(throwing: ModuleStorageError.hashCalculationFailed)
            }
        }
    }

    // MARK: - Modification Date

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Clear cached values to get fresh data
        var url = fileURL
        try? url.removeAllCachedResourceValues()

        let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        return resourceValues.contentModificationDate
    }

    // MARK: - Sync Status

    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        guard let dirURL = directoryURL(for: type) else {
            return .notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .notAvailable
        }

        var url = fileURL
        try? url.removeAllCachedResourceValues()

        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .ubiquitousItemIsUploadedKey,
                .ubiquitousItemIsUploadingKey
            ])

            if resourceValues.ubiquitousItemIsUploaded == true {
                return .synced
            } else if resourceValues.ubiquitousItemIsUploading == true {
                return .syncing
            } else {
                return .notSynced
            }
        } catch {
            return .notAvailable
        }
    }
}
