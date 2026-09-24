//
//  WebDAVModuleStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation
import LampModuleKit

// MARK: - WebDAV Module Storage

/// ModuleStorage implementation for WebDAV servers (Nextcloud, ownCloud, etc.)
class WebDAVModuleStorage: ModuleStorage, LampSyncRemoteStore {
    private let client: WebDAVClient
    let syncSourceIdentifier: String

    /// Initialize with WebDAV client
    /// - Parameters:
    ///   - baseURL: The WebDAV server base URL (module folders are created directly here)
    ///   - username: Username for authentication
    ///   - password: Password for authentication
    init(baseURL: URL, username: String?, password: String?) {
        self.client = WebDAVClient(baseURL: baseURL, username: username, password: password)
        self.syncSourceIdentifier = "webdav:\(baseURL.absoluteString)|\(username ?? "")"
    }

    // MARK: - ModuleStorage Protocol

    func isAvailable() async -> Bool {
        do {
            return try await client.testConnection()
        } catch {
            print("[WebDAV] Connection test failed: \(error)")
            return false
        }
    }

    func listModuleFiles(type: ModuleType) async throws -> [ModuleFileInfo] {
        let dirPath = "\(directoryName(for: type))/"

        do {
            // Ensure directory exists first
            try await ensureDirectoryExists(type: type)

            let items = try await LampSyncModuleFolder.list(
                in: self, directory: dirPath
            )

            return items.compactMap { item -> ModuleFileInfo? in
                guard let id = LampSyncModuleFiles.moduleID(from: item.name) else { return nil }

                return ModuleFileInfo(
                    id: id,
                    type: type,
                    filePath: item.name,
                    fileHash: item.revision.flatMap {
                        LampWebDAVStorage.isStrongETag($0) ? $0 : nil
                    },
                    modificationDate: item.modifiedAt
                )
            }
        } catch WebDAVError.notFound {
            // Directory doesn't exist yet - return empty list
            return []
        } catch {
            throw error
        }
    }

    func readModuleFile(type: ModuleType, fileName: String) async throws -> Data {
        try await readModuleSnapshot(type: type, fileName: fileName).data
    }

    func readModuleSnapshot(type: ModuleType, fileName: String) async throws -> LampSyncRemoteFile {
        let filePath = "\(directoryName(for: type))/\(fileName)"
        guard let remote = try await client.read(path: filePath) else {
            throw ModuleStorageError.fileNotFound(fileName)
        }
        return LampSyncModuleRead.webDAV(remote)
    }

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        _ = try await writeModuleFile(
            type: type, fileName: fileName, data: data, matching: nil
        )
    }

    @discardableResult
    func writeModuleFile(
        type: ModuleType,
        fileName: String,
        data: Data,
        matching base: String?,
        supersededBy archiveFile: LampCompatibilityManifest.File? = nil
    ) async throws -> String {
        // Ensure directory structure exists
        try await ensureDirectoryExists(type: type)

        let filePath = "\(directoryName(for: type))/\(fileName)"
        let revision = try await LampSyncObservedWrite.publish(
            data, to: filePath, in: self,
            matching: base, supersededBy: archiveFile
        )
        return revision
    }

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        let filePath = "\(directoryName(for: type))/\(fileName)"

        do {
            try await client.delete(filePath)
        } catch WebDAVError.notFound {
            // Already deleted - ignore
        } catch {
            throw error
        }
    }

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        let filePath = "\(directoryName(for: type))/\(fileName)"
        let revision = try await client.revision(path: filePath)
        return revision.flatMap { LampWebDAVStorage.isStrongETag($0) ? $0 : nil }
    }

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? {
        let dirPath = "\(directoryName(for: type))/"

        do {
            let items = try await list(directory: dirPath) ?? []
            return items.first { $0.name == fileName }?.modifiedAt
        } catch {
            return nil
        }
    }

    func ensureDirectoryExists(type: ModuleType) async throws {
        // Create type-specific directory directly under baseURL
        let typePath = directoryName(for: type)
        do {
            try await client.createDirectory(typePath)
        } catch WebDAVError.httpError(405, _) {
            // Directory exists
        } catch WebDAVError.conflict {
            // Directory already exists
        }
    }

    func directoryURL(for type: ModuleType) -> URL? {
        return client.baseURL
            .appendingPathComponent(directoryName(for: type))
    }

    func getSyncStatus(type: ModuleType, fileName: String) async -> ModuleSyncStatus {
        let filePath = "\(directoryName(for: type))/\(fileName)"

        do {
            let exists = try await client.exists(filePath)
            return exists ? .synced : .notSynced
        } catch {
            return .notAvailable
        }
    }

    // MARK: - Change Token

    func getChangeToken(path: String) async -> String? {
        let revision = try? await client.revision(path: path)
        return LampSyncConditionalWrite.strongToken(for: revision)
    }

    // MARK: - Generic File Access

    func readFile(path: String) async throws -> Data {
        do {
            return try await client.download(path)
        } catch WebDAVError.notFound {
            throw ModuleStorageError.fileNotFound(path)
        } catch {
            throw error
        }
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        try await client.read(path: path)
    }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        try await client.list(directory: directory)
    }

    func revision(path: String) async throws -> String? {
        try await client.revision(path: path)
    }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        try await ensureParentDirectories(for: path)
        return try await client.write(data, to: path, condition: condition)
    }

    func writeFile(path: String, data: Data) async throws {
        try await ensureParentDirectories(for: path)
        _ = try await LampSyncObservedWrite.publish(
            data, to: path, in: self, matching: nil
        )
    }

    private func ensureParentDirectories(for path: String) async throws {
        _ = try await LampSyncRemoteDirectories.prepareParents(for: path) { directory in
            do {
                try await client.createDirectory(directory)
            } catch WebDAVError.httpError(405, _) {
                // Directory exists on servers that reject a repeated MKCOL.
            } catch WebDAVError.conflict {
                // Continue to the write; some servers report this for an
                // existing directory, and the write checks the actual result.
            } catch {
                // A directory may already exist even if MKCOL is unsupported.
                print("[WebDAV] Could not create directory \(directory): \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Extract module ID from filename (remove extension)
}

// MARK: - Keychain Helper

/// Helper for securely storing WebDAV credentials in Keychain
enum KeychainHelper {
    private static let service = "com.lampbible.webdav"

    /// Save WebDAV password to Keychain
    static func saveWebDAVPassword(_ password: String) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete existing password first
        try? deleteWebDAVPassword()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "webdav_password",
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieve WebDAV password from Keychain
    static func getWebDAVPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "webdav_password",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }

        return password
    }

    /// Delete WebDAV password from Keychain
    static func deleteWebDAVPassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "webdav_password"
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode password"
        case .saveFailed(let status):
            return "Failed to save to Keychain: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain: \(status)"
        }
    }
}
