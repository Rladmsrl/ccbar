import Foundation
import Observation

/// One row from `claude agents --json`.
struct ClaudeAgent: Sendable, Hashable, Identifiable {
    let pid: Int
    let sessionId: String
    let managementId: String?
    let cwd: String
    let kind: Kind
    let status: Status
    let name: String?
    /// Wall-clock when the agent started. The CLI emits this in
    /// milliseconds-since-epoch.
    let startedAt: Date

    init(
        pid: Int,
        sessionId: String,
        managementId: String? = nil,
        cwd: String,
        kind: Kind,
        status: Status,
        name: String?,
        startedAt: Date
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.managementId = managementId
        self.cwd = cwd
        self.kind = kind
        self.status = status
        self.name = name
        self.startedAt = startedAt
    }

    var id: String { sessionId }

    /// What we show in the floating tab when `name` is missing. Falls back
    /// to the first 8 chars of the session id, which is what the CLI itself
    /// shows.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return String(sessionId.prefix(8))
    }

    /// Tail component of `cwd`, for the second-line subtitle.
    var projectDisplayName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    enum Kind: String, Sendable, Hashable, Codable {
        case interactive
        case background
        case unknown

        init(raw: String) {
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    enum Status: String, Sendable, Hashable, Codable {
        case idle
        case busy
        case unknown

        init(raw: String) {
            self = Status(rawValue: raw) ?? .unknown
        }
    }
}

@MainActor
@Observable
final class ClaudeAgentsService {
    private(set) var agents: [ClaudeAgent] = []
    private(set) var lastError: String?
    private(set) var lastRefreshedAt: Date?
    private(set) var isLoading = false
    private(set) var isPolling = false
    private(set) var actionStates: [String: AgentAction] = [:]

    @ObservationIgnored weak var sessionRegistry: SessionRegistry?
    @ObservationIgnored private var inflightTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    /// Path to the `claude` CLI. Discovered lazily because the CLI may live
    /// in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, etc.
    @ObservationIgnored private static let candidatePaths: [String] = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]
    @ObservationIgnored private var resolvedClaudeBinary: String?

    init() {}

    nonisolated static let commandTimeout: TimeInterval = 5
    /// How often we re-snapshot `claude agents --json`. Catches new
    /// background sessions started after launch and prunes ones the daemon
    /// has dropped. Hook traffic is much higher-frequency so this only
    /// needs to be brisk enough to feel live, not exact.
    nonisolated static let pollInterval: TimeInterval = 15
    nonisolated static let interactiveRefreshInterval: TimeInterval = 3

    /// Bootstrap + start the periodic poll. Runs `agents --json` once now
    /// to backfill the ``SessionRegistry`` with whatever the daemon already
    /// knows about, then every ``pollInterval`` seconds to reconcile (so
    /// sessions started or stopped while the app is running show up /
    /// disappear without needing a manual mutation).
    func start() {
        guard !isPolling else { return }
        isPolling = true
        refresh()
        pollTask = Task { [weak self] in
            let nanos = UInt64(Self.pollInterval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.refresh() }
            }
        }
    }

    func stop() {
        isPolling = false
        refreshGeneration += 1
        inflightTask?.cancel()
        inflightTask = nil
        isLoading = false
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() {
        guard inflightTask == nil else { return }
        guard let binary = resolveClaudeBinary() else {
            lastError = "claude CLI not found"
            return
        }
        isLoading = true
        let generation = refreshGeneration
        inflightTask = Task.detached { [weak self] in
            let result = ClaudeAgentsService.runAgentsCommand(binary: binary)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.refreshGeneration == generation else { return }
                self.inflightTask = nil
                self.isLoading = false
                self.lastRefreshedAt = .now
                switch result {
                case .success(let agents):
                    self.agents = agents.sorted { lhs, rhs in
                        // Busy first, then by recency.
                        if lhs.status == .busy && rhs.status != .busy { return true }
                        if rhs.status == .busy && lhs.status != .busy { return false }
                        return lhs.startedAt > rhs.startedAt
                    }
                    self.lastError = nil
                    self.sessionRegistry?.upsertFromAgentsList(self.agents)
                case .failure(let error):
                    self.lastError = error.message
                }
            }
        }
    }

    func refreshIfStale(maxAge: TimeInterval = interactiveRefreshInterval) {
        guard !isLoading else { return }
        guard let lastRefreshedAt else {
            refresh()
            return
        }
        if Date.now.timeIntervalSince(lastRefreshedAt) >= maxAge {
            refresh()
        }
    }

    // MARK: - Mutations

    /// Soft-stop a session via `claude stop <id>`. Re-runs `refresh()` on
    /// success so the registry mirrors the new state. Failures land in
    /// `lastError`.
    func stop(sessionId: String) async {
        await runMutation(["stop", sessionId], label: "stop", sessionId: sessionId, action: .stopping)
    }

    /// Restart a session (preserves the chat). `claude respawn <id>`.
    func respawn(sessionId: String) async {
        await runMutation(["respawn", sessionId], label: "respawn", sessionId: sessionId, action: .respawning)
    }

    /// Delete a session + its worktree (if no uncommitted changes).
    /// `claude rm <id>`. Caller should confirm with the user first —
    /// the worktree is gone afterwards.
    func remove(sessionId: String) async {
        await runMutation(["rm", sessionId], label: "rm", sessionId: sessionId, action: .removing)
    }

    private func runMutation(_ arguments: [String], label: String, sessionId: String, action: AgentAction) async {
        guard actionStates[sessionId] == nil else { return }
        guard let binary = resolveClaudeBinary() else {
            lastError = "claude CLI not found"
            return
        }
        actionStates[sessionId] = action
        let result = await Task.detached {
            ClaudeAgentsService.runSubprocess(binary: binary, arguments: arguments)
        }.value
        actionStates[sessionId] = nil
        switch result {
        case .success:
            Log.session.notice("\(label, privacy: .public) ok")
            lastError = nil
            refresh()
        case .failure(let error):
            Log.session.error("\(label, privacy: .public) failed: \(error.message, privacy: .public)")
            lastError = error.message
        }
    }

    private func resolveClaudeBinary() -> String? {
        let fileManager = FileManager.default
        if let resolvedClaudeBinary, fileManager.isExecutableFile(atPath: resolvedClaudeBinary) {
            return resolvedClaudeBinary
        }
        resolvedClaudeBinary = Self.locateClaudeBinary()
        return resolvedClaudeBinary
    }

    nonisolated private static func runSubprocess(binary: String, arguments: [String]) -> Result<String, AgentsError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.init("Failed to launch `claude \(arguments.joined(separator: " "))`: \(error.localizedDescription)"))
        }
        if finished.wait(timeout: .now() + Self.commandTimeout) == .timedOut {
            process.terminate()
            return .failure(.init("`claude \(arguments.joined(separator: " "))` timed out after \(Int(Self.commandTimeout))s"))
        }
        let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.init(trimmed.isEmpty ? "exit code \(process.terminationStatus)" : trimmed))
        }
        return .success(outText)
    }

    // MARK: - Subprocess

    nonisolated private static func runAgentsCommand(binary: String) -> Result<[ClaudeAgent], AgentsError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["agents", "--json"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.init("Failed to launch `claude agents --json`: \(error.localizedDescription)"))
        }
        if finished.wait(timeout: .now() + Self.commandTimeout) == .timedOut {
            process.terminate()
            return .failure(.init("`claude agents --json` timed out after \(Int(Self.commandTimeout))s"))
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(.init("`claude agents --json` exited with code \(process.terminationStatus): \(errText)"))
        }
        return parse(
            data: data,
            jobsDirectory: ClaudePaths.default.configDirectory.appendingPathComponent("jobs", isDirectory: true)
        )
    }

    nonisolated static func parse(data: Data) -> Result<[ClaudeAgent], AgentsError> {
        parse(data: data, jobsDirectory: nil)
    }

    nonisolated static func parse(data: Data, jobsDirectory: URL?) -> Result<[ClaudeAgent], AgentsError> {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure(.init("Unable to parse agent list"))
        }
        let identities = loadDaemonSessionIdentities(from: jobsDirectory)
        let agents: [ClaudeAgent] = array.compactMap { dict in
            guard let pid = dict["pid"] as? Int,
                  let sessionId = dict["sessionId"] as? String,
                  let cwd = dict["cwd"] as? String,
                  let kindRaw = dict["kind"] as? String,
                  let statusRaw = dict["status"] as? String,
                  let startedAtMs = dict["startedAt"] as? Double
            else { return nil }
            let rawKind = ClaudeAgent.Kind(raw: kindRaw)
            let identity = identities[sessionId]
            if jobsDirectory != nil, identity == nil, rawKind != .interactive {
                return nil
            }
            return ClaudeAgent(
                pid: pid,
                sessionId: identity?.sessionId ?? sessionId,
                managementId: identity?.managementId,
                cwd: cwd,
                kind: identity == nil ? rawKind : .background,
                status: .init(raw: statusRaw),
                name: dict["name"] as? String,
                startedAt: Date(timeIntervalSince1970: startedAtMs / 1000)
            )
        }
        return .success(dedupAgents(agents))
    }

    private struct DaemonSessionIdentity: Sendable {
        let sessionId: String
        let managementId: String?
    }

    nonisolated private static func loadDaemonSessionIdentities(from jobsDirectory: URL?) -> [String: DaemonSessionIdentity] {
        guard let jobsDirectory else { return [:] }
        guard let jobDirectories = try? FileManager.default.contentsOfDirectory(
            at: jobsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var identities: [String: DaemonSessionIdentity] = [:]
        for jobDirectory in jobDirectories {
            guard (try? jobDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let stateURL = jobDirectory.appendingPathComponent("state.json", isDirectory: false)
            guard let data = try? Data(contentsOf: stateURL),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionId = state["sessionId"] as? String,
                  !sessionId.isEmpty
            else { continue }

            let directoryShort = jobDirectory.lastPathComponent
            let stateDaemonShort = state["daemonShort"] as? String
            let managementId = firstNonEmpty(stateDaemonShort, directoryShort)
            let identity = DaemonSessionIdentity(sessionId: sessionId, managementId: managementId)

            // Some `claude agents --json` rows expose the resumed transcript id
            // instead of the daemon session id that state hooks use.
            addIdentity(sessionId, identity: identity, into: &identities)
            addIdentity(directoryShort, identity: identity, into: &identities)
            addIdentity(stateDaemonShort, identity: identity, into: &identities)
            addIdentity(state["resumeSessionId"] as? String, identity: identity, into: &identities)
            if let linkScanPath = state["linkScanPath"] as? String {
                addIdentity(
                    URL(fileURLWithPath: linkScanPath).deletingPathExtension().lastPathComponent,
                    identity: identity,
                    into: &identities
                )
            }
        }
        return identities
    }

    nonisolated private static func addIdentity(
        _ alias: String?,
        identity: DaemonSessionIdentity,
        into identities: inout [String: DaemonSessionIdentity]
    ) {
        guard let alias, !alias.isEmpty else { return }
        identities[alias] = identity
    }

    nonisolated private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.isEmpty
        } ?? nil
    }

    nonisolated private static func dedupAgents(_ agents: [ClaudeAgent]) -> [ClaudeAgent] {
        var order: [String] = []
        var bySessionId: [String: ClaudeAgent] = [:]
        for agent in agents {
            if let existing = bySessionId[agent.sessionId] {
                bySessionId[agent.sessionId] = preferredAgent(existing, over: agent)
            } else {
                order.append(agent.sessionId)
                bySessionId[agent.sessionId] = agent
            }
        }
        return order.compactMap { bySessionId[$0] }
    }

    nonisolated private static func preferredAgent(_ lhs: ClaudeAgent, over rhs: ClaudeAgent) -> ClaudeAgent {
        if lhs.kind != rhs.kind {
            if lhs.kind == .background { return lhs }
            if rhs.kind == .background { return rhs }
        }
        if lhs.status != rhs.status {
            if lhs.status == .busy { return lhs }
            if rhs.status == .busy { return rhs }
        }
        let lhsHasName = lhs.name?.isEmpty == false
        let rhsHasName = rhs.name?.isEmpty == false
        if lhsHasName != rhsHasName {
            return lhsHasName ? lhs : rhs
        }
        return lhs.startedAt <= rhs.startedAt ? lhs : rhs
    }

    private static func locateClaudeBinary() -> String? {
        let fileManager = FileManager.default
        if let candidate = candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return candidate
        }
        return locateClaudeBinaryFromPATH()
    }

    nonisolated private static func locateClaudeBinaryFromPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "claude"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if finished.wait(timeout: .now() + 1) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    struct AgentsError: Error {
        let message: String
        init(_ message: String) { self.message = message }
        var localizedDescription: String { message }
    }

    enum AgentAction: Sendable, Hashable {
        case stopping
        case respawning
        case removing
    }
}
