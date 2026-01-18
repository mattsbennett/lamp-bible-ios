//
//  WebDAVModuleStorage.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation
import CryptoKit

// MARK: - WebDAV Module Storage

/// ModuleStorage implementation for WebDAV servers (Nextcloud, ownCloud, etc.)
class WebDAVModuleStorage: ModuleStorage {
    private let client: WebDAVClient

    /// Cache of ETags for change detection
    private var etagCache: [String: String] = [:]

    /// Initialize with WebDAV client
    /// - Parameters:
    ///   - baseURL: The WebDAV server base URL (module folders are created directly here)
    ///   - username: Username for authentication
    ///   - password: Password for authentication
    init(baseURL: URL, username: String?, password: String?) {
        self.client = WebDAVClient(baseURL: baseURL, username: username, password: password)
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

            let items = try await client.listDirectory(dirPath)

            return items.compactMap { item -> ModuleFileInfo? in
                // Skip directories
                guard !item.isDirectory else { return nil }

                // Extract module ID from filename
                let id = extractModuleId(from: item.name)

                // Cache ETag
                if let etag = item.etag {
                    let cacheKey = "\(type.rawValue)/\(item.name)"
                    etagCache[cacheKey] = etag
                }

                return ModuleFileInfo(
                    id: id,
                    type: type,
                    filePath: item.name,
                    fileHash: item.etag,
                    modificationDate: item.lastModified
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
        let filePath = "\(directoryName(for: type))/\(fileName)"

        do {
            return try await client.download(filePath)
        } catch WebDAVError.notFound {
            throw ModuleStorageError.fileNotFound(fileName)
        } catch {
            throw error
        }
    }

    func writeModuleFile(type: ModuleType, fileName: String, data: Data) async throws {
        // Ensure directory structure exists
        try await ensureDirectoryExists(type: type)

        let filePath = "\(directoryName(for: type))/\(fileName)"
        try await client.upload(data, to: filePath)

        // Update ETag cache
        if let etag = try? await client.getETag(filePath) {
            let cacheKey = "\(type.rawValue)/\(fileName)"
            etagCache[cacheKey] = etag
        }
    }

    func deleteModuleFile(type: ModuleType, fileName: String) async throws {
        let filePath = "\(directoryName(for: type))/\(fileName)"

        do {
            try await client.delete(filePath)

            // Remove from cache
            let cacheKey = "\(type.rawValue)/\(fileName)"
            etagCache.removeValue(forKey: cacheKey)
        } catch WebDAVError.notFound {
            // Already deleted - ignore
        } catch {
            throw error
        }
    }

    func getFileHash(type: ModuleType, fileName: String) async throws -> String? {
        let cacheKey = "\(type.rawValue)/\(fileName)"

        // Return cached ETag if available
        if let cached = etagCache[cacheKey] {
            return cached
        }

        // Fetch from server
        let filePath = "\(directoryName(for: type))/\(fileName)"
        let etag = try await client.getETag(filePath)

        if let etag = etag {
            etagCache[cacheKey] = etag
        }

        return etag
    }

    func getModificationDate(type: ModuleType, fileName: String) async throws -> Date? {
        let dirPath = "\(directoryName(for: type))/"

        do {
            let items = try await client.listDirectory(dirPath)
            return items.first { $0.name == fileName }?.lastModified
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

    // MARK: - Helpers

    /// Extract module ID from filename (remove extension)
    private func extractModuleId(from fileName: String) -> String {
        var id = fileName

        // Remove common extensions in order
        let extensions = [".lamp", ".db.zlib", ".db", ".json"]
        for ext in extensions {
            if id.hasSuffix(ext) {
                id = String(id.dropLast(ext.count))
                break
            }
        }

        return id
    }
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
