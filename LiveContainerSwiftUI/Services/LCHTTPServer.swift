//
//  LCHTTPServer.swift
//  LiveContainerSwiftUI
//
//  A tiny streaming HTTP/1.1 server built on Network.framework.
//  No third-party dependencies; large bodies are written straight to disk.
//

import Foundation
import Network
import Security

// MARK: - Model

struct LCHTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    let bodyFileURL: URL?
}

struct LCHTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
    var downloadURL: URL?
    var downloadFileName: String?
}

// MARK: - Server

@MainActor
final class LCHTTPServer: ObservableObject {
    static let shared = LCHTTPServer()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "com.kdt.livecontainer.httpserver", qos: .utility)

    private init() {}

    // MARK: Configuration

    var isEnabled: Bool {
        get { LCUtils.appGroupUserDefault.bool(forKey: "LCHTTPServerEnabled") }
        set {
            LCUtils.appGroupUserDefault.set(newValue, forKey: "LCHTTPServerEnabled")
            if newValue {
                start()
            } else {
                stop()
            }
        }
    }

    var port: UInt16 {
        let configured = LCUtils.appGroupUserDefault.integer(forKey: "LCHTTPServerPort")
        return (1024...65535).contains(configured) ? UInt16(configured) : 8080
    }

    var loopbackOnly: Bool {
        LCUtils.appGroupUserDefault.bool(forKey: "LCHTTPServerLoopbackOnly")
    }

    var apiToken: String {
        if let existing = LCUtils.appGroupUserDefault.string(forKey: "LCHTTPServerToken"), !existing.isEmpty {
            return existing
        }
        return regenerateToken()
    }

    @discardableResult
    func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        LCUtils.appGroupUserDefault.set(token, forKey: "LCHTTPServerToken")
        return token
    }

    // MARK: Lifecycle

    func startIfEnabled() {
        guard isEnabled else {
            return
        }
        start()
    }

    func start() {
        stop()
        guard isEnabled else {
            return
        }
        // Ensure the API token is generated and persisted before accepting
        // connections so streaming upload preflight checks always find it.
        _ = apiToken
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "Invalid port \(port)"
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if loopbackOnly {
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            }
            let nwListener = try NWListener(using: parameters, on: nwPort)
            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            let connectionQueue = serverQueue
            nwListener.newConnectionHandler = { connection in
                let session = LCHTTPConnectionSession(connection: connection, queue: connectionQueue)
                session.start()
            }
            nwListener.start(queue: serverQueue)
            listener = nwListener
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Applies port / binding changes by restarting after the old listener has
    /// had a moment to release the socket.
    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.start()
        }
    }
}

// MARK: - Connection

final class LCHTTPConnectionSession {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private var headerBuffer = Data()
    private var headerParsed = false
    private var requestMethod = "GET"
    private var requestPath = "/"
    private var requestHeaders: [String: String] = [:]
    private var expectedBodyLength: Int64 = 0
    private var receivedBodyLength: Int64 = 0
    private var inMemoryBody = Data()
    private var bodyFileURL: URL?
    private var bodyFileHandle: FileHandle?
    private var isStreamingBody = false
    private var responded = false
    private var requestFinished = false

    private static let maxHeaderSize = 16 * 1024
    private static let maxInMemoryBody = 2 * 1024 * 1024
    private static let headerTerminator = Data([13, 10, 13, 10])

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    deinit {
        cleanupBodyFile()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveNext()
            case .failed, .cancelled:
                self?.cleanup()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finishWithError(status: 500, message: error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                self.consume(data)
            }
            if isComplete {
                if !self.requestFinished {
                    self.finishWithError(status: 400, message: "Incomplete request body")
                }
                return
            }
            if !self.responded && !self.requestFinished {
                self.receiveNext()
            }
        }
    }

    private func consume(_ data: Data) {
        if !headerParsed {
            headerBuffer.append(data)
            if headerBuffer.count > Self.maxHeaderSize {
                finishWithError(status: 431, message: "Request header too large")
                return
            }
            guard let terminatorRange = headerBuffer.range(of: Self.headerTerminator) else {
                return
            }
            let headerData = headerBuffer.subdata(in: 0..<terminatorRange.lowerBound)
            let bodyPrefix = headerBuffer.subdata(in: terminatorRange.upperBound..<headerBuffer.count)
            headerBuffer.removeAll(keepingCapacity: false)

            guard parseHeader(headerData) else {
                return
            }
            headerParsed = true

            if expectedBodyLength > 0 {
                if isStreamingBody {
                    prepareStreamingBodyFile()
                }
                if !bodyPrefix.isEmpty {
                    appendBody(bodyPrefix)
                }
                if receivedBodyLength >= expectedBodyLength {
                    finishRequest()
                }
            } else {
                finishRequest()
            }
            return
        }

        appendBody(data)
        if receivedBodyLength >= expectedBodyLength {
            finishRequest()
        }
    }

    private func parseHeader(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else {
            finishWithError(status: 400, message: "Malformed request header")
            return false
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            finishWithError(status: 400, message: "Missing request line")
            return false
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            finishWithError(status: 400, message: "Malformed request line")
            return false
        }
        requestMethod = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        if let questionMark = rawTarget.firstIndex(of: "?") {
            requestPath = String(rawTarget[..<questionMark])
            parseQuery(String(rawTarget[rawTarget.index(after: questionMark)...]))
        } else {
            requestPath = rawTarget
        }

        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            requestHeaders[name] = value
        }

        if let contentLength = requestHeaders["content-length"], let parsed = Int64(contentLength), parsed >= 0 {
            expectedBodyLength = parsed
        }
        if requestHeaders["transfer-encoding"]?.lowercased().contains("chunked") == true {
            finishWithError(status: 411, message: "Chunked transfer encoding is not supported; send Content-Length")
            return false
        }
        if expectedBodyLength > Int64(Int.max) {
            finishWithError(status: 413, message: "Body too large")
            return false
        }

        isStreamingBody = Self.isStreamingRoute(method: requestMethod, path: requestPath)
        if !isStreamingBody && expectedBodyLength > Int64(Self.maxInMemoryBody) {
            finishWithError(status: 413, message: "Body too large")
            return false
        }
        // Reject unauthenticated uploads before a single byte reaches the disk.
        if isStreamingBody, !LCHTTPRouter.isAuthorized(path: requestPath, headers: requestHeaders, query: parsedQuery) {
            finishWithError(status: 401, message: "Missing or invalid API token")
            return false
        }
        return true
    }

    private func parseQuery(_ raw: String) {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let value = parts.count > 1 ? (String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1])) : ""
            result[name] = value
        }
        parsedQuery = result
    }

    private var parsedQuery: [String: String] = [:]

    private static func isStreamingRoute(method: String, path: String) -> Bool {
        guard method == "POST" else {
            return false
        }
        return path == "/api/v1/apps/install" || path == "/api/v1/fs/upload"
    }

    private func prepareStreamingBodyFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LCUpload_\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        bodyFileURL = url
        bodyFileHandle = try? FileHandle(forWritingTo: url)
    }

    private func appendBody(_ data: Data) {
        guard !data.isEmpty else { return }
        let remaining = expectedBodyLength - receivedBodyLength
        guard remaining > 0 else { return }
        let chunk = data.count > Int(remaining) ? data.prefix(Int(remaining)) : data
        receivedBodyLength += Int64(chunk.count)

        if isStreamingBody {
            bodyFileHandle?.write(Data(chunk))
        } else {
            inMemoryBody.append(Data(chunk))
        }
    }

    private func finishRequest() {
        guard !responded, !requestFinished else { return }
        requestFinished = true
        bodyFileHandle?.closeFile()
        bodyFileHandle = nil

        let request = LCHTTPRequest(
            method: requestMethod,
            path: requestPath,
            query: parsedQuery,
            headers: requestHeaders,
            body: inMemoryBody,
            bodyFileURL: bodyFileURL
        )

        Task { @MainActor in
            let response = await LCHTTPRouter.shared.handle(request)
            // All connection state is owned by the server queue.
            self.queue.async {
                self.send(response)
            }
        }
    }

    // MARK: Response

    private func send(_ response: LCHTTPResponse) {
        guard !responded else { return }
        responded = true

        if let fileURL = response.downloadURL {
            sendFile(response, fileURL: fileURL)
            return
        }

        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Server"] = "LiveContainer"
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json; charset=utf-8"
        }

        var payload = Data(Self.statusLine(response.status).utf8)
        for (key, value) in headers {
            payload.append(Data("\(key): \(value)\r\n".utf8))
        }
        payload.append(Data("\r\n".utf8))
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.closeConnection()
        })
    }

    private func sendFile(_ response: LCHTTPResponse, fileURL: URL) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            let failure = LCHTTPRouter.errorResponse(status: 500, message: "Cannot read file")
            responded = false
            send(failure)
            return
        }

        var headers = response.headers
        headers["Content-Length"] = "\(fileSize)"
        headers["Content-Type"] = "application/octet-stream"
        headers["Connection"] = "close"
        headers["Server"] = "LiveContainer"
        if let fileName = response.downloadFileName {
            headers["Content-Disposition"] = "attachment; filename=\"\(fileName)\""
        }

        var payload = Data(Self.statusLine(response.status).utf8)
        for (key, value) in headers {
            payload.append(Data("\(key): \(value)\r\n".utf8))
        }
        payload.append(Data("\r\n".utf8))

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.cleanup()
                return
            }
            self.streamFile(handle: handle, sent: 0, total: fileSize)
        })
    }

    private func streamFile(handle: FileHandle, sent: Int64, total: Int64) {
        guard sent < total else {
            try? handle.close()
            closeConnection()
            return
        }
        let chunkSize = Int(min(Int64(256 * 1024), total - sent))
        let chunk: Data
        do {
            guard let read = try handle.read(upToCount: chunkSize), !read.isEmpty else {
                try? handle.close()
                closeConnection()
                return
            }
            chunk = read
        } catch {
            try? handle.close()
            cleanup()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.cleanup()
                return
            }
            self.streamFile(handle: handle, sent: sent + Int64(chunk.count), total: total)
        })
    }

    private static func statusLine(_ status: Int) -> String {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        case 500: reason = "Internal Server Error"
        default: reason = "Error"
        }
        return "HTTP/1.1 \(status) \(reason)\r\n"
    }

    private func finishWithError(status: Int, message: String) {
        let response = LCHTTPRouter.errorResponse(status: status, message: message)
        send(response)
    }

    private func closeConnection() {
        responded = true
        cleanupBodyFile()
        connection.cancel()
    }

    private func cleanup() {
        cleanupBodyFile()
    }

    private func cleanupBodyFile() {
        bodyFileHandle?.closeFile()
        bodyFileHandle = nil
        if let bodyFileURL {
            try? FileManager.default.removeItem(at: bodyFileURL)
            self.bodyFileURL = nil
        }
    }
}

// MARK: - Routing

private struct LCHTTPEnvelope<T: Encodable>: Encodable {
    let ok: Bool
    let data: T
}

private struct LCHTTPErrorEnvelope: Encodable {
    let ok: Bool
    let error: String
}

private struct LCStatusPayload: Encodable {
    let running: Bool
    let port: Int
    let loopbackOnly: Bool
    let multiLCStatus: Int
    let appCount: Int
    let version: String
}

private struct LCAppsPayload: Encodable {
    let apps: [LCInstalledAppDTO]
}

private struct LCFileListPayload: Encodable {
    let path: String
    let items: [LCFileItemDTO]
}

private struct LCSimplePayload: Encodable {
    let success: Bool
    let path: String?
}

@MainActor
final class LCHTTPRouter {
    static let shared = LCHTTPRouter()
    private init() {}

    nonisolated static func errorResponse(status: Int, message: String) -> LCHTTPResponse {
        let body = (try? JSONEncoder().encode(LCHTTPErrorEnvelope(ok: false, error: message))) ?? Data()
        return LCHTTPResponse(status: status, body: body)
    }

    func handle(_ request: LCHTTPRequest) async -> LCHTTPResponse {
        guard request.path.hasPrefix("/api/v1/") else {
            return Self.errorResponse(status: 404, message: "Unknown endpoint: " + request.path)
        }
        guard isAuthorized(request) else {
            return Self.errorResponse(status: 401, message: "Missing or invalid API token")
        }

        switch (request.method, request.path) {
        case ("GET", "/api/v1/status"):
            return statusResponse()
        case ("GET", "/api/v1/apps"):
            return appsResponse(includeHidden: boolValue(request.query["includeHidden"]) ?? false)
        case ("POST", "/api/v1/apps/install"):
            return await installResponse(request)
        case ("POST", "/api/v1/apps/uninstall"), ("DELETE", "/api/v1/apps/uninstall"):
            return await uninstallResponse(request)
        case ("GET", "/api/v1/fs/list"):
            return listResponse(request)
        case ("GET", "/api/v1/fs/download"):
            return downloadResponse(request)
        case ("POST", "/api/v1/fs/upload"):
            return uploadResponse(request)
        case ("POST", "/api/v1/fs/rename"):
            return renameResponse(request)
        case ("DELETE", "/api/v1/fs/delete"), ("POST", "/api/v1/fs/delete"):
            return deleteResponse(request)
        default:
            return Self.errorResponse(status: 404, message: "Unknown endpoint: " + request.method + " " + request.path)
        }
    }

    // MARK: Auth

    private func isAuthorized(_ request: LCHTTPRequest) -> Bool {
        _ = LCHTTPServer.shared.apiToken
        return Self.isAuthorized(path: request.path, headers: request.headers, query: request.query)
    }

    nonisolated static func isAuthorized(path: String, headers: [String: String], query: [String: String]) -> Bool {
        guard let token = LCUtils.appGroupUserDefault.string(forKey: "LCHTTPServerToken"), !token.isEmpty else {
            return false
        }
        if let header = headers["authorization"] {
            let bearer = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
            if constantTimeEquals(bearer, token) {
                return true
            }
        }
        if let headerToken = headers["x-lc-token"], constantTimeEquals(headerToken, token) {
            return true
        }
        // Only the download endpoint may carry the token in the query string so
        // that a browser or download manager can fetch a file directly.
        if path == "/api/v1/fs/download",
           let queryToken = query["token"],
           constantTimeEquals(queryToken, token) {
            return true
        }
        return false
    }

    nonisolated static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference: UInt8 = left.count == right.count ? 0 : 1
        let count = min(left.count, right.count)
        for index in 0..<count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: Handlers

    private func statusResponse() -> LCHTTPResponse {
        let sharedModel = DataManager.shared.model
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let payload = LCStatusPayload(
            running: LCHTTPServer.shared.isRunning,
            port: Int(LCHTTPServer.shared.port),
            loopbackOnly: LCHTTPServer.shared.loopbackOnly,
            multiLCStatus: sharedModel.multiLCStatus,
            appCount: sharedModel.apps.count + sharedModel.hiddenApps.count,
            version: version
        )
        return json(payload)
    }

    private func appsResponse(includeHidden: Bool) -> LCHTTPResponse {
        let apps = LCAppInstallerService.shared.installedApps(includeHidden: includeHidden)
        return json(LCAppsPayload(apps: apps))
    }

    private func installResponse(_ request: LCHTTPRequest) async -> LCHTTPResponse {
        guard let bodyFileURL = request.bodyFileURL else {
            return Self.errorResponse(status: 400, message: "Missing IPA body")
        }
        do {
            let dto = try await LCAppInstallerService.shared.installIPA(
                from: bodyFileURL,
                overwrite: boolValue(request.query["overwrite"]) ?? false
            )
            return json(dto)
        } catch {
            return Self.response(for: error)
        }
    }

    private func uninstallResponse(_ request: LCHTTPRequest) async -> LCHTTPResponse {
        let jsonBody = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let identifier = request.query["bundleId"]
            ?? request.query["relativeBundlePath"]
            ?? jsonBody?["bundleId"] as? String
            ?? jsonBody?["relativeBundlePath"] as? String
        guard let identifier, !identifier.isEmpty else {
            return Self.errorResponse(status: 400, message: "Missing bundleId or relativeBundlePath")
        }

        let keepDataValue: Bool
        if let keepData = boolValue(request.query["keepData"]) {
            keepDataValue = keepData
        } else if let keepData = jsonBody?["keepData"] as? Bool {
            keepDataValue = keepData
        } else {
            keepDataValue = false
        }

        do {
            try await LCAppInstallerService.shared.uninstallApp(identifier: identifier, keepData: keepDataValue)
            return json(LCSimplePayload(success: true, path: nil))
        } catch {
            return Self.response(for: error)
        }
    }

    private func listResponse(_ request: LCHTTPRequest) -> LCHTTPResponse {
        guard let path = request.query["path"], !path.isEmpty else {
            return Self.errorResponse(status: 400, message: "Missing path")
        }
        do {
            let items = try LCSandboxFileManager.shared.listDirectory(virtualPath: path)
            return json(LCFileListPayload(path: path, items: items))
        } catch {
            return Self.response(for: error)
        }
    }

    private func downloadResponse(_ request: LCHTTPRequest) -> LCHTTPResponse {
        guard let path = request.query["path"], !path.isEmpty else {
            return Self.errorResponse(status: 400, message: "Missing path")
        }
        do {
            let fileURL = try LCSandboxFileManager.shared.fileForDownload(virtualPath: path)
            var response = LCHTTPResponse()
            response.downloadURL = fileURL
            response.downloadFileName = fileURL.lastPathComponent
            return response
        } catch {
            return Self.response(for: error)
        }
    }

    private func uploadResponse(_ request: LCHTTPRequest) -> LCHTTPResponse {
        guard let path = request.query["path"], !path.isEmpty else {
            return Self.errorResponse(status: 400, message: "Missing path")
        }
        guard let bodyFileURL = request.bodyFileURL else {
            return Self.errorResponse(status: 400, message: "Missing file body")
        }
        do {
            try LCSandboxFileManager.shared.storeUploadedFile(
                from: bodyFileURL,
                toVirtualPath: path,
                overwrite: boolValue(request.query["overwrite"]) ?? false
            )
            return json(LCSimplePayload(success: true, path: path))
        } catch {
            return Self.response(for: error)
        }
    }

    private func renameResponse(_ request: LCHTTPRequest) -> LCHTTPResponse {
        guard let jsonBody = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let from = jsonBody["from"] as? String,
              let to = jsonBody["to"] as? String else {
            return Self.errorResponse(status: 400, message: "Body must contain from and to")
        }
        do {
            try LCSandboxFileManager.shared.moveOrRename(
                fromVirtual: from,
                toVirtual: to,
                overwrite: (jsonBody["overwrite"] as? Bool) ?? false
            )
            return json(LCSimplePayload(success: true, path: to))
        } catch {
            return Self.response(for: error)
        }
    }

    private func deleteResponse(_ request: LCHTTPRequest) -> LCHTTPResponse {
        guard let path = request.query["path"], !path.isEmpty else {
            return Self.errorResponse(status: 400, message: "Missing path")
        }
        do {
            try LCSandboxFileManager.shared.deleteItem(virtualPath: path)
            return json(LCSimplePayload(success: true, path: path))
        } catch {
            return Self.response(for: error)
        }
    }

    // MARK: Helpers

    private func json<T: Encodable>(_ value: T, status: Int = 200) -> LCHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(LCHTTPEnvelope(ok: true, data: value)) else {
            return Self.errorResponse(status: 500, message: "Failed to encode response")
        }
        return LCHTTPResponse(status: status, body: body)
    }

    private func boolValue(_ raw: String?) -> Bool? {
        guard let raw else {
            return nil
        }
        switch raw.lowercased() {
        case "true", "1", "yes":
            return true
        case "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    private static func response(for error: Error) -> LCHTTPResponse {
        if let fsError = error as? LCSandboxFSException {
            switch fsError {
            case .invalidVirtualPath, .accessDeniedPathTraversal,
                 .rootModificationForbidden, .symbolicLinkOutsideRoot:
                return errorResponse(status: 403, message: fsError.localizedDescription)
            case .fileNotFound:
                return errorResponse(status: 404, message: fsError.localizedDescription)
            case .targetAlreadyExists:
                return errorResponse(status: 409, message: fsError.localizedDescription)
            case .isDirectory:
                return errorResponse(status: 400, message: fsError.localizedDescription)
            }
        }
        if let installerError = error as? LCInstallerError {
            switch installerError {
            case .subContainerReadOnly, .builtInAppNotRemovable:
                return errorResponse(status: 403, message: installerError.localizedDescription)
            case .installInProgress, .containerInUse:
                return errorResponse(status: 409, message: installerError.localizedDescription)
            case .appNotFound:
                return errorResponse(status: 404, message: installerError.localizedDescription)
            case .notAnIPA, .bundleNotFound, .infoPlistUnreadable:
                return errorResponse(status: 400, message: installerError.localizedDescription)
            case .signingFailed:
                return errorResponse(status: 500, message: installerError.localizedDescription)
            }
        }
        return errorResponse(status: 500, message: error.localizedDescription)
    }
}
