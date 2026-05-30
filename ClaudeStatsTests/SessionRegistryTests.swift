import Foundation
import Testing
@testable import ClaudeStats

@Suite("SessionRegistry")
@MainActor
struct SessionRegistryTests {

    // MARK: - Hook ingestion

    @Test("First hook event creates a foreground session in working state")
    func firstHookCreatesForegroundWorking() {
        let registry = SessionRegistry()
        registry.upsertFromHook(
            event: "SessionStart",
            payload: ["session_id": "s1", "cwd": "/tmp/proj"]
        )
        #expect(registry.sessions.count == 1)
        let session = registry.sessions[0]
        #expect(session.id == "s1")
        #expect(session.kind == .foreground)
        #expect(session.state == .working)
        #expect(session.cwd == "/tmp/proj")
    }

    @Test("SessionEnd hook drops the session from the registry")
    func sessionEndDropsSession() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "s1"])
        #expect(registry.sessions.count == 1)

        registry.upsertFromHook(event: "SessionEnd", payload: ["session_id": "s1"])
        #expect(registry.sessions.isEmpty)
    }

    @Test("Idle event flips state to idle")
    func idleEventFlipsState() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "s1"])
        registry.upsertFromHook(event: "Stop", payload: ["session_id": "s1"])
        #expect(registry.sessions.first?.state == .idle)
    }

    @Test("Empty session_id payload is ignored")
    func emptySessionIdIgnored() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": ""])
        registry.upsertFromHook(event: "SessionStart", payload: [:])
        #expect(registry.sessions.isEmpty)
    }

    @Test("source_pid is captured from payload")
    func sourcePidCaptured() {
        let registry = SessionRegistry()
        registry.upsertFromHook(
            event: "SessionStart",
            payload: ["session_id": "s1", "source_pid": 4242]
        )
        #expect(registry.sessions.first?.sourcePid == 4242)
    }

    // MARK: - Kind locking from agents snapshot

    @Test("agents --json upgrades existing foreground session to background")
    func agentsSnapshotUpgradesKind() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "s1"])
        #expect(registry.sessions.first?.kind == .foreground)

        registry.upsertFromAgentsList([
            ClaudeAgent(
                pid: 100,
                sessionId: "s1",
                cwd: "/",
                kind: .background,
                status: .idle,
                name: "bg-worker",
                startedAt: .now
            )
        ])
        #expect(registry.sessions.first?.kind == .background)
    }

    @Test("Hook arriving after agents snapshot keeps session locked to background")
    func hookAfterAgentsKeepsBackground() {
        let registry = SessionRegistry()
        registry.upsertFromAgentsList([
            ClaudeAgent(
                pid: 100,
                sessionId: "s1",
                cwd: "/",
                kind: .background,
                status: .idle,
                name: "bg-worker",
                startedAt: .now
            )
        ])
        #expect(registry.sessions.first?.kind == .background)

        registry.upsertFromHook(event: "PreToolUse", payload: ["session_id": "s1"])
        // Hook ingestion must not downgrade .background → .foreground
        #expect(registry.sessions.first?.kind == .background)
    }

    // MARK: - Daemon snapshot diff

    @Test("Sessions absent from a fresh agents snapshot are pruned")
    func agentsSnapshotPrunesMissingSessions() {
        let registry = SessionRegistry()
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: .now),
            ClaudeAgent(pid: 2, sessionId: "b", cwd: "/", kind: .background, status: .idle, name: "b", startedAt: .now),
        ])
        #expect(registry.sessions.count == 2)

        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: .now)
        ])
        #expect(registry.sessions.count == 1)
        #expect(registry.sessions.first?.id == "a")
    }

    @Test("Fresh hook-only session survives the agents grace window")
    func freshHookOnlySessionSurvivesGraceWindow() {
        let registry = SessionRegistry()
        // Hook-only session — never appeared in agents snapshot.
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "hook-only"])
        // Independent agents snapshot for a different session.
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-1", cwd: "/", kind: .background, status: .idle, name: "x", startedAt: .now)
        ])
        // Another snapshot that no longer mentions bg-1. Hook-only is
        // still within the default grace window (just-arrived) so it
        // must survive; bg-1 was in the roster so it's pruned.
        registry.upsertFromAgentsList([])

        #expect(registry.sessions.contains(where: { $0.id == "hook-only" }))
        #expect(!registry.sessions.contains(where: { $0.id == "bg-1" }))
    }

    @Test("Stale hook-only session is pruned once the grace window passes")
    func staleHookOnlySessionIsPrunedAfterGrace() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "hook-only"])
        // Empty snapshot taken 60s after the hook arrived — past the
        // 30s default grace window. The session should be gone (covers
        // the "claude was SIGKILLed, no SessionEnd ever fired" case).
        registry.upsertFromAgentsList([], now: .now.addingTimeInterval(60))

        #expect(!registry.sessions.contains(where: { $0.id == "hook-only" }))
    }

    @Test("A daemon-registered session pruned on the next empty snapshot")
    func daemonRegisteredSessionPrunedImmediately() {
        let registry = SessionRegistry()
        // First snapshot registers bg-1; second drops it. No grace
        // window applies here — once the daemon has stopped reporting
        // a session it's authoritatively gone.
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-1", cwd: "/", kind: .background, status: .idle, name: "x", startedAt: .now)
        ])
        registry.upsertFromAgentsList([])

        #expect(!registry.sessions.contains(where: { $0.id == "bg-1" }))
    }

    // MARK: - Unread "done" bell

    @Test("Working → done transition queues an unread bell")
    func workingToDoneRingsBell() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "s1"])
        // working → working (no bell yet)
        #expect(registry.unreadDoneSessions.isEmpty)

        registry.upsertFromHook(event: "Stop", payload: ["session_id": "s1"])
        #expect(registry.unreadDoneSessions.contains("s1"))
    }

    @Test("markRead clears the unread bell without touching state")
    func markReadClearsUnread() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "s1"])
        registry.upsertFromHook(event: "Stop", payload: ["session_id": "s1"])
        #expect(registry.unreadDoneSessions.contains("s1"))

        registry.markRead("s1")
        #expect(registry.unreadDoneSessions.isEmpty)
        #expect(registry.sessions.first?.state == .idle) // state untouched
    }

    @Test("A subsequent non-done event clears the unread bell")
    func nonDoneEventClearsUnread() {
        let registry = SessionRegistry()
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "s1"])
        registry.upsertFromHook(event: "Stop", payload: ["session_id": "s1"])
        #expect(registry.unreadDoneSessions.contains("s1"))

        registry.upsertFromHook(event: "UserPromptSubmit", payload: ["session_id": "s1"])
        #expect(registry.unreadDoneSessions.isEmpty)
    }

    // MARK: - needsInput placeholder path

    @Test("markNeedsInput creates a placeholder when session is unknown")
    func markNeedsInputCreatesPlaceholder() {
        let registry = SessionRegistry()
        registry.markNeedsInput("unknown-id", true)
        #expect(registry.sessions.count == 1)
        #expect(registry.sessions.first?.id == "unknown-id")
        #expect(registry.sessions.first?.needsInput == true)
    }

    @Test("markNeedsInput false on unknown session is a no-op (no placeholder)")
    func markNeedsInputFalseOnUnknownDoesNothing() {
        let registry = SessionRegistry()
        registry.markNeedsInput("unknown-id", false)
        #expect(registry.sessions.isEmpty)
    }

    // MARK: - visibleSessions filter

    @Test("visibleSessions includes both foreground and background sessions")
    func visibleSessionsIncludesForeground() {
        let registry = SessionRegistry()
        // FG session via hook (with cwd so displayTitle is the basename, not the id-prefix)
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "fg", "cwd": "/tmp/proj"])
        // BG session via agents snapshot
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg", cwd: "/", kind: .background, status: .idle, name: "named-bg", startedAt: .now)
        ])
        let visible = registry.visibleSessions
        #expect(visible.count == 2)
        let ids = Set(visible.map(\.id))
        #expect(ids.contains("fg"))
        #expect(ids.contains("bg"))
    }

    @Test("floating tab sessions include every foreground session even when visibleSessions hides fallback idle rows")
    func floatingTabSessionsIncludeAllForeground() {
        let registry = SessionRegistry()
        let foregroundId = "1234567890abcdef"
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": foregroundId])
        registry.upsertFromHook(event: "SubagentStop", payload: ["session_id": foregroundId])
        registry.upsertFromAgentsList([
            ClaudeAgent(
                pid: 1,
                sessionId: "bg",
                cwd: "/tmp/worker",
                kind: .background,
                status: .busy,
                name: "named-bg",
                startedAt: .now
            )
        ])

        #expect(!registry.visibleSessions.map(\.id).contains(foregroundId))
        #expect(registry.floatingTabSessions.map(\.id).contains(foregroundId))
        #expect(registry.floatingTabSessions.map(\.id).contains("bg"))
    }

    @Test("agents-managed snapshot preserves ordinary interactive rows as foreground")
    func agentsManagedSnapshotPreservesOrdinaryInteractiveRows() throws {
        let registry = SessionRegistry()
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }
        let jobs = temp.appendingPathComponent("jobs", isDirectory: true)
        try TempDir.write(
            """
            {
              "sessionId": "bg-one",
              "resumeSessionId": "bg-one",
              "daemonShort": "11111111"
            }
            """,
            to: jobs
                .appendingPathComponent("11111111", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        )
        try TempDir.write(
            """
            {
              "sessionId": "bg-two",
              "resumeSessionId": "bg-two",
              "daemonShort": "22222222"
            }
            """,
            to: jobs
                .appendingPathComponent("22222222", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        )
        let json = """
        [
          { "pid": 1, "sessionId": "bg-one", "cwd": "/tmp/one", "kind": "background", "status": "busy", "name": "one", "startedAt": 1000 },
          { "pid": 2, "sessionId": "interactive-only", "cwd": "/tmp/app", "kind": "interactive", "status": "idle", "startedAt": 2000 },
          { "pid": 3, "sessionId": "bg-two", "cwd": "/tmp/two", "kind": "background", "status": "idle", "name": "two", "startedAt": 3000 }
        ]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8), jobsDirectory: jobs).get()

        registry.upsertFromAgentsList(agents)

        #expect(registry.visibleSessions.map(\.id) == ["bg-one", "bg-two", "interactive-only"])
        #expect(registry.visibleSessions.map(\.kind) == [.background, .background, .foreground])
    }

    @Test("visibleSessions places background sessions before foreground (BG-first partition)")
    func visibleSessionsBackgroundBeforeForeground() {
        let registry = SessionRegistry()
        // FG arrives first
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "fg", "cwd": "/tmp/proj"])
        // BG arrives second
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg", cwd: "/", kind: .background, status: .idle, name: "named-bg", startedAt: .now)
        ])
        // Despite FG being older (smaller updatedAt), BG must sort first.
        #expect(registry.visibleSessions.map(\.id) == ["bg", "fg"])
    }

    @Test("visibleSessions hides background sessions with placeholder names (id-prefix titles)")
    func visibleSessionsHidesUnnamedBackground() {
        let registry = SessionRegistry()
        let id = "abcdef1234567890"
        registry.upsertFromAgentsList([
            // name is nil AND cwd is empty → makeDisplayTitle falls all the way
            // through to String(id.prefix(8)) — the placeholder title that
            // visibleSessions specifically filters out.
            ClaudeAgent(pid: 1, sessionId: id, cwd: "", kind: .background, status: .idle, name: nil, startedAt: .now)
        ])
        #expect(registry.sessions.first?.displayTitle == String(id.prefix(8)))
        #expect(registry.visibleSessions.isEmpty)
    }

    @Test("visibleSessions includes placeholder sessions when they are active")
    func visibleSessionsIncludesActivePlaceholderSessions() {
        let registry = SessionRegistry()
        let id = "abcdef1234567890"
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: id, cwd: "", kind: .background, status: .busy, name: nil, startedAt: .now)
        ])

        #expect(registry.sessions.first?.displayTitle == String(id.prefix(8)))
        #expect(registry.visibleSessions.map(\.id) == [id])
    }

    @Test("visibleSessions includes placeholder sessions when they need input")
    func visibleSessionsIncludesNeedsInputPlaceholderSessions() {
        let registry = SessionRegistry()
        let id = "abcdef1234567890"
        registry.markNeedsInput(id, true)

        #expect(registry.sessions.first?.displayTitle == String(id.prefix(8)))
        #expect(registry.visibleSessions.map(\.id) == [id])
    }

    @Test("agents resume id aliases merge into existing hook session")
    func agentsResumeIdAliasesMergeIntoHookSession() throws {
        let registry = SessionRegistry()
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }
        let jobs = temp.appendingPathComponent("jobs", isDirectory: true)
        let daemonSessionId = "2da0953c-bfc0-4419-9ac8-380d87415374"
        let resumeSessionId = "b7f942f2-172a-4c5b-ab00-9258f43ddcc7"
        try TempDir.write(
            """
            {
              "sessionId": "\(daemonSessionId)",
              "resumeSessionId": "\(resumeSessionId)",
              "daemonShort": "2da0953c"
            }
            """,
            to: jobs
                .appendingPathComponent("2da0953c", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        )
        let json = """
        [
          {
            "pid": 89537,
            "sessionId": "\(resumeSessionId)",
            "cwd": "/Users/dev/projects/demo",
            "kind": "background",
            "status": "idle",
            "name": "worker",
            "startedAt": 1779857972958
          }
        ]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8), jobsDirectory: jobs).get()
        registry.upsertFromHook(
            event: "SessionStart",
            payload: ["session_id": daemonSessionId, "cwd": "/Users/dev/projects/demo"]
        )
        registry.upsertFromAgentsList(agents)

        #expect(registry.visibleSessions.map(\.id) == [daemonSessionId])
        #expect(registry.visibleSessions.first?.kind == .background)
        #expect(registry.visibleSessions.first?.displayTitle == "worker")
        #expect(registry.visibleSessions.first?.managementId == "2da0953c")
    }

    // MARK: - 段位置稳定 (spec 2026-05-27)

    @Test("同组内按 startedAt 升序排,即使 updatedAt 顺序相反")
    func backgroundSortedByStartedAtAsc() {
        let registry = SessionRegistry()
        // bg-a 先开 (startedAt 早), bg-b 后开 (startedAt 晚)
        let early = Date(timeIntervalSince1970: 1_000)
        let late  = Date(timeIntervalSince1970: 2_000)
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: early),
            ClaudeAgent(pid: 2, sessionId: "bg-b", cwd: "/", kind: .background, status: .idle, name: "b", startedAt: late),
        ])
        // 让 bg-b 后续被 hook 摸了, updatedAt 变成现在
        registry.upsertFromHook(event: "PreToolUse", payload: ["session_id": "bg-b"])
        // 但顺序仍应是 [bg-a, bg-b], 因为按 startedAt 排
        #expect(registry.sessions.map(\.id) == ["bg-a", "bg-b"])
    }

    @Test("needsInput 不再让 session 浮顶,位置保持 startedAt asc")
    func needsInputDoesNotReorder() {
        let registry = SessionRegistry()
        let early = Date(timeIntervalSince1970: 1_000)
        let late  = Date(timeIntervalSince1970: 2_000)
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: early),
            ClaudeAgent(pid: 2, sessionId: "bg-b", cwd: "/", kind: .background, status: .idle, name: "b", startedAt: late),
        ])
        // 把 bg-b (晚开) 标 needsInput,旧规则会让它浮顶,新规则不该
        registry.markNeedsInput("bg-b", true)
        #expect(registry.sessions.map(\.id) == ["bg-a", "bg-b"])
    }

    @Test("markNeedsInput 不再 bump updatedAt")
    func needsInputDoesNotBumpUpdatedAt() {
        let registry = SessionRegistry()
        let early = Date(timeIntervalSince1970: 1_000)
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "bg-a", cwd: "/", kind: .background, status: .idle, name: "a", startedAt: early)
        ])
        let beforeUpdate = registry.sessions.first?.updatedAt
        registry.markNeedsInput("bg-a", true)
        let afterUpdate = registry.sessions.first?.updatedAt
        #expect(beforeUpdate == afterUpdate)
    }

    @Test("session 结束后剩余 session 顺序保持稳定 (compact)")
    func sessionEndKeepsOthersStable() {
        let registry = SessionRegistry()
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        // 用 agents-list 入三个 BG, startedAt 显式固定 — 比 upsertFromHook
        // (用 .now) 可控。
        registry.upsertFromAgentsList([
            ClaudeAgent(pid: 1, sessionId: "a", cwd: "/p/a", kind: .background, status: .idle, name: "a", startedAt: t1),
            ClaudeAgent(pid: 2, sessionId: "b", cwd: "/p/b", kind: .background, status: .idle, name: "b", startedAt: t2),
            ClaudeAgent(pid: 3, sessionId: "c", cwd: "/p/c", kind: .background, status: .idle, name: "c", startedAt: t3),
        ])
        #expect(registry.sessions.map(\.id) == ["a", "b", "c"])
        // 结束 b: 用 hook 触发 SessionEnd
        registry.upsertFromHook(event: "SessionEnd", payload: ["session_id": "b"])
        // 剩下 a, c, 顺序保留 (a 更早 startedAt)
        #expect(registry.sessions.map(\.id) == ["a", "c"])
    }

    @Test("BG 仍排在 FG 前面,组内按 startedAt asc")
    func backgroundBeforeForegroundWithStartedAt() {
        let registry = SessionRegistry()
        // 制造场景: FG 比 BG 先开 (startedAt 更早), 但 BG 仍应排前面
        registry.upsertFromHook(event: "SessionStart", payload: ["session_id": "fg-old", "cwd": "/p/fg"])
        registry.upsertFromAgentsList([
            ClaudeAgent(
                pid: 1, sessionId: "bg-new", cwd: "/",
                kind: .background, status: .idle, name: "bg-new",
                startedAt: Date()  // 现在,比 fg-old 晚
            )
        ])
        #expect(registry.sessions.map(\.id) == ["bg-new", "fg-old"])
    }
}
