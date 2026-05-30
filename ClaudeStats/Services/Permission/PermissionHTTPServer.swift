import Foundation
import Network
import Observation

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only. Speaks just enough of the
/// protocol to serve Claude Code's hook traffic: `POST /state` (fire-and-forget
/// state events), `POST /permission` (blocking, returns the user's decision),
/// and `GET /health` for the in-app "server up" indicator.
///
/// Connection: close after every request. We do not implement keep-alive,
/// pipelining, or chunked encoding — none of those are used by CC's hooks.
@MainActor
@Observable
final class PermissionHTTPServer {

    enum Status: Equatable {
        case stopped
        case starting(port: Int)
        case running(port: Int)
        case failed(reason: String)
    }

    private(set) var status: Status = .stopped

    /// Number of state events seen since `start()`. Useful for the
    /// settings page "1234 events received" diagnostic.
    private(set) var stateEventsReceived: Int = 0
    /// Number of permission requests handled (allowed/denied/dropped/timed out).
    private(set) var permissionRequestsHandled: Int = 0

    private weak var store: PermissionStore?
    private weak var sessionRegistry: SessionRegistry?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.rladmsrl.ClaudeStats.permission-server")
    /// Bearer token written to disk for the hook script to attach as
    /// `Authorization: Bearer <token>`. Regenerated on each `start()`.
    private(set) var bearerToken: String = ""

    /// Active connection readers. NWConnection.receive captures the reader
    /// via `[weak self]`, so without this strong reference the reader is
    /// released the moment `handleNewConnection` returns and every receive
    /// callback silently no-ops on `guard let self else { return }`.
    /// Cleared per connection in `route(_:on:)`.
    nonisolated(unsafe) private var activeReaders: [ObjectIdentifier: AnyObject] = [:]
    private let activeReadersLock = NSLock()

    nonisolated static let maxBodyBytes = 64 * 1024
    nonisolated static let permissionTimeout: TimeInterval = 600 // matches CC's hook timeout

    nonisolated static func isValidPort(_ port: Int) -> Bool {
        (1024...65535).contains(port)
    }

    nonisolated static let loopbackHostnames: Set<String> = ["127.0.0.1", "localhost", "::1"]

    /// Loopback binding stops the LAN from reaching us, but it does NOT stop a
    /// web page in the user's own browser from POSTing to `127.0.0.1` (classic
    /// localhost CSRF) or a DNS-rebinding page whose name resolves to loopback.
    /// Claude Code's hooks are curl / URLSession callers: they never attach an
    /// `Origin` header and always send a loopback `Host`. A browser does the
    /// opposite — cross-site `fetch`/form POSTs carry an `Origin`, and a
    /// rebinding page sends `Host: attacker.example`. Reject both.
    nonisolated static func isTrustedHookRequest(headers: [String: String]) -> Bool {
        // Any Origin means a browser sent this cross-site. CC's hooks never do.
        if let origin = headers["origin"], !origin.isEmpty { return false }
        // Host must be loopback. HTTP/1.1 requires it; curl always sends it.
        guard let host = headers["host"] else { return false }
        return loopbackHostnames.contains(hostname(fromHostHeader: host))
    }

    /// Extracts the host portion from a `Host` header value, dropping the
    /// `:port` suffix and unwrapping an IPv6 literal (`[::1]:23333` → `::1`).
    nonisolated static func hostname(fromHostHeader host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return trimmed }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        if let colon = trimmed.firstIndex(of: ":") {
            return String(trimmed[..<colon])
        }
        return trimmed
    }

    // MARK: - Lifecycle

    func attach(store: PermissionStore) {
        self.store = store
    }

    func attach(sessionRegistry: SessionRegistry) {
        self.sessionRegistry = sessionRegistry
    }

    func start(port: Int) throws {
        stop()
        bearerToken = Self.makeToken()
        try Self.writeTokenAndPortFiles(token: bearerToken, port: port)

        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        guard Self.isValidPort(port) else {
            status = .failed(reason: "Invalid port: \(port)")
            throw PermissionServerError.invalidPort(port)
        }
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port))!

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            status = .failed(reason: error.localizedDescription)
            throw error
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state, port: port)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.handleNewConnection(connection)
            }
        }

        self.listener = listener
        status = .starting(port: port)
        listener.start(queue: queue)
        Log.permission.notice("Server starting on 127.0.0.1:\(port)")
    }

    func stop() {
        if let listener {
            listener.cancel()
            self.listener = nil
        }
        status = .stopped
        store?.dropAll(reason: "server-stopped")
        Log.permission.notice("Server stopped")
    }

    func restart(port: Int) throws {
        stop()
        try start(port: port)
    }

    private func handleListenerState(_ state: NWListener.State, port: Int) {
        switch state {
        case .ready:
            status = .running(port: port)
            Log.permission.notice("Server ready on 127.0.0.1:\(port)")
        case .failed(let error):
            // Translate the most common errno into something a non-Network-
            // framework reader can act on directly.
            let reason = Self.friendlyError(from: error, port: port)
            Log.permission.error("Server failed: \(reason, privacy: .public)")
            status = .failed(reason: reason)
            // Don't call listener.cancel() here — it would fire .cancelled
            // and overwrite the .failed status with .stopped, hiding the
            // real reason from the UI. Just drop the reference; ARC will
            // tear the listener down.
            listener = nil
        case .cancelled:
            // Keep the previous .failed reason visible. Only blank to
            // .stopped if we genuinely cancelled an OK listener.
            if case .failed = status { return }
            status = .stopped
        default:
            break
        }
    }

    nonisolated private static func friendlyError(from error: NWError, port: Int) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use by another process."
        }
        return error.localizedDescription
    }

    // MARK: - Per-connection

    nonisolated private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.permission.error("conn failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        connection.start(queue: queue)
        // We need to keep the reader alive past the end of this scope so the
        // NWConnection.receive callback has something to deliver to. The
        // reader registers itself in `activeReaders` (strong ref) and removes
        // itself once the request has been routed.
        var reader: ConnectionReader!
        reader = ConnectionReader(connection: connection) { [weak self] request in
            guard let self else {
                Self.respond(connection: connection, status: 503, body: nil)
                return
            }
            let readerKey = ObjectIdentifier(reader)
            Task { @MainActor [weak self] in
                await self?.route(request, on: connection)
                self?.releaseReader(key: readerKey)
            }
        }
        retainReader(reader)
        reader.pump()
    }

    nonisolated private func retainReader(_ reader: AnyObject) {
        activeReadersLock.lock()
        defer { activeReadersLock.unlock() }
        activeReaders[ObjectIdentifier(reader)] = reader
    }

    nonisolated private func releaseReader(key: ObjectIdentifier) {
        activeReadersLock.lock()
        defer { activeReadersLock.unlock() }
        activeReaders.removeValue(forKey: key)
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) async {
        Log.permission.debug("\(request.method, privacy: .public) \(request.path, privacy: .public) (\(request.body.count) bytes)")

        // CSRF / DNS-rebinding guard. Loopback binding keeps the LAN out but
        // not the user's own browser; reject anything that looks browser-
        // originated (carries Origin, or a non-loopback Host) before it can
        // touch the session registry or pending bubbles. CC's hooks (curl) are
        // unaffected — they send no Origin and a `127.0.0.1` Host.
        guard Self.isTrustedHookRequest(headers: request.headers) else {
            Log.permission.error("Rejected cross-site request \(request.method, privacy: .public) \(request.path, privacy: .public) (origin=\(request.headers["origin"] ?? "nil", privacy: .public) host=\(request.headers["host"] ?? "nil", privacy: .public))")
            Self.respond(connection: connection, status: 403, body: nil)
            return
        }

        if request.method == "GET" && request.path == "/health" {
            Self.respond(connection: connection, status: 200, contentType: "application/json", body: Data(#"{"status":"ok"}"#.utf8))
            return
        }
        if request.method == "POST" && (request.path == "/state" || request.path.hasPrefix("/state/")) {
            let event = request.path == "/state" ? "" : String(request.path.dropFirst("/state/".count))
            let sourcePid = request.queryItems["pid"].flatMap(Int.init)
            handleStatePost(request, event: event, sourcePid: sourcePid)
            Self.respond(connection: connection, status: 200, body: Data("ok".utf8))
            return
        }
        if request.method == "POST" && request.path == "/permission" {
            await handlePermissionPost(request, on: connection)
            return
        }
        Self.respond(connection: connection, status: 404, body: nil)
    }

    // MARK: - /state

    private func handleStatePost(_ request: HTTPRequest, event: String, sourcePid: Int?) {
        stateEventsReceived += 1
        var object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        if let sourcePid, sourcePid > 0 {
            // Inject the bridge script's PPID (the Claude Code process). The
            // registry uses this as the seed for terminal-tab resolution.
            object["source_pid"] = sourcePid
        }
        sessionRegistry?.upsertFromHook(event: event, payload: object)

        // Cross-hook cancel: PostToolUse / PostToolUseFailure / Stop means
        // CC already moved past the tool, so any still-pending bubble for
        // the same call is stale (user answered in the chat). CC keeps
        // the /permission HTTP connection alive past that answer, so the
        // receive-EOF detector in handlePermissionPost never fires for
        // this case — these state hooks are the only reliable signal we
        // have. Ported from clawd's server-route-state.js.
        if event == "PostToolUse" || event == "PostToolUseFailure" || event == "Stop" {
            let toolUseId = (object["tool_use_id"] as? String)
                ?? (object["toolUseId"] as? String)
                ?? (object["toolUseID"] as? String)
            let toolName = object["tool_name"] as? String
            let toolInputFingerprint = (object["tool_input_fingerprint"] as? String)
                ?? PermissionRequest.fingerprint(of: PermissionJSONValue.from(object["tool_input"]))
            if let sessionId = object["session_id"] as? String, !sessionId.isEmpty {
                store?.cancelMatchingPending(
                    sessionId: sessionId,
                    toolUseId: toolUseId,
                    toolName: toolName,
                    toolInputFingerprint: toolInputFingerprint,
                    allowSingletonFallback: event == "Stop"
                )
            }
        }
    }

    // MARK: - /permission

    private func handlePermissionPost(_ request: HTTPRequest, on connection: NWConnection) async {
        Log.permission.notice("/permission POST received (\(request.body.count) bytes)")
        guard let store else {
            Self.respond(connection: connection, status: 503, body: nil)
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            Self.respond(connection: connection, status: 400, body: Data("bad json".utf8))
            return
        }
        let permissionRequest = Self.makePermissionRequest(from: object)
        permissionRequestsHandled += 1
        Log.permission.notice("permission request tool=\(permissionRequest.toolName, privacy: .public) session=\(permissionRequest.sessionId, privacy: .public) toolUseId=\(permissionRequest.toolUseId ?? "nil", privacy: .public) elicitation=\(permissionRequest.isElicitation) headless=\(permissionRequest.isHeadless) keys=\(Array(object.keys).sorted().joined(separator: ","), privacy: .public)")

        // When the user picks Allow/Deny inside the Claude Code chat (the
        // CC-side fallback prompt) instead of on our bubble, CC drops the
        // HTTP hook connection. Watching for that here lets us close the
        // bubble in sync rather than waiting on the 600s watchdog.
        // Both paths funnel through `store.drop`, which is idempotent —
        // whichever fires first wins, the other is a no-op.
        // Detect peer disconnect (= user answered in CC chat, CC closed the
        // hook socket) so we can drop the bubble immediately rather than
        // wait the 600s watchdog. NWConnection.stateUpdateHandler will NOT
        // fire on a peer FIN — `.cancelled` only happens when we ourselves
        // call `connection.cancel()`. The only reliable signal is a
        // pending `receive` that completes with `isComplete=true` (EOF) or
        // an error. We post-pump an extra receive here, after the request
        // body has already been parsed; if anything else arrives or the
        // peer closes, this fires.
        //
        // store.drop is idempotent — if the user clicks Allow on the
        // bubble first, `respond → connection.cancel()` makes this receive
        // fire too, but the entry was already removed by resolve.
        let requestId = permissionRequest.id.uuidString.prefix(8)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16) { [weak store] _, _, isComplete, error in
            if isComplete || error != nil {
                Log.permission.notice("permission-conn \(requestId, privacy: .public) peer-closed (eof=\(isComplete) err=\(error?.localizedDescription ?? "nil", privacy: .public)) → drop")
                Task { @MainActor in
                    store?.drop(permissionRequest.id, reason: "cc-disconnected")
                }
            }
        }
        // Keep the stateUpdateHandler too — covers the case where the
        // NWConnection itself errors out (network framework internal
        // failure) without producing an EOF on receive.
        connection.stateUpdateHandler = { [weak store] state in
            switch state {
            case .cancelled:
                Task { @MainActor in
                    store?.drop(permissionRequest.id, reason: "cc-disconnected")
                }
            case .failed(let error):
                Log.permission.error("conn failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    store?.drop(permissionRequest.id, reason: "cc-disconnected")
                }
            default:
                break
            }
        }

        // Watchdog: never let the request linger past CC's own hook
        // timeout. If we don't receive a click in 600s, drop and let CC
        // fall back to its chat prompt. Hoisted out of the continuation
        // closure so we can `.cancel()` it once the decision lands —
        // otherwise every short-circuit (DND / elicitation / passthrough)
        // would still leave a 10-minute sleeping task strong-retaining
        // `store`.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.permissionTimeout))
            store.drop(permissionRequest.id, reason: "timed-out")
        }
        defer { watchdog.cancel() }

        // Bridge the store's MainActor closures with a CheckedContinuation
        // so the server stays a single async function per connection.
        let decision: PermissionDecision? = await withCheckedContinuation { (cont: CheckedContinuation<PermissionDecision?, Never>) in
            let queued = store.submit(
                permissionRequest,
                resolve: { decision in
                    cont.resume(returning: decision)
                },
                drop: { _ in
                    cont.resume(returning: nil)
                }
            )
            if !queued {
                // store already invoked one of the closures synchronously.
                // Nothing else to do.
            }
        }

        if let decision, let body = decision.responseBody() {
            Self.respond(connection: connection, status: 200, contentType: "application/json", body: body)
        } else {
            // No-decision / dropped → explicit "no content" response, which
            // Claude Code treats as "fall back to the built-in chat prompt".
            Self.respond(connection: connection, status: 204, contentType: nil, body: nil)
        }
    }

    private static func makePermissionRequest(from object: [String: Any]) -> PermissionRequest {
        let toolName = (object["tool_name"] as? String) ?? "Unknown"
        let rawToolInputAny = object["tool_input"]
        let toolInput = PermissionJSONValue.from(rawToolInputAny)
        let sessionId = (object["session_id"] as? String) ?? "default"
        let agentId = (object["agent_id"] as? String) ?? "claude-code"
        let toolUseId = (object["tool_use_id"] as? String) ?? (object["toolUseId"] as? String)
        let fingerprint = (object["tool_input_fingerprint"] as? String)
            ?? PermissionRequest.fingerprint(of: toolInput)
        let isElicitation = toolName == "AskUserQuestion"
        let suggestions = parseSuggestions(object["permission_suggestions"])
        let isHeadless = (object["headless"] as? Bool) ?? false
        return PermissionRequest(
            agentId: agentId,
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            toolUseId: toolUseId,
            toolInputFingerprint: fingerprint,
            suggestions: suggestions,
            isHeadless: isHeadless,
            isElicitation: isElicitation
        )
    }

    private static func parseSuggestions(_ raw: Any?) -> [PermissionSuggestion] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let dict = entry as? [String: Any] else { return nil }
            let kindString = (dict["type"] as? String) ?? "other"
            let kind: PermissionSuggestion.Kind = (kindString == "addRules") ? .addRules : .other
            let label = renderSuggestionLabel(dict, kind: kind)
            return PermissionSuggestion(
                kind: kind,
                displayLabel: label,
                raw: PermissionJSONValue.from(dict)
            )
        }
    }

    private static func renderSuggestionLabel(_ dict: [String: Any], kind: PermissionSuggestion.Kind) -> String {
        if kind == .addRules {
            let rules = (dict["rules"] as? [[String: Any]]) ?? []
            let parts = rules.compactMap { rule -> String? in
                let tool = (rule["toolName"] as? String) ?? ""
                let content = (rule["ruleContent"] as? String) ?? ""
                if content.isEmpty { return tool.isEmpty ? nil : tool }
                if tool.isEmpty { return content }
                return "\(tool)(\(content))"
            }
            if !parts.isEmpty {
                return "Always allow \(parts.joined(separator: ", "))"
            }
        }
        if let title = dict["title"] as? String { return title }
        if let kind = dict["type"] as? String { return kind }
        return "Suggestion"
    }

    // MARK: - HTTP helpers

    nonisolated static func respond(
        connection: NWConnection,
        status: Int,
        contentType: String? = "text/plain; charset=utf-8",
        body: Data?
    ) {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        head += "Server: CCBar\r\n"
        head += "Connection: close\r\n"
        if let body, let contentType {
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
        } else {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    nonisolated private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func writeTokenAndPortFiles(token: String, port: Int) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: PermissionHookPaths.directory(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: PermissionHookPaths.tokenFileURL(), options: .atomic)
        try Data(String(port).utf8).write(to: PermissionHookPaths.portFileURL(), options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: PermissionHookPaths.tokenFileURL().path)
    }
}

enum PermissionServerError: Error, LocalizedError {
    case invalidPort(Int)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port): return "Invalid port: \(port)"
        case .bindFailed(let message): return "Bind failed: \(message)"
        }
    }
}

// MARK: - HTTP request parser

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let contentLength: Int
    let bodyRemainder: Data
    var body: Data = Data()

    static func parseHeaders(from buffer: Data) throws -> HTTPRequest {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            throw HTTPParseError.headerIncomplete
        }
        let headerSlice = buffer[..<range.lowerBound]
        guard let headerString = String(data: headerSlice, encoding: .utf8) else {
            throw HTTPParseError.invalidEncoding
        }
        // Manually split on "\r\n" rather than String.split(separator:) — the
        // latter's multi-character-separator overload has version-dependent
        // behaviour and silently returned the whole string as one element on
        // the macOS we ran into in the wild.
        let rawLines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = rawLines.first else {
            throw HTTPParseError.malformedRequestLine
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { throw HTTPParseError.malformedRequestLine }
        let method = String(parts[0]).uppercased()
        let pathPart = String(parts[1])
        let pathAndQuery = pathPart.split(separator: "?", maxSplits: 1)
        let path = pathAndQuery.first.map(String.init) ?? pathPart
        var queryItems: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = kv.first, !key.isEmpty else { continue }
                queryItems[key] = kv.count > 1 ? kv[1] : ""
            }
        }

        var headers: [String: String] = [:]
        for line in rawLines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = (headers["content-length"]).flatMap(Int.init) ?? 0
        let remainder = buffer[range.upperBound...]
        return HTTPRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            headers: headers,
            contentLength: contentLength,
            bodyRemainder: Data(remainder)
        )
    }

    func bearerMatches(token: String) -> Bool {
        if token.isEmpty { return true } // server not initialized; should not happen in production
        guard let raw = headers["authorization"] else { return false }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let prefix = "Bearer "
        guard trimmed.hasPrefix(prefix) else { return false }
        return String(trimmed.dropFirst(prefix.count)) == token
    }
}

private enum HTTPParseError: Error {
    case headerIncomplete
    case invalidEncoding
    case malformedRequestLine
}

/// Per-connection reader. NWConnection's receive callback runs on the
/// listener's serial dispatch queue, so concurrent access to `buffer` /
/// `parsedHeaders` from multiple threads is impossible — we silence Swift's
/// strict-concurrency check via `@unchecked Sendable` rather than wrapping
/// every mutation in an actor.
private final class ConnectionReader: @unchecked Sendable {
    private let connection: NWConnection
    private let onRequest: (HTTPRequest) -> Void
    private var buffer = Data()
    private var parsedHeaders: HTTPRequest?

    init(connection: NWConnection, onRequest: @escaping (HTTPRequest) -> Void) {
        self.connection = connection
        self.onRequest = onRequest
    }

    func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { chunk, _, isComplete, error in
            if let chunk { self.buffer.append(chunk) }
            if let error {
                Log.permission.error("recv error: \(error.localizedDescription, privacy: .public)")
                self.connection.cancel()
                return
            }

            if self.parsedHeaders == nil {
                if let parsed = try? HTTPRequest.parseHeaders(from: self.buffer) {
                    self.parsedHeaders = parsed
                    self.buffer = parsed.bodyRemainder
                } else if self.buffer.count > PermissionHTTPServer.maxBodyBytes {
                    PermissionHTTPServer.respond(connection: self.connection, status: 431, body: nil)
                    return
                }
            }

            if let request = self.parsedHeaders {
                let needed = request.contentLength
                if self.buffer.count >= needed {
                    let body = needed > 0 ? self.buffer.prefix(needed) : Data()
                    let finalized = HTTPRequest(
                        method: request.method,
                        path: request.path,
                        queryItems: request.queryItems,
                        headers: request.headers,
                        contentLength: needed,
                        bodyRemainder: Data(),
                        body: Data(body)
                    )
                    self.onRequest(finalized)
                    return
                }
                if needed > PermissionHTTPServer.maxBodyBytes {
                    PermissionHTTPServer.respond(connection: self.connection, status: 413, body: nil)
                    return
                }
            }

            if isComplete {
                PermissionHTTPServer.respond(connection: self.connection, status: 400, body: nil)
                return
            }
            self.pump()
        }
    }
}
