import Foundation
import Observation

/// In-app sink for `PermissionRequest` events arriving on the HTTP server.
/// Views read `pending` to render the bubble; the server adds entries via
/// ``submit(_:resolve:drop:)`` and receives a `PermissionDecision` back when
/// the user clicks a button.
///
/// **DND vs. resolve.** Two cancellation paths exist, with different semantics:
///   - ``resolve(_:decision:)`` writes a JSON response and unblocks CC.
///   - ``drop(_:reason:)`` returns "no decision", so CC falls back to its
///     in-chat approval prompt. Used for DND and for mid-flight cancellation
///     when the feature is toggled off.
@MainActor
@Observable
final class PermissionStore {

    /// What the bubble UI iterates over. The first entry is the foreground
    /// request; remaining ones surface as "+N more" badge.
    private(set) var pending: [PermissionRequest] = []

    /// Tools auto-allowed without ever surfacing a bubble. Pure-metadata
    /// task management tools have zero side effects, and asking the user
    /// to click `Allow` 50 times during a long agent run is purely friction.
    /// Mirrors clawd's `PASSTHROUGH_TOOLS`.
    let passthroughTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskStop", "TaskOutput",
    ]

    /// Toast hook: most recent rule the user permanently allowed (so the
    /// menu-bar icon can flash "Added rule X" briefly). Cleared by the UI.
    var lastAddedAllowRule: String?
    /// Most recent non-fatal permission error shown in the bubble. Used for
    /// failures like "Always" rule persistence, where resolving the request
    /// would give the user a false sense that the rule was saved.
    var lastErrorMessage: String?

    /// Last decision delivered for a request, surfaced for tests and for the
    /// menu-bar animation.
    private(set) var lastDecidedAt: Date?

    /// True when the user has flipped DND. The server checks this before
    /// queuing — if set, the connection is destroyed and CC falls back to
    /// its chat prompt.
    var doNotDisturb: Bool = false

    /// Fires every time a new request lands in `pending` (i.e. once a
    /// duplicate has been deduped and a passthrough has been auto-allowed
    /// — only "real" UI-bound arrivals trigger this). `AppEnvironment`
    /// wires it to the sound player.
    var onArrived: ((PermissionRequest) -> Void)?

    /// Fires whenever a session toggles in or out of "has a pending
    /// permission request". `AppEnvironment` wires it to
    /// ``SessionRegistry.markNeedsInput(_:_:)`` so the HUD can flip the
    /// red dot.
    var onSessionPendingChange: ((_ sessionId: String, _ needsInput: Bool) -> Void)?

    private struct PendingConnection {
        let resolve: @MainActor (PermissionDecision) -> Void
        let drop: @MainActor (String) -> Void
    }

    private struct PendingEntry {
        let request: PermissionRequest
        var connections: [PendingConnection]
    }

    private var entries: [UUID: PendingEntry] = [:]
    private var aliases: [UUID: UUID] = [:]
    private var arrivalLog: [String] = []  // fingerprints, last 50

    init() {}

    // MARK: - Server-side entry points

    /// Returns `false` when the request was short-circuited (auto-allow,
    /// headless auto-deny, dropped because DND). In those cases the server
    /// has already invoked `resolve` or `drop` via the closures and should
    /// NOT keep the connection alive.
    @discardableResult
    func submit(
        _ request: PermissionRequest,
        resolve: @escaping @MainActor (PermissionDecision) -> Void,
        drop: @escaping @MainActor (String) -> Void
    ) -> Bool {
        if doNotDisturb {
            Log.permission.notice("DND → drop, CC chat fallback (tool=\(request.toolName, privacy: .public))")
            drop("do-not-disturb")
            return false
        }

        // Headless check MUST come before the elicitation short-circuit:
        // `claude -p` has no interactive chat to fall back to, so dropping
        // an elicitation there would hang CC waiting on input that never
        // arrives. Auto-denying keeps the run deterministic.
        if request.isHeadless {
            Log.permission.notice("headless session → auto-deny (tool=\(request.toolName, privacy: .public))")
            resolve(.deny(message: "Non-interactive session; auto-denied"))
            return false
        }

        if request.isElicitation {
            // AskUserQuestion is best answered in the CC chat where the
            // user already has scrollback / context — popping a separate
            // bubble for it just splits attention. Drop and let CC fall
            // back to its inline prompt.
            Log.permission.notice("elicitation → drop, defer to CC chat (tool=\(request.toolName, privacy: .public))")
            drop("elicitation-defer-to-chat")
            return false
        }

        if passthroughTools.contains(request.toolName) {
            Log.permission.notice("passthrough → auto-allow (tool=\(request.toolName, privacy: .public))")
            resolve(.allow(message: nil))
            return false
        }

        if let fingerprint = request.toolInputFingerprint,
           let existing = pending.first(where: { $0.toolInputFingerprint == fingerprint && $0.sessionId == request.sessionId }) {
            // Same fingerprint already pending — likely a CC retry. Keep the
            // UI entry stable, but attach this new HTTP connection to the
            // existing decision so the visible bubble never points at a stale
            // socket.
            Log.permission.notice("duplicate fingerprint, attach retry (id=\(existing.id.uuidString, privacy: .public))")
            guard var entry = entries[existing.id] else {
                drop("duplicate-missing-entry")
                return false
            }
            entry.connections.append(PendingConnection(resolve: resolve, drop: drop))
            entries[existing.id] = entry
            aliases[request.id] = existing.id
            return true
        }

        let entry = PendingEntry(
            request: request,
            connections: [PendingConnection(resolve: resolve, drop: drop)]
        )
        entries[request.id] = entry
        pending.append(request)
        lastErrorMessage = nil
        if let fp = request.toolInputFingerprint {
            arrivalLog.append(fp)
            if arrivalLog.count > 50 { arrivalLog.removeFirst(arrivalLog.count - 50) }
        }
        if sessionHasOnePending(request.sessionId) {
            onSessionPendingChange?(request.sessionId, true)
        }
        onArrived?(request)
        return true
    }

    /// True when this is the only pending entry against the session — used
    /// to fire `onSessionPendingChange(_, true)` only on the *first* request.
    private func sessionHasOnePending(_ sessionId: String) -> Bool {
        pending.filter { $0.sessionId == sessionId }.count == 1
    }

    // MARK: - UI entry points

    func resolve(_ id: UUID, decision: PermissionDecision) {
        let canonicalID = aliases[id] ?? id
        guard let entry = entries.removeValue(forKey: canonicalID) else { return }
        aliases = aliases.filter { $0.value != canonicalID && $0.key != canonicalID }
        let resolvedSessionId = entry.request.sessionId
        pending.removeAll { $0.id == canonicalID }
        lastErrorMessage = nil
        lastDecidedAt = .now
        for connection in entry.connections {
            connection.resolve(decision)
        }
        if !pending.contains(where: { $0.sessionId == resolvedSessionId }) {
            onSessionPendingChange?(resolvedSessionId, false)
        }
    }

    /// Cancel a pending request when a post-hook fires for the same call —
    /// CC has already acted on the user's decision (typed in chat or
    /// pre-allowed by a rule), so the bubble can never matter anymore.
    ///
    /// Matcher ladder, ported from clawd's `findPendingPermissionForStateEvent`:
    ///   1. exact match on `(sessionId, toolUseId)` when toolUseId is present
    ///   2. `(sessionId, toolName, toolInputFingerprint)` when toolUseId is
    ///      absent on the pending entry (CC's PermissionRequest payload
    ///      drops tool_use_id in some versions — the fingerprint is the
    ///      only stable correlator we have)
    ///   3. `Stop`-event singleton fallback: if the session has exactly
    ///      one pending request, cancel it
    func cancelMatchingPending(
        sessionId: String,
        toolUseId: String?,
        toolName: String?,
        toolInputFingerprint: String?,
        allowSingletonFallback: Bool
    ) {
        let candidates = entries.values.filter { $0.request.sessionId == sessionId }
        Log.permission.notice("cancelMatchingPending session=\(sessionId, privacy: .public) toolUseId=\(toolUseId ?? "nil", privacy: .public) toolName=\(toolName ?? "nil", privacy: .public) fp=\(toolInputFingerprint ?? "nil", privacy: .public) singleton=\(allowSingletonFallback) candidates=\(candidates.count)")
        if candidates.isEmpty { return }

        if let toolUseId, !toolUseId.isEmpty,
           let match = candidates.first(where: { $0.request.toolUseId == toolUseId }) {
            Log.permission.notice("cancel match-by-toolUseId id=\(match.request.id.uuidString, privacy: .public)")
            drop(match.request.id, reason: "cc-decided-in-chat")
            return
        }

        if let toolName, !toolName.isEmpty,
           let fingerprint = toolInputFingerprint, !fingerprint.isEmpty {
            let fpMatches = candidates.filter {
                $0.request.toolName == toolName
                    && $0.request.toolInputFingerprint == fingerprint
                    && ((toolUseId?.isEmpty ?? true) || ($0.request.toolUseId?.isEmpty ?? true))
            }
            if fpMatches.count == 1 {
                Log.permission.notice("cancel match-by-fingerprint id=\(fpMatches[0].request.id.uuidString, privacy: .public)")
                drop(fpMatches[0].request.id, reason: "cc-decided-in-chat")
                return
            }
        }

        if allowSingletonFallback, candidates.count == 1 {
            Log.permission.notice("cancel match-by-singleton id=\(candidates[0].request.id.uuidString, privacy: .public)")
            drop(candidates[0].request.id, reason: "cc-decided-in-chat")
        }
    }

    /// Drop the request without sending an allow/deny decision. The server
    /// converts this to HTTP 204 so CC falls back to its chat prompt.
    func drop(_ id: UUID, reason: String) {
        let canonicalID = aliases[id] ?? id
        guard let entry = entries.removeValue(forKey: canonicalID) else { return }
        aliases = aliases.filter { $0.value != canonicalID && $0.key != canonicalID }
        let droppedSessionId = entry.request.sessionId
        pending.removeAll { $0.id == canonicalID }
        for connection in entry.connections {
            connection.drop(reason)
        }
        if !pending.contains(where: { $0.sessionId == droppedSessionId }) {
            onSessionPendingChange?(droppedSessionId, false)
        }
    }

    /// Drop every pending request — for shutdown / feature-off / port change.
    func dropAll(reason: String) {
        let snapshot = entries
        let affectedSessions = Set(snapshot.values.map { $0.request.sessionId })
        entries.removeAll()
        aliases.removeAll()
        pending.removeAll()
        for entry in snapshot.values {
            for connection in entry.connections {
                connection.drop(reason)
            }
        }
        for sessionId in affectedSessions {
            onSessionPendingChange?(sessionId, false)
        }
    }

    /// Brief flash text after writing to `settings.json.permissions.allow`.
    func noteAddedAllowRule(_ label: String) {
        lastAddedAllowRule = label
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if self.lastAddedAllowRule == label { self.lastAddedAllowRule = nil }
        }
    }

    func noteError(_ message: String) {
        lastErrorMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if self.lastErrorMessage == message { self.lastErrorMessage = nil }
        }
    }

    func request(for id: UUID) -> PermissionRequest? {
        entries[id]?.request
    }
}
