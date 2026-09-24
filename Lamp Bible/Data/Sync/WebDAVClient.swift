//
//  WebDAVClient.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation
import LampModuleKit

// MARK: - WebDAV Error

enum WebDAVError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String?)
    case authenticationRequired
    case forbidden
    case notFound
    case conflict
    case preconditionFailed
    case insufficientStorage
    case serverError(String)
    case networkError(Error)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebDAV URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code, let message):
            return "HTTP error \(code): \(message ?? "Unknown")"
        case .authenticationRequired:
            return "Authentication required"
        case .forbidden:
            return "Access forbidden"
        case .notFound:
            return "Resource not found"
        case .conflict:
            return "Conflict - resource may already exist"
        case .preconditionFailed:
            return "The remote file changed before it could be saved"
        case .insufficientStorage:
            return "Insufficient storage on server"
        case .serverError(let message):
            return "Server error: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let message):
            return "Parse error: \(message)"
        }
    }
}

// MARK: - WebDAV Client

/// HTTP client for WebDAV operations (PROPFIND, PUT, DELETE, MKCOL)
final class WebDAVClient {
    let baseURL: URL
    private let storage: LampWebDAVStorage

    init(baseURL: URL, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL
        let credentials: LampWebDAVHTTP.Credentials?
        if let username, let password {
            credentials = .init(username: username, password: password)
        } else {
            credentials = nil
        }
        storage = LampWebDAVStorage(baseURL: baseURL, credentials: credentials)
    }

    func testConnection() async throws -> Bool {
        try await mapped { try await storage.testConnection() }
    }

    func download(_ path: String) async throws -> Data {
        guard let data = try await mapped({ try await storage.download(path) }) else {
            throw WebDAVError.notFound
        }
        return data
    }

    func read(path: String) async throws -> LampSyncRemoteFile? {
        try await mapped { try await storage.read(path: path) }
    }

    func list(directory: String) async throws -> [LampSyncRemoteEntry]? {
        try await mapped { try await storage.list(directory: directory) }
    }

    func upload(_ data: Data, to path: String) async throws {
        try await mapped { try await storage.upload(data, to: path) }
    }

    func write(
        _ data: Data,
        to path: String,
        condition: LampSyncWriteCondition
    ) async throws -> String? {
        try await mapped { try await storage.write(data, to: path, condition: condition) }
    }

    func delete(_ path: String) async throws {
        try await mapped { try await storage.delete(path) }
    }

    func createDirectory(_ path: String) async throws {
        try await mapped { try await storage.createDirectory(path) }
    }

    func getETag(_ path: String) async throws -> String? {
        try await mapped { try await storage.getETag(path) }
    }

    func revision(path: String) async throws -> String? {
        try await mapped { try await storage.revision(path: path) }
    }

    func exists(_ path: String) async throws -> Bool {
        try await mapped { try await storage.exists(path) }
    }

    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch LampWebDAVStorage.StorageError.invalidPath {
            throw WebDAVError.invalidURL
        } catch LampWebDAVStorage.StorageError.invalidResponse {
            throw WebDAVError.invalidResponse
        } catch LampWebDAVStorage.StorageError.invalidXML(let message) {
            throw WebDAVError.parseError(message)
        } catch LampWebDAVStorage.StorageError.preconditionFailed {
            throw WebDAVError.preconditionFailed
        } catch LampWebDAVStorage.StorageError.httpStatus(let code) {
            switch code {
            case 401: throw WebDAVError.authenticationRequired
            case 403: throw WebDAVError.forbidden
            case 404: throw WebDAVError.notFound
            case 405:
                throw WebDAVError.httpError(
                    code, "Method not allowed - server may not support WebDAV or path is incorrect"
                )
            case 409: throw WebDAVError.conflict
            case 507: throw WebDAVError.insufficientStorage
            default:
                throw WebDAVError.httpError(
                    code, HTTPURLResponse.localizedString(forStatusCode: code)
                )
            }
        } catch {
            throw WebDAVError.networkError(error)
        }
    }
}
