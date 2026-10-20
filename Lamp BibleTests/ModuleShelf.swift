//
//  ModuleShelf.swift
//  Lamp BibleTests
//
//  Somewhere for a published module to go, and to be read back from, so a
//  round trip can be exercised without a real backend.
//

import Foundation
import LampCore
import LampModuleKit
import XCTest
@testable import Lamp_Bible

/// A backend's worth of files, held in memory. Revisions behave the way a real
/// backend's do: a new one on every write, plus `reissueRevision` for the case
/// these suites care about — the same bytes offered under a revision this
/// device has not recorded, which is what a second device republishing looks
/// like from here.
actor ModuleShelf {
    private var files: [String: Data] = [:]
    private var revisions: [String: String] = [:]
    private var issued = 0
    private var writes = 0

    func write(_ data: Data, named name: String) {
        writes += 1
        files[name] = data
        revisions[name] = nextRevision()
    }

    func reissueRevision(for name: String) {
        guard files[name] != nil else { return }
        revisions[name] = nextRevision()
    }

    func data(named name: String) -> Data? { files[name] }
    func revision(named name: String) -> String? { revisions[name] }
    func names() -> [String] { files.keys.sorted() }
    func writeCount() -> Int { writes }

    private func nextRevision() -> String {
        issued += 1
        return "revision-\(issued)"
    }
}

/// The one module file a shelf offers, plus whatever media is written beside it.
struct ShelfStorage: ModuleStorage {
    let shelf: ModuleShelf
    let moduleID: String
    let moduleType: ModuleType
    /// Publishing writes `<id>.lamp`, so a suite serving another form — the
    /// legacy JSON, say — names it rather than letting the listing pick up
    /// whatever a publish left behind.
    var fileName: String? = nil

    private var listedName: String { fileName ?? "\(moduleID).lamp" }

    func isAvailable() async -> Bool { true }

    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        guard type == moduleType, await shelf.data(named: listedName) != nil else {
            return []
        }
        return [ModuleFileInfo(
            id: moduleID,
            type: moduleType,
            filePath: listedName,
            fileHash: await shelf.revision(named: listedName),
            modificationDate: nil
        )]
    }

    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        guard let data = await shelf.data(named: fileName) else {
            throw ModuleStorageError.fileNotFound(fileName)
        }
        return data
    }

    func readModuleSnapshot(
        type: ModuleType, fileName: String
    ) async throws -> LampSyncRemoteFile {
        LampSyncRemoteFile(
            data: try await readModuleFile(type: type, fileName: fileName),
            revision: await shelf.revision(named: fileName)
        )
    }

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        await shelf.write(data, named: fileName)
    }

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        XCTFail("A round trip must not delete the module")
    }

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        await shelf.revision(named: fileName)
    }

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? { nil }
    func ensureDirectoryExists(type: ModuleType) async throws {}
    func directoryURL(for type: ModuleType) -> URL? { nil }
    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        .notAvailable
    }

    func readFile(path: String) async throws -> Data {
        guard let data = await shelf.data(named: path) else {
            throw ModuleStorageError.fileNotFound(path)
        }
        return data
    }

    func writeFile(path: String, data: Data) async throws {
        await shelf.write(data, named: path)
    }
}

/// A module going out and coming back the way the library pass moves it:
/// this device's own export, and another device's copy taken in by value.
extension ModuleSyncManager {
    /// Puts this device's export of an editable module on the shelf, with any
    /// attachments its writings name, as the pass sends them.
    func publish(moduleId: String, to storage: ShelfStorage) async throws {
        guard let module = try ModuleDatabase.shared.getModule(id: moduleId) else {
            throw ModuleSyncError.moduleNotFound(moduleId)
        }
        let data: Data
        switch module.type {
        case .notes: data = try exportNoteModuleToSQLite(module)
        case .devotional: data = try exportDevotionalModuleToSQLite(module)
        case .highlights: data = try exportHighlightModuleToSQLite(module)
        default: throw ModuleSyncError.moduleNotEditable(moduleId)
        }
        try await storage.writeModuleFile(type: module.type, fileName: "\(moduleId).lamp", data: data)
        if module.type == .devotional {
            for item in try devotionalMediaItems(moduleId: moduleId, forExport: true)
            where FileManager.default.fileExists(atPath: item.localURL.path) {
                try await storage.writeFile(path: item.remotePath, data: Data(contentsOf: item.localURL))
            }
        }
        try ModuleDatabase.shared.clearPendingModulePublication(moduleId: moduleId)
    }

    /// Takes the shelf's copy in as the pass takes another device's, and
    /// sends back what the merge leaves of this device's own.
    func pull(
        moduleId: String, type: ModuleType, from storage: ShelfStorage, fileName: String? = nil
    ) async throws {
        let fileName = fileName ?? "\(moduleId).lamp"
        let snapshot = try await storage.readModuleSnapshot(type: type, fileName: fileName)
        try await importRemoteModuleSnapshot(
            fileInfo: ModuleFileInfo(
                id: moduleId, type: type, filePath: fileName,
                fileHash: snapshot.revision, modificationDate: nil
            ),
            type: type, snapshot: snapshot, storage: storage
        )
        if try ModuleDatabase.shared.pendingModulePublications(type: type).contains(moduleId) {
            try await publish(moduleId: moduleId, to: storage)
        }
    }
}

/// A test storage that can list and read its module files, as a server's
/// folders would be listed and read.
protocol ListedModuleStorage: ModuleStorage {
    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo]
    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile
}

extension ShelfStorage: ListedModuleStorage {}

extension ModuleSyncManager {
    /// Takes in every module file a storage lists for a type, as the library
    /// pass installs each file that arrives.
    func takeIn(_ type: ModuleType, from storage: some ListedModuleStorage) async throws {
        for file in try await storage.listModuleFiles(type: type) {
            let snapshot = try await storage.readModuleSnapshot(type: type, fileName: file.filePath)
            try await importRemoteModuleSnapshot(
                fileInfo: file, type: type, snapshot: snapshot, storage: storage
            )
        }
    }
}
