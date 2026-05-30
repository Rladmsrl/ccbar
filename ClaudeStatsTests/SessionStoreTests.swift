import Foundation
import Testing
@testable import ClaudeStats

@Suite("Session store")
struct SessionStoreTests {
    @MainActor
    @Test("Refresh reparses same-size sessions when last modified changes")
    func refreshReparsesSameSizeModifiedSession() async {
        let provider = MutableSessionProvider(
            sessions: [
                Self.session(lastModified: Date(timeIntervalSince1970: 1_000), fileSize: 42),
            ],
            statsByID: ["project::session": Self.stats(title: "First")]
        )
        let store = SessionStore(
            registry: ProviderRegistry(providers: [provider]),
            pricing: TestPricing.table
        )

        await store.refresh()
        #expect(store.sessions.first?.stats?.title == "First")

        provider.update(
            sessions: [
                Self.session(lastModified: Date(timeIntervalSince1970: 2_000), fileSize: 42),
            ],
            statsByID: ["project::session": Self.stats(title: "Second")]
        )

        await store.refresh()

        #expect(provider.parseCalls() == 2)
        #expect(store.sessions.first?.stats?.title == "Second")
    }

    private static func session(lastModified: Date, fileSize: Int64) -> Session {
        Session(
            id: "project::session",
            externalID: "session",
            provider: .claude,
            projectDirectoryName: "project",
            filePath: "/tmp/session.jsonl",
            cwd: "/tmp/project",
            lastModified: lastModified,
            fileSize: fileSize,
            stats: nil
        )
    }

    private static func stats(title: String) -> SessionStats {
        SessionStats(
            title: title,
            messageCount: 1,
            firstActivity: nil,
            lastActivity: nil,
            models: [],
            timeline: []
        )
    }
}

private final class MutableSessionProvider: Provider, @unchecked Sendable {
    let kind: ProviderKind = .claude
    var dataDirectoryExists: Bool { true }

    private let lock = NSLock()
    private var sessions: [Session]
    private var statsByID: [String: SessionStats]
    private var parseCallCount = 0

    init(sessions: [Session], statsByID: [String: SessionStats]) {
        self.sessions = sessions
        self.statsByID = statsByID
    }

    func update(sessions: [Session], statsByID: [String: SessionStats]) {
        lock.withLock {
            self.sessions = sessions
            self.statsByID = statsByID
        }
    }

    func parseCalls() -> Int {
        lock.withLock { parseCallCount }
    }

    func discoverSessions() async -> [Session] {
        lock.withLock { sessions }
    }

    func parse(_ session: Session) async -> SessionStats? {
        lock.withLock {
            parseCallCount += 1
            return statsByID[session.id]
        }
    }
}
