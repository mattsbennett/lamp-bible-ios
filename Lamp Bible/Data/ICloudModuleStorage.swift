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

    // MARK: - List Module Files

    // MARK: - Read Module File

    // MARK: - Write Module File

    // MARK: - Delete Module File

    // MARK: - File Hash

    // MARK: - Modification Date

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

    // MARK: - Generic File Access

    func readFile(path: String) async throws -> Data {
        guard let docsURL = documentsURL else {
            throw ModuleStorageError.notAvailable
        }

        let fileURL = docsURL.appendingPathComponent(path)

        try await downloadIfPlaceholder(at: fileURL)

        return try coordinatedRead(at: fileURL)
    }

    /// Placeholders are listed under their real name and downloaded here, so a
    /// caller that reads what it lists never races the download.
    func listFiles(path: String) async throws -> [StoredFileListing] {
        guard let docsURL = documentsURL else {
            throw ModuleStorageError.notAvailable
        }

        let directoryURL = docsURL.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        )

        var listings: [StoredFileListing] = []
        var listedNames = Set<String>()
        for itemURL in contents {
            guard try itemURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  let fileName = Self.canonicalModuleFilename(itemURL.lastPathComponent),
                  listedNames.insert(fileName).inserted else { continue }

            let fileURL = directoryURL.appendingPathComponent(fileName)
            try await downloadIfPlaceholder(at: fileURL)
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            listings.append(StoredFileListing(
                name: fileName,
                modificationDate: values?.contentModificationDate,
                size: values?.fileSize.map(Int64.init)
            ))
        }
        return listings
    }

}

// MARK: - Design B

extension ICloudModuleStorage {
    /// This storage's iCloud Documents as a library endpoint, or nil while
    /// iCloud is unavailable. Resolving the container can block, so call it
    /// off the main thread.
    func libraryEndpoint() -> ICloudLibraryStorage? {
        documentsURL.map { ICloudLibraryStorage(store: LampSyncDirectoryStore(root: $0)) }
    }
}

/// iCloud Drive for the library pass: core's folder store over the app's
/// iCloud Documents. Evicted files, coordinated access and unresolved
/// versions are handled there, the same on the phone and the Mac.
struct ICloudLibraryStorage: LibraryEndpoint, LampSyncVersionedStore {
    let store: LampSyncDirectoryStore

    var librarySource: String { "icloud:iCloud.com.neus.lamp-bible" }

    // MARK: Remote store

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        try await store.list(directory: directory)
    }
    func read(path: String) async throws -> LampSyncRemoteFile? { try await store.read(path: path) }
    func read(path: String, into url: URL) async throws -> LampSyncDownloadedFile? {
        try await store.read(path: path, into: url)
    }
    func revision(path: String) async throws -> String? { try await store.revision(path: path) }
    func write(_ data: Data, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        try await store.write(data, to: path, condition: condition)
    }
    func write(fileAt url: URL, to path: String, condition: LampSyncWriteCondition) async throws -> String? {
        try await store.write(fileAt: url, to: path, condition: condition)
    }
    func delete(path: String, condition: LampSyncWriteCondition) async throws {
        try await store.delete(path: path, condition: condition)
    }

    // MARK: Versions iCloud kept beside a file instead of refusing a write

    func readWithVersions(
        path: String, into destination: URL
    ) async throws -> (current: LampSyncDownloadedFile?, versions: [LampSyncDownloadedFile]) {
        try await store.readWithVersions(path: path, into: destination)
    }
    func resolveVersions(
        of path: String, writing data: Data, ifRevision revision: String, resolving versions: Set<String>
    ) async throws -> String {
        try await store.resolveVersions(of: path, writing: data, ifRevision: revision, resolving: versions)
    }
    func hasVersions(path: String) async throws -> Bool { try await store.hasVersions(path: path) }

    // MARK: Module storage, as the importers read it

    func isAvailable() async -> Bool { FileManager.default.fileExists(atPath: store.root.path) }

    func readFile(path: String) async throws -> Data {
        guard let file = try await store.read(path: path) else { throw ModuleStorageError.fileNotFound(path) }
        return file.data
    }
    func listFiles(path: String) async throws -> [StoredFileListing] {
        (try await store.list(directory: path) ?? [])
            .filter { !$0.isDirectory }
            .map { StoredFileListing(name: $0.name, modificationDate: $0.modifiedAt, size: $0.size) }
    }
    func directoryURL(for type: ModuleType) -> URL? {
        store.root.appendingPathComponent(directoryName(for: type), isDirectory: true)
    }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus { .notAvailable }
}
