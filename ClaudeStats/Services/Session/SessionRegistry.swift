import Foundation
import Observation

/// Authoritative in-memory store of live Claude Code sessions across both
/// data sources (CC hooks + `claude agents --json`). Two-way merge on
/// `sessionId`, last-writer-wins by `updatedAt`. Views observe `sessions`
/// directly via `@Observable`.
///
/// **What lives where**
/// - Both interactive and background sessions appear in `claude agents
///   --json` — the daemon snapshot is the authoritative live set. A hook
///   may arrive first (e.g. SessionStart before the next 15s poll); a
///   short grace window protects fresh hook-only sessions from being
///   pruned before the daemon has registered them.
/// - Hooks drive real-time `state` (working / idle) and recent-event
///   history. The snapshot provides `kind` (interactive vs background),
///   the BG task `name`, and authoritative liveness.
/// - Once we see a session id in the daemon roster we lock it to
///   `.background` if it was tagged as such; a later hook event won't
///   downgrade the classification. A fresh daemon snapshot can still
///   re-classify (the daemon is authoritative for `kind`).
@MainActor
@Observable
final class SessionRegistry {

    /// Sorted view of all currently tracked sessions. Order:
    /// BG before FG, then within each group by `startedAt` ascending.
    /// Position is stable for the entire session lifetime — hook events,
    /// `needsInput` changes, and state transitions only affect the row's
    /// color/badge, never its slot. Views can observe this directly.
    private(set) var sessions: [LiveSession] = []

    /// Session ids that finished a turn since the user last looked at the
    /// HUD. The bell icon animates next to these rows; tapping the row
    /// (or any badge change away from `.done`) clears it.
    private(set) var unreadDoneSessions: Set<String> = []

    /// Sessions the daemon currently reports as `.background`. The hook
    /// path uses this to lock a session's kind to `.background` so a
    /// fresh hook event doesn't downgrade it back to `.foreground`.
    private var knownBackgroundIds: Set<String> = []

    /// Sessions covered by the latest `claude agents --json` snapshot
    /// (any kind — interactive + background). Used to diff against the
    /// next snapshot and prune sessions the daemon has dropped; hook-only
    /// sessions never enter this set so they aren't swept away.
    private var knownDaemonIds: Set<String> = []

    /// Previous badge per session — used to detect a `* → done` transition
    /// that should ring the unread bell.
    private var previousBadges: [String: LiveSession.Badge] = [:]

    init() {}

    // MARK: - Hook ingestion

    /// Apply one CC hook event. `event` is the URL-path event name (e.g.
    /// "SessionStart"); `payload` is the parsed JSON body CC POSTed to us.
    /// Safe to call with empty `event` or empty `payload`; we just skip.
    func upsertFromHook(event: String, payload: [String: Any]) {
        guard let sessionId = (payload["session_id"] as? String), !sessionId.isEmpty else {
            return
        }
        let cwd = payload["cwd"] as? String
        let title = payload["session_title"] as? String
        // Only trust `source_pid` (injected by our server from the bridge
        // script's URL query). Avoid `payload["pid"]` fallback — CC's hook
        // payload may add a `pid` field later with different semantics
        // (e.g. a tool subprocess pid), and treating that as the terminal
        // PID would silently focus the wrong tab.
        let sourcePid = payload["source_pid"] as? Int
        let now = Date.now

        var entry = sessionsById[sessionId] ?? LiveSession(
            id: sessionId,
            displayTitle: makeDisplayTitle(explicit: title, cwd: cwd, id: sessionId),
            cwd: cwd,
            kind: knownBackgroundIds.contains(sessionId) ? .background : .foreground,
            state: .working,
            startedAt: now,
            updatedAt: now
        )

        if let title, !title.isEmpty {
            entry.displayTitle = title
        } else if entry.displayTitle.isEmpty || entry.displayTitle == String(sessionId.prefix(8)) {
            entry.displayTitle = makeDisplayTitle(explicit: nil, cwd: cwd, id: sessionId)
        }
        if let cwd, !cwd.isEmpty { entry.cwd = cwd }
        if let sourcePid, sourcePid > 0 { entry.sourcePid = sourcePid }

        entry.lastEvent = event
        if !event.isEmpty {
            entry.recentEvents.append(.init(event: event, at: now))
            if entry.recentEvents.count > LiveSession.recentEventLimit {
                entry.recentEvents.removeFirst(entry.recentEvents.count - LiveSession.recentEventLimit)
            }
        }
        if LiveSession.workingEvents.contains(event) {
            entry.state = .working
        } else if LiveSession.idleEvents.contains(event) {
            entry.state = .idle
        }
        entry.updatedAt = now

        // SessionEnd → drop from the registry (after a brief tail to let the
        // UI flash "done"). Caller can re-add on the next SessionStart.
        if event == "SessionEnd" {
            sessionsById.removeValue(forKey: sessionId)
            knownBackgroundIds.remove(sessionId)
            rebuildSorted()
            Log.session.notice("hook=SessionEnd ended session=\(sessionId, privacy: .public)")
            return
        }

        sessionsById[sessionId] = entry
        rebuildSorted()
        Log.session.notice("hook=\(event, privacy: .public) session=\(sessionId, privacy: .public) state=\(entry.state.rawValue, privacy: .public) kind=\(entry.kind.rawValue, privacy: .public) pid=\(entry.sourcePid ?? 0) registry=\(self.sessions.count)")
    }

    // MARK: - agents --json ingestion

    /// Reconcile the registry against the latest `claude agents --json`
    /// snapshot. The daemon is authoritative for the live set — sessions
    /// missing from the snapshot are pruned, with one exception:
    /// hook-only sessions still within `hookGracePeriod` are kept (covers
    /// the gap between a SessionStart hook arriving and the daemon
    /// registering the process before the next poll).
    ///
    /// `agent.kind` is honoured: `.interactive` agents land in the registry
    /// as ``LiveSession/Kind/foreground`` so the visibility filter and the
    /// row-actions menu treat them as terminal sessions (no Stop/Respawn).
    func upsertFromAgentsList(
        _ agents: [ClaudeAgent],
        hookGracePeriod: TimeInterval = 30,
        now: Date = .now
    ) {
        let incomingIds = Set(agents.map(\.sessionId))

        // Prune anything not in this snapshot. Sessions previously seen
        // in a daemon roster (`knownDaemonIds`) are dropped immediately —
        // the daemon stopped tracking them, they're gone. Hook-only
        // sessions get a grace window so a fresh SessionStart that hasn't
        // shown up in `agents --json` yet isn't killed prematurely.
        let staleIds: [String] = sessionsById.compactMap { id, entry in
            guard !incomingIds.contains(id) else { return nil }
            let wasInRoster = knownDaemonIds.contains(id)
            if !wasInRoster, now.timeIntervalSince(entry.updatedAt) <= hookGracePeriod {
                return nil
            }
            return id
        }
        for id in staleIds {
            sessionsById.removeValue(forKey: id)
        }
        knownDaemonIds = incomingIds
        knownBackgroundIds = Set(agents.lazy.filter { $0.kind == .background }.map(\.sessionId))

        for agent in agents {
            let mappedKind = Self.kind(for: agent.kind)
            if var existing = sessionsById[agent.sessionId] {
                // The daemon is authoritative for kind — if it now says a
                // session is interactive, trust that over a stale `.background`
                // pinning from the previous snapshot. The "background sticks"
                // guard only applies to hook → daemon ordering: a hook can't
                // downgrade kind, but a fresh daemon snapshot can.
                existing.kind = mappedKind
                existing.managementId = agent.managementId
                if let name = agent.name, !name.isEmpty { existing.displayTitle = name }
                if existing.cwd == nil || (existing.cwd?.isEmpty ?? true) {
                    existing.cwd = agent.cwd
                }
                if existing.sourcePid == nil, agent.pid > 0 {
                    existing.sourcePid = agent.pid
                }
                // Hook events drive `state`; only seed it if we haven't yet.
                if existing.lastEvent == nil {
                    existing.state = (agent.status == .busy) ? .working : .idle
                }
                existing.updatedAt = max(existing.updatedAt, now)
                sessionsById[agent.sessionId] = existing
            } else {
                let title = (agent.name?.isEmpty == false)
                    ? agent.name!
                    : makeDisplayTitle(explicit: nil, cwd: agent.cwd, id: agent.sessionId)
                let entry = LiveSession(
                    id: agent.sessionId,
                    managementId: agent.managementId,
                    displayTitle: title,
                    cwd: agent.cwd,
                    kind: mappedKind,
                    state: (agent.status == .busy) ? .working : .idle,
                    sourcePid: agent.pid > 0 ? agent.pid : nil,
                    startedAt: agent.startedAt,
                    updatedAt: now
                )
                sessionsById[agent.sessionId] = entry
            }
        }
        rebuildSorted()
        Log.session.notice("agents-list: \(agents.count) session(s), registry now has \(self.sessions.count) (\(self.visibleSessions.count) user-visible)")
    }

    private static func kind(for agentKind: ClaudeAgent.Kind) -> LiveSession.Kind {
        switch agentKind {
        case .interactive: .foreground
        case .background: .background
        case .unknown: .foreground
        }
    }

    // MARK: - PermissionStore integration

    /// Called by `PermissionStore` when a permission request arrives or
    /// resolves. Flips the `needsInput` flag — position is unchanged because
    /// the sort key is `startedAt` (a `let`). TabGlowOverlay picks up the
    /// flag and renders the red pulse on that session's segment in place.
    func markNeedsInput(_ sessionId: String, _ needsInput: Bool) {
        guard var entry = sessionsById[sessionId] else {
            // Hook system may not have fired SessionStart yet; create a
            // placeholder so the badge shows up.
            if needsInput {
                let placeholder = LiveSession(
                    id: sessionId,
                    displayTitle: String(sessionId.prefix(8)),
                    state: .working,
                    needsInput: true
                )
                sessionsById[sessionId] = placeholder
                rebuildSorted()
            }
            return
        }
        if entry.needsInput == needsInput { return }
        entry.needsInput = needsInput
        // 排序键已改为 startedAt, 不再需要 bump updatedAt 让 session 浮顶。
        // bump updatedAt 还会污染 overflow 段的 kind 推断 (取 max(updatedAt))。
        sessionsById[sessionId] = entry
        rebuildSorted()
    }

    // MARK: - Test / debug helpers

    func reset() {
        sessionsById.removeAll()
        knownBackgroundIds.removeAll()
        knownDaemonIds.removeAll()
        previousBadges.removeAll()
        unreadDoneSessions.removeAll()
        sessions = []
    }

    // MARK: - Visibility

    /// Subset of ``sessions`` the user actually cares about — sessions with
    /// a meaningful title. Background sessions sort before foreground;
    /// within each group the order from `sessions` is preserved (BG before FG,
    /// `startedAt` ascending within each group). See spec
    /// docs/superpowers/specs/2026-05-27-tab-position-stability-design.md §2.
    var visibleSessions: [LiveSession] {
        let filtered = sessions.filter { session in
            let title = session.displayTitle
            guard !title.isEmpty else { return false }
            if title != String(session.id.prefix(8)) { return true }
            return session.badge != .idle
        }
        let bg = filtered.filter { $0.kind == .background }
        let fg = filtered.filter { $0.kind != .background }
        return bg + fg
    }

    /// Floating-tab source list. Foreground/headless sessions are always
    /// included so the tab remains a complete "what is open?" surface.
    /// Background sessions keep the stricter visibility filter and are
    /// later hidden/summarized by `FloatingSessionActionPresenter` when
    /// they are quiet.
    var floatingTabSessions: [LiveSession] {
        let visibleBackground = visibleSessions.filter { $0.kind == .background }
        let foreground = sessions.filter { $0.kind != .background }
        return visibleBackground + foreground
    }

    // MARK: - Internals

    private var sessionsById: [String: LiveSession] = [:]

    private func rebuildSorted() {
        // Track badge transitions to drive the unread-done bell.
        let currentBadges = sessionsById.mapValues(\.badge)
        for (id, current) in currentBadges {
            let previous = previousBadges[id]
            if current != .done {
                // Any non-done badge clears the bell (user implicitly
                // saw the session move on).
                unreadDoneSessions.remove(id)
            } else if let previous, previous != .done {
                // *→done transition while no one was watching → ring.
                unreadDoneSessions.insert(id)
            }
        }
        previousBadges = currentBadges
        let aliveIds = Set(currentBadges.keys)
        unreadDoneSessions = unreadDoneSessions.intersection(aliveIds)

        // 段位置稳定化 (spec 2026-05-27):
        // - BG 在 FG 上方 (跟 visibleSessions 的分组规则一致)
        // - 组内按 startedAt 升序: 最早开的在最上, 整个 session 生命周期内
        //   不变 (startedAt 是 let)。needsInput / 状态变化 / hook 涌入
        //   都不影响位置, 只影响该段的颜色。
        sessions = sessionsById.values.sorted { lhs, rhs in
            if (lhs.kind == .background) != (rhs.kind == .background) {
                return lhs.kind == .background
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    /// Called by the row view when the user clicks (or otherwise
    /// acknowledges) a session. Clears the bell without altering badges.
    func markRead(_ sessionId: String) {
        guard unreadDoneSessions.contains(sessionId) else { return }
        unreadDoneSessions.remove(sessionId)
    }

    private func makeDisplayTitle(explicit: String?, cwd: String?, id: String) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let cwd, !cwd.isEmpty {
            let basename = (cwd as NSString).lastPathComponent
            if !basename.isEmpty { return basename }
        }
        return String(id.prefix(8))
    }
}
