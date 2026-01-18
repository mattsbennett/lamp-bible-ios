//
//  WebDAVClient.swift
//  Lamp Bible
//
//  Created by Claude on 2025-01-17.
//

import Foundation

// MARK: - WebDAV Item

/// Represents a file or directory on a WebDAV server
struct WebDAVItem {
    let path: String
    let name: String
    let isDirectory: Bool
    let etag: String?
    let lastModified: Date?
    let size: Int64?
}

// MARK: - WebDAV Error

enum WebDAVError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String?)
    case authenticationRequired
    case forbidden
    case notFound
    case conflict
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
class WebDAVClient {
    let baseURL: URL
    private let session: URLSession
    private let credential: URLCredential?

    /// Initialize with base URL and optional credentials
    /// - Parameters:
    ///   - baseURL: The WebDAV server base URL
    ///   - username: Optional username for Basic authentication
    ///   - password: Optional password for Basic authentication
    init(baseURL: URL, username: String? = nil, password: String? = nil) {
        self.baseURL = baseURL

        if let username = username, let password = password {
            self.credential = URLCredential(user: username, password: password, persistence: .forSession)
        } else {
            self.credential = nil
        }

        // Configure session with default timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Test connection to the server
    func testConnection() async throws -> Bool {
        let url = baseURL
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        addAuthHeader(to: &request)

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebDAVError.invalidResponse
            }
            return (200..<300).contains(httpResponse.statusCode)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    /// List contents of a directory
    /// - Parameter path: Path relative to base URL (e.g., "/LampBible/Notes/")
    /// - Returns: Array of WebDAVItem representing files and directories
    func listDirectory(_ path: String) async throws -> [WebDAVItem] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        // PROPFIND body requesting basic properties
        let propfindBody = """
        <?xml version="1.0" encoding="UTF-8"?>
        <d:propfind xmlns:d="DAV:">
            <d:prop>
                <d:resourcetype/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:getetag/>
            </d:prop>
        </d:propfind>
        """
        request.httpBody = propfindBody.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            try handleHTTPResponse(response)
            return try parseMultiStatus(data, basePath: path)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    /// Download a file from the server
    /// - Parameter path: Path relative to base URL
    /// - Returns: File data
    func download(_ path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuthHeader(to: &request)

        do {
            let (data, response) = try await session.data(for: request)
            try handleHTTPResponse(response)
            return data
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    /// Upload data to the server
    /// - Parameters:
    ///   - data: Data to upload
    ///   - path: Destination path relative to base URL
    func upload(_ data: Data, to path: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        addAuthHeader(to: &request)

        do {
            let (_, response) = try await session.data(for: request)
            try handleHTTPResponse(response, allowedCodes: [200, 201, 204])
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    /// Delete a file or directory from the server
    /// - Parameter path: Path relative to base URL
    func delete(_ path: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuthHeader(to: &request)

        do {
            let (_, response) = try await session.data(for: request)
            try handleHTTPResponse(response, allowedCodes: [200, 204, 404]) // 404 is OK - already deleted
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    /// Create a directory on the server
    /// - Parameter path: Path relative to base URL
    func createDirectory(_ path: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        addAuthHeader(to: &request)

        do {
            let (_, response) = try await session.data(for: request)
            try handleHTTPResponse(response, allowedCodes: [200, 201, 405]) // 405 = already exists
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    /// Get the ETag for a file
    /// - Parameter path: Path relative to base URL
    /// - Returns: ETag string or nil if not available
    func getETag(_ path: String) async throws -> String? {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        addAuthHeader(to: &request)

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebDAVError.invalidResponse
            }

            if httpResponse.statusCode == 404 {
                return nil
            }

            try handleHTTPResponse(response)
            return httpResponse.value(forHTTPHeaderField: "ETag")
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    /// Check if a path exists on the server
    /// - Parameter path: Path relative to base URL
    /// - Returns: True if the path exists
    func exists(_ path: String) async throws -> Bool {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        addAuthHeader(to: &request)

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WebDAVError.invalidResponse
            }
            return httpResponse.statusCode == 200
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.networkError(error)
        }
    }

    // MARK: - Private Helpers

    private func addAuthHeader(to request: inout URLRequest) {
        guard let credential = credential,
              let user = credential.user,
              let password = credential.password else {
            return
        }

        let loginString = "\(user):\(password)"
        guard let loginData = loginString.data(using: .utf8) else { return }
        let base64LoginString = loginData.base64EncodedString()
        request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
    }

    private func handleHTTPResponse(_ response: URLResponse, allowedCodes: [Int]? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVError.invalidResponse
        }

        let statusCode = httpResponse.statusCode
        let allowed = allowedCodes ?? Array(200..<300)

        if allowed.contains(statusCode) {
            return
        }

        switch statusCode {
        case 401:
            throw WebDAVError.authenticationRequired
        case 403:
            throw WebDAVError.forbidden
        case 404:
            throw WebDAVError.notFound
        case 409:
            throw WebDAVError.conflict
        case 507:
            throw WebDAVError.insufficientStorage
        default:
            throw WebDAVError.httpError(statusCode, HTTPURLResponse.localizedString(forStatusCode: statusCode))
        }
    }

    /// Parse WebDAV multistatus XML response
    private func parseMultiStatus(_ data: Data, basePath: String) throws -> [WebDAVItem] {
        let parser = WebDAVResponseParser(basePath: basePath)
        let success = parser.parse(data)

        if !success, let error = parser.parseError {
            throw WebDAVError.parseError(error)
        }

        return parser.items
    }
}

// MARK: - WebDAV Response Parser

/// Simple XML parser for WebDAV multistatus responses
private class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private let basePath: String
    private(set) var items: [WebDAVItem] = []
    private(set) var parseError: String?

    // Current parsing state
    private var currentHref: String?
    private var currentIsDirectory = false
    private var currentETag: String?
    private var currentLastModified: Date?
    private var currentSize: Int64?
    private var currentElement: String?
    private var currentText = ""

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    init(basePath: String) {
        self.basePath = basePath
        super.init()
    }

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = localName(from: elementName)
        currentText = ""

        if currentElement == "response" {
            // Reset for new response
            currentHref = nil
            currentIsDirectory = false
            currentETag = nil
            currentLastModified = nil
            currentSize = nil
        } else if currentElement == "collection" {
            currentIsDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localElement = localName(from: elementName)
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localElement {
        case "href":
            currentHref = trimmedText.removingPercentEncoding ?? trimmedText
        case "getetag":
            currentETag = trimmedText.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "getlastmodified":
            currentLastModified = dateFormatter.date(from: trimmedText)
        case "getcontentlength":
            currentSize = Int64(trimmedText)
        case "response":
            // Finished parsing a response - create item
            if let href = currentHref {
                // Extract name from href
                let name = URL(fileURLWithPath: href).lastPathComponent

                // Skip the base directory itself
                let normalizedHref = href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let normalizedBase = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if normalizedHref != normalizedBase && !name.isEmpty {
                    let item = WebDAVItem(
                        path: href,
                        name: name,
                        isDirectory: currentIsDirectory,
                        etag: currentETag,
                        lastModified: currentLastModified,
                        size: currentSize
                    )
                    items.append(item)
                }
            }
        default:
            break
        }

        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError.localizedDescription
    }

    /// Extract local name from potentially namespaced element name
    private func localName(from elementName: String) -> String {
        if let colonIndex = elementName.lastIndex(of: ":") {
            return String(elementName[elementName.index(after: colonIndex)...])
        }
        return elementName
    }
}
