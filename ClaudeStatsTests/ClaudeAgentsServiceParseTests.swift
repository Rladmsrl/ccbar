import Foundation
import Testing
@testable import ClaudeStats

@Suite("ClaudeAgentsService.parse")
struct ClaudeAgentsServiceParseTests {

    // MARK: - Happy path

    @Test("Well-formed JSON array parses into ClaudeAgent values")
    func parsesWellFormedArray() throws {
        let json = """
        [
          {
            "pid": 123,
            "sessionId": "abc-123",
            "cwd": "/tmp/foo",
            "kind": "background",
            "status": "busy",
            "name": "worker",
            "startedAt": 1700000000000
          }
        ]
        """
        let result = ClaudeAgentsService.parse(data: Data(json.utf8))
        let agents = try result.get()
        #expect(agents.count == 1)
        let agent = agents[0]
        #expect(agent.pid == 123)
        #expect(agent.sessionId == "abc-123")
        #expect(agent.cwd == "/tmp/foo")
        #expect(agent.kind == .background)
        #expect(agent.status == .busy)
        #expect(agent.name == "worker")
        #expect(agent.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Empty array parses into empty list")
    func parsesEmptyArray() throws {
        let agents = try ClaudeAgentsService.parse(data: Data("[]".utf8)).get()
        #expect(agents.isEmpty)
    }

    // MARK: - Error cases

    @Test("Top-level object (not array) is a parse failure")
    func topLevelObjectFails() {
        let result = ClaudeAgentsService.parse(data: Data("{}".utf8))
        if case .success = result { Issue.record("expected failure") }
    }

    @Test("Non-JSON bytes are a parse failure")
    func nonJSONFails() {
        let result = ClaudeAgentsService.parse(data: Data("not json".utf8))
        if case .success = result { Issue.record("expected failure") }
    }

    // MARK: - Missing-field tolerance (compactMap skips bad rows)

    @Test("Entry missing required pid is skipped, others parse")
    func skipsEntryMissingPid() throws {
        let json = """
        [
          { "sessionId": "no-pid", "cwd": "/", "kind": "background", "status": "idle", "startedAt": 0 },
          { "pid": 7, "sessionId": "ok", "cwd": "/", "kind": "background", "status": "idle", "startedAt": 0 }
        ]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8)).get()
        #expect(agents.count == 1)
        #expect(agents[0].sessionId == "ok")
    }

    @Test("Entry missing required sessionId is skipped")
    func skipsEntryMissingSessionId() throws {
        let json = """
        [{ "pid": 1, "cwd": "/", "kind": "background", "status": "idle", "startedAt": 0 }]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8)).get()
        #expect(agents.isEmpty)
    }

    // MARK: - Unknown enum values

    @Test("Unknown kind falls back to .unknown")
    func unknownKindFallsBack() throws {
        let json = """
        [{ "pid": 1, "sessionId": "s", "cwd": "/", "kind": "wildcard", "status": "idle", "startedAt": 0 }]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8)).get()
        #expect(agents.count == 1)
        #expect(agents[0].kind == .unknown)
    }

    @Test("Unknown status falls back to .unknown")
    func unknownStatusFallsBack() throws {
        let json = """
        [{ "pid": 1, "sessionId": "s", "cwd": "/", "kind": "background", "status": "compacting", "startedAt": 0 }]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8)).get()
        #expect(agents.count == 1)
        #expect(agents[0].status == .unknown)
    }

    // MARK: - Optional fields

    @Test("Missing name falls back to first 8 chars of sessionId for displayName")
    func missingNameFallsBackToSessionPrefix() throws {
        let json = """
        [{ "pid": 1, "sessionId": "abcdef1234567890", "cwd": "/", "kind": "background", "status": "idle", "startedAt": 0 }]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8)).get()
        #expect(agents.count == 1)
        #expect(agents[0].name == nil)
        #expect(agents[0].displayName == "abcdef12")
    }

    @Test("startedAt is interpreted as milliseconds since epoch")
    func startedAtIsMilliseconds() throws {
        let json = """
        [{ "pid": 1, "sessionId": "s", "cwd": "/", "kind": "background", "status": "idle", "startedAt": 1500 }]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8)).get()
        #expect(agents[0].startedAt == Date(timeIntervalSince1970: 1.5))
    }

    @Test("Background resume ids are normalized to daemon session ids")
    func backgroundResumeIdNormalizesToDaemonSessionId() throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }
        let jobs = temp.appendingPathComponent("jobs", isDirectory: true)
        try TempDir.write(
            """
            {
              "sessionId": "2da0953c-bfc0-4419-9ac8-380d87415374",
              "resumeSessionId": "b7f942f2-172a-4c5b-ab00-9258f43ddcc7",
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
            "sessionId": "b7f942f2-172a-4c5b-ab00-9258f43ddcc7",
            "cwd": "/Users/dev/projects/demo",
            "kind": "background",
            "status": "idle",
            "name": "worker",
            "startedAt": 1779857972958
          }
        ]
        """
        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8), jobsDirectory: jobs).get()
        #expect(agents.map(\.sessionId) == ["2da0953c-bfc0-4419-9ac8-380d87415374"])
        #expect(agents.map(\.managementId) == ["2da0953c"])
    }

    @Test("Interactive agents rows outside daemon jobs are preserved as foreground")
    func interactiveRowsOutsideDaemonJobsArePreserved() throws {
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
              "sessionId": "bg-two-canonical",
              "resumeSessionId": "bg-two-resume",
              "daemonShort": "22222222"
            }
            """,
            to: jobs
                .appendingPathComponent("22222222", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false)
        )

        let json = """
        [
          { "pid": 1, "sessionId": "bg-one", "cwd": "/tmp/one", "kind": "background", "status": "busy", "startedAt": 1000 },
          { "pid": 2, "sessionId": "interactive-only", "cwd": "/tmp/app", "kind": "interactive", "status": "idle", "startedAt": 2000 },
          { "pid": 3, "sessionId": "bg-two-resume", "cwd": "/tmp/two", "kind": "interactive", "status": "idle", "startedAt": 3000 }
        ]
        """

        let agents = try ClaudeAgentsService.parse(data: Data(json.utf8), jobsDirectory: jobs).get()

        #expect(agents.map(\.sessionId) == ["bg-one", "interactive-only", "bg-two-canonical"])
        #expect(agents.map(\.kind) == [.background, .interactive, .background])
        #expect(agents.map(\.managementId) == ["11111111", nil, "22222222"])
    }
}
