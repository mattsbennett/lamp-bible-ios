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
