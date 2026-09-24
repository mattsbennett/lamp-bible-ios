//
//  ICloudModuleStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2024-12-30.
//

import Foundation
import LampModuleKit

class ICloudModuleStorage: ModuleStorage {
    static let shared = ICloudModuleStorage()

    private let containerIdentifier = "iCloud.com.neus.lamp-bible"
    private let fileManager: FileManager
    private let documentsURLOverride: URL?
    private let downloadItem: (URL) throws -> Void

    init(
        documentsURL: URL? = nil,
        fileManager: FileManager = .default,
        downloadItem: ((URL) throws -> Void)? = nil
    ) {
        documentsURLOverride = documentsURL
        self.fileManager = fileManager
        self.downloadItem = downloadItem ?? {
            try fileManager.startDownloadingUbiquitousItem(at: $0)
        }
    }

    private static func canonicalModuleFilename(_ name: String) -> String? {
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            return String(name.dropFirst().dropLast(".icloud".count))
        }
        return name.hasPrefix(".") ? nil : name
    }

    private func placeholderURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).icloud")
    }

    private func downloadIfPlaceholder(at fileURL: URL) async throws {
        if fileManager.fileExists(atPath: fileURL.path) { return }
        guard fileManager.fileExists(atPath: placeholderURL(for: fileURL).path) else {
            throw ModuleStorageError.fileNotFound(fileURL.lastPathComponent)
        }
        try downloadItem(fileURL)
        for _ in 0..<60 {
            if fileManager.fileExists(atPath: fileURL.path) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ModuleStorageError.notAvailable
    }

    private func ensureNoUnresolvedVersions(at url: URL) throws {
        if NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty == false {
            throw ModuleStorageError.unresolvedVersions
        }
    }

    private func coordinatedRead(at fileURL: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: fileURL, options: [], error: &coordinationError) { url in
            result = Result {
                try ensureNoUnresolvedVersions(at: url)
                return try Data(contentsOf: url)
            }
        }
        if let result { return try result.get() }
        throw (coordinationError as Error?) ?? ModuleStorageError.fileCoordinationFailed
    }

    private func coordinatedWrite(
        at fileURL: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: fileURL, options: options, error: &coordinationError) { url in
            result = Result {
                try ensureNoUnresolvedVersions(at: url)
                try body(url)
            }
        }
        if let result { return try result.get() }
        throw (coordinationError as Error?) ?? ModuleStorageError.fileCoordinationFailed
    }

    // MARK: - Container Access

    private var containerURL: URL? {
        fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    private var documentsURL: URL? {
        if let documentsURLOverride { return documentsURLOverride }
        guard let container = containerURL else { return nil }
        return container.appendingPathComponent("Documents")
    }

    /// Inspect existing iCloud content without creating directories or files.
    func probeExistingContent() -> ICloudContentState {
        guard fileManager.ubiquityIdentityToken != nil else {
            return .unavailable
        }
        guard let documentsURL else {
            return .unavailable
        }
        return Self.inspectExistingContent(
            documentsURL: documentsURL,
            fileManager: fileManager
        )
    }

    static func inspectExistingContent(
        documentsURL: URL,
        fileManager: FileManager = .default
    ) -> ICloudContentState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: documentsURL.path, isDirectory: &isDirectory) else {
            return .empty
        }
        guard isDirectory.boolValue else {
            return .unavailable
        }

        let userSettingsNames = [
            "user-settings.db",
            ".user-settings.db.icloud"
        ]
        let userDataURL = documentsURL.appendingPathComponent("UserData")
        if userSettingsNames.contains(where: {
            fileManager.fileExists(atPath: userDataURL.appendingPathComponent($0).path)
        }) {
            return .hasContent
        }

        let moduleDirectories = [
            "Translations",
            "Dictionaries",
            "Commentaries",
            "Devotionals",
            "Notes",
            "Plans",
            "Highlights",
            "Quizzes"
        ]

        for directoryName in moduleDirectories {
            let directoryURL = documentsURL.appendingPathComponent(directoryName)
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                continue
            }

            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: []
                )
            } catch {
                return .unavailable
            }

            if contents.contains(where: isMeaningfulModuleFile) {
                return .hasContent
            }
        }

        return .empty
    }

    private static func isMeaningfulModuleFile(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return false
        }

        var fileName = url.lastPathComponent.lowercased()
        if fileName.hasPrefix("."), fileName.hasSuffix(".icloud") {
            fileName.removeFirst()
            fileName.removeLast(".icloud".count)
        }

        return fileName.hasSuffix(".json")
            || fileName.hasSuffix(".db")
            || fileName.hasSuffix(".db.zlib")
            || fileName.hasSuffix(".lamp")
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

        let contents = try fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        )

        var moduleFiles: [ModuleFileInfo] = []
        var listedNames = Set<String>()

        for itemURL in contents {
            guard try itemURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            guard let fileName = Self.canonicalModuleFilename(itemURL.lastPathComponent),
                  listedNames.insert(fileName).inserted else { continue }
            guard let id = LampSyncModuleFiles.moduleID(from: fileName) else { continue }

            let fileURL = dirURL.appendingPathComponent(fileName)
            try await downloadIfPlaceholder(at: fileURL)
            let modDate = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let hash = try await calculateHash(at: fileURL)

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

        try await downloadIfPlaceholder(at: fileURL)

        return try coordinatedRead(at: fileURL)
    }

    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        LampSyncModuleRead.content(
            try await readModuleFile(type: type, fileName: fileName)
        )
    }

    // MARK: - Write Module File

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        try await writeModuleFile(
            type: type, fileName: fileName, data: data,
            matching: nil, enforceMatch: false
        )
    }

    /// Rechecks the observed body inside the coordinated write callback.
    /// Another device can still upload a version after local coordination.
    func writeModuleFile(
        type: ModuleType,
        fileName: String,
        data: Data,
        matching expectedDigest: String?
    ) async throws {
        try await writeModuleFile(
            type: type, fileName: fileName, data: data,
            matching: expectedDigest, enforceMatch: true
        )
    }

    private func writeModuleFile(
        type: ModuleType,
        fileName: String,
        data: Data,
        matching expectedDigest: String?,
        enforceMatch: Bool
    ) async throws {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        // Ensure directory exists
        try await ensureDirectoryExists(type: type)

        let fileURL = dirURL.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: fileURL.path)
            || fileManager.fileExists(atPath: placeholderURL(for: fileURL).path) {
            try await downloadIfPlaceholder(at: fileURL)
            try coordinatedWrite(at: fileURL, options: []) { url in
                if enforceMatch {
                    let observed = try Data(contentsOf: url)
                    guard LampSyncContentRevision.matchesDigest(
                        expectedDigest, observed: observed
                    ) else { throw SyncError.conflictDetected }
                }
                try data.write(to: url)
            }
        } else {
            guard !enforceMatch || expectedDigest == nil else {
                throw SyncError.conflictDetected
            }
            // New ubiquitous files must be moved from a local temporary URL.
            let fileExtension = (fileName as NSString).pathExtension
            let tempURL = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".\(fileExtension)")
            do {
                try data.write(to: tempURL)
                if enforceMatch && (
                    fileManager.fileExists(atPath: fileURL.path)
                        || fileManager.fileExists(atPath: placeholderURL(for: fileURL).path)
                ) {
                    throw SyncError.conflictDetected
                }
                try fileManager.setUbiquitous(true, itemAt: tempURL, destinationURL: fileURL)
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw error
            }
        }
    }

    // MARK: - Delete Module File

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path)
            || fileManager.fileExists(atPath: placeholderURL(for: fileURL).path) else {
            return // Already deleted
        }
        try await downloadIfPlaceholder(at: fileURL)

        try coordinatedWrite(at: fileURL, options: .forDeleting) { url in
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - File Hash

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path)
            || fileManager.fileExists(atPath: placeholderURL(for: fileURL).path) else {
            return nil
        }
        try await downloadIfPlaceholder(at: fileURL)

        return try await calculateHash(at: fileURL)
    }

    private func calculateHash(at url: URL) async throws -> String {
        let data = try coordinatedRead(at: url)
        return LampSyncContentRevision.digest(for: data)
    }

    // MARK: - Modification Date

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? {
        guard let dirURL = directoryURL(for: type) else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = dirURL.appendingPathComponent(fileName)

        guard fileManager.fileExists(atPath: fileURL.path)
            || fileManager.fileExists(atPath: placeholderURL(for: fileURL).path) else {
            return nil
        }
        try await downloadIfPlaceholder(at: fileURL)

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

    // MARK: - Change Token

    func getChangeToken(path: String) async -> String? {
        guard let data = try? await readFile(path: path) else { return nil }
        return LampSyncContentRevision.token(for: data)
    }

    // MARK: - Generic File Access

    func readFile(path: String) async throws -> Data {
        guard let docsURL = documentsURL else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = docsURL.appendingPathComponent(path)

        try await downloadIfPlaceholder(at: fileURL)

        return try coordinatedRead(at: fileURL)
    }

    func writeFile(path: String, data: Data) async throws {
        try await writeFile(path: path, data: data, matching: nil, enforceMatch: false)
    }

    func writeFile(path: String, data: Data, matching expectedToken: String?) async throws {
        try await writeFile(
            path: path, data: data, matching: expectedToken, enforceMatch: true
        )
    }

    func writeFileIfAbsentOrUnchanged(path: String, data: Data) async throws {
        let observed: Data?
        do {
            observed = try await readFile(path: path)
        } catch ModuleStorageError.fileNotFound {
            observed = nil
        }
        guard LampSyncContentRevision.allowsUnbasedWrite(data, over: observed) else {
            throw SyncError.conflictDetected
        }
        try await writeFile(
            path: path, data: data,
            matching: observed.map(LampSyncContentRevision.token(for:))
        )
    }

    private func writeFile(
        path: String,
        data: Data,
        matching expectedToken: String?,
        enforceMatch: Bool
    ) async throws {
        guard let docsURL = documentsURL else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = docsURL.appendingPathComponent(path)

        // Create parent directory if needed
        let parentDir = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

        try coordinatedWrite(at: fileURL, options: .forReplacing) { url in
            if enforceMatch {
                guard !fileManager.fileExists(atPath: placeholderURL(for: url).path) else {
                    throw SyncError.conflictDetected
                }
                let observed = fileManager.fileExists(atPath: url.path)
                    ? try Data(contentsOf: url) : nil
                guard LampSyncContentRevision.matchesToken(
                    expectedToken, observed: observed
                ) else { throw SyncError.conflictDetected }
            }
            try data.write(to: url, options: .atomic)
        }
    }
}
