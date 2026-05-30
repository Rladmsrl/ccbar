import Foundation
import Testing
@testable import ClaudeStats

@MainActor
@Suite("Skills store")
struct SkillsStoreTests {
    @Test("Loads local skills, filters groups, and preserves valid selection")
    func localFilteringAndSelection() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        try TempDir.write(
            """
            ---
            name: Alpha Skill
            description: Helps alpha projects
            ---
            """,
            to: root.appendingPathComponent(".codex/skills/alpha/SKILL.md")
        )
        try TempDir.write(
            """
            ---
            name: Beta Skill
            description: Helps beta projects
            ---
            """,
            to: root.appendingPathComponent(".claude/skills/beta/SKILL.md")
        )

        let store = SkillsStore(
            scanner: SkillsLocalScanner(homeDirectory: root),
            client: FakeSkillsShClient(),
            credentials: InMemorySkillsShCredentialStore()
        )

        await store.loadIfNeeded(sessions: [])
        #expect(store.snapshot.summary.groupCount == 2)
        #expect(store.headerSummaryText.contains("2 skills"))
        #expect(store.selectedLocalGroup?.name == "Alpha Skill")
        let initialDetail = try #require(store.selectedLocalDetail)
        #expect(initialDetail.title == "Alpha Skill")
        #expect(initialDetail.copyCount == 1)
        #expect(initialDetail.primaryFacts.contains { $0.label == "Provider" && $0.value == "Codex" })
        await store.loadSelectedLocalMarkdownDocument()
        #expect(store.selectedLocalMarkdownDocument?.text.contains("Alpha Skill") == true)
        #expect(store.selectedLocalDetailModel == initialDetail)

        store.searchText = "beta"
        store.syncLocalSelection()
        #expect(store.filteredLocalGroups.map(\.name) == ["Beta Skill"])
        #expect(store.visibleLocalRows.map(\.name) == ["Beta Skill"])
        #expect(store.visibleLocalRows.first?.providerBadges == ["Claude"])
        #expect(store.selectedLocalGroup?.name == "Beta Skill")
        #expect(store.selectedLocalDetail?.title == "Beta Skill")

        store.selectedProviderID = "codex"
        store.searchText = ""
        store.syncLocalSelection()
        #expect(store.filteredLocalGroups.map(\.name) == ["Alpha Skill"])
        #expect(store.groupsByID[store.selectedLocalGroupID ?? ""]?.name == "Alpha Skill")

        store.selectedTab = .discover
        store.searchText = "react"
        #expect(store.discoverSearchText == "react")
        #expect(store.localSearchText.isEmpty)
        #expect(store.visibleLocalRows.map(\.name) == ["Alpha Skill"])
    }

    @Test("Remote search uses saved API key, caches detail, and reports install state")
    func remoteSearchAndDetail() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let localSkill = root.appendingPathComponent(".codex/skills/react-native", isDirectory: true)
        try TempDir.write(
            """
            ---
            name: React Native
            description: Local copy
            ---
            """,
            to: localSkill.appendingPathComponent("SKILL.md")
        )

        let fakeClient = FakeSkillsShClient()
        fakeClient.searchResults = [
            RemoteSkillSummary(
                id: "expo/skills/react-native",
                slug: "react-native",
                name: "React Native",
                source: "expo/skills",
                installs: 100,
                installURL: "https://github.com/expo/skills",
                url: "https://skills.sh/expo/skills/react-native"
            ),
        ]
        fakeClient.details["expo/skills/react-native"] = RemoteSkillDetail.testValue(
            id: "expo/skills/react-native",
            hash: "remote-hash"
        )
        fakeClient.audits["expo/skills/react-native"] = SkillsShAuditReport(
            id: "expo/skills/react-native",
            source: "expo/skills",
            slug: "react-native",
            audits: [
                SkillsShAuditEntry(
                    provider: "Socket",
                    slug: "socket",
                    status: "pass",
                    summary: "No alerts",
                    auditedAt: nil,
                    riskLevel: "LOW",
                    categories: []
                ),
            ]
        )

        let credentials = InMemorySkillsShCredentialStore(apiKey: "sk_test")
        let store = SkillsStore(
            scanner: SkillsLocalScanner(homeDirectory: root),
            client: fakeClient,
            credentials: credentials
        )

        await store.loadIfNeeded(sessions: [])
        store.selectedTab = .discover
        store.searchText = "react"
        await store.searchOrLoadTrending()

        let remote = try #require(store.remoteResults.first)
        #expect(remote.id == "expo/skills/react-native")
        #expect(store.installState(for: remote) == .possiblyInstalled)
        #expect(store.discoverRows.first?.installState == .possiblyInstalled)

        store.selectRemoteSkill(remote)
        await store.loadRemoteDetail(id: remote.id)
        await store.waitForLocalHashRefresh()

        #expect(store.remoteDetails[remote.id]?.detail?.hash == "remote-hash")
        #expect(store.remoteDetails[remote.id]?.audit?.audits.first?.provider == "Socket")
        #expect(store.remoteDetails[remote.id]?.skillMarkdown?.contains("React Native") == true)
        #expect(store.remoteDetails[remote.id]?.fileEntries.first?.path == "SKILL.md")
        #expect(store.installState(for: remote) == .outOfDate)
        #expect(store.discoverRows.first?.installState == .outOfDate)
        let remoteDetail = try #require(store.selectedRemoteDetail)
        #expect(remoteDetail.title == "React Native")
        #expect(remoteDetail.installStateTitle == SkillInstallState.outOfDate.title)
        #expect(remoteDetail.markdownDocument?.text.contains("React Native") == true)
        #expect(remoteDetail.files.first?.path == "SKILL.md")
        #expect(remoteDetail.files.first?.byteCountText?.isEmpty == false)
        #expect(remoteDetail.audits.first?.provider == "Socket")
        #expect(remoteDetail.audits.first?.auditedAtText == nil)
        #expect(remoteDetail.actions.installCommand?.contains("npx skills add") == true)
        #expect(store.selectedRemoteDetailModel == remoteDetail)
    }

    @Test("Remote install state upgrades after full local hashes arrive")
    func remoteInstallStateUpgradesAfterFullHash() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let localSkill = root.appendingPathComponent(".codex/skills/react-native", isDirectory: true)
        try TempDir.write(
            """
            ---
            name: React Native
            description: Local copy
            ---
            """,
            to: localSkill.appendingPathComponent("SKILL.md")
        )
        try TempDir.write("helper", to: localSkill.appendingPathComponent("references/helper.md"))

        let roots = [
            SkillRootDefinition(
                provider: SkillProviderDefinition(id: "codex", displayName: "Codex"),
                scope: .global,
                url: root.appendingPathComponent(".codex/skills", isDirectory: true),
                maxDepth: 4
            ),
        ]
        let indexSnapshot = SkillsLocalScanner.scanSync(roots: roots, scannedAt: Date(timeIntervalSince1970: 1), mode: .indexOnly)
        let fullHashSnapshot = SkillsLocalScanner.scanSync(roots: roots, scannedAt: Date(timeIntervalSince1970: 2), mode: .fullHash)
        let localHash = try #require(fullHashSnapshot.skills.first?.contentHash)

        let remote = RemoteSkillSummary(
            id: "expo/skills/react-native",
            slug: "react-native",
            name: "React Native",
            source: "expo/skills"
        )
        let fakeClient = FakeSkillsShClient()
        fakeClient.searchResults = [remote]
        fakeClient.details[remote.id] = RemoteSkillDetail.testValue(id: remote.id, hash: localHash)

        let store = SkillsStore(
            scanner: DelayedFullHashScanner(indexSnapshot: indexSnapshot, fullHashSnapshot: fullHashSnapshot),
            client: fakeClient,
            credentials: InMemorySkillsShCredentialStore(apiKey: "sk_test")
        )

        await store.loadIfNeeded(sessions: [])
        store.selectedTab = .discover
        store.searchText = "react"
        await store.searchOrLoadTrending()
        store.selectRemoteSkill(remote)
        await store.loadRemoteDetail(id: remote.id)

        #expect(store.installState(for: remote) == .possiblyInstalled)
        await store.waitForLocalHashRefresh()
        #expect(store.installState(for: remote) == .installed)
        #expect(store.discoverRows.first?.installState == .installed)
    }

    @Test("Project root changes during scanning trigger a pending reload")
    func projectRootChangesDuringScanningTriggerPendingReload() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstRoot = root.appendingPathComponent("first/.codex/skills", isDirectory: true)
        try TempDir.write(
            """
            ---
            name: Alpha Skill
            ---
            """,
            to: firstRoot.appendingPathComponent("alpha/SKILL.md")
        )
        let secondRoot = root.appendingPathComponent("second/.codex/skills", isDirectory: true)
        try TempDir.write(
            """
            ---
            name: Beta Skill
            ---
            """,
            to: secondRoot.appendingPathComponent("beta/SKILL.md")
        )

        let provider = SkillProviderDefinition(id: "codex", displayName: "Codex")
        let firstSnapshot = SkillsLocalScanner.scanSync(
            roots: [SkillRootDefinition(provider: provider, scope: .global, url: firstRoot, maxDepth: 4)],
            scannedAt: Date(timeIntervalSince1970: 1),
            mode: .indexOnly
        )
        let secondSnapshot = SkillsLocalScanner.scanSync(
            roots: [SkillRootDefinition(provider: provider, scope: .global, url: secondRoot, maxDepth: 4)],
            scannedAt: Date(timeIntervalSince1970: 2),
            mode: .indexOnly
        )
        let scannerState = QueuedSkillsScannerState(
            indexSnapshots: [firstSnapshot, secondSnapshot],
            fullHashSnapshot: secondSnapshot
        )
        let store = SkillsStore(
            scanner: QueuedSkillsScanner(state: scannerState),
            client: FakeSkillsShClient(),
            credentials: InMemorySkillsShCredentialStore()
        )

        async let firstReload: Void = store.reloadLocal(sessions: [makeSession(cwd: root.appendingPathComponent("first").path)])
        try? await Task.sleep(nanoseconds: 25_000_000)
        await store.reloadLocalIfProjectRootsChanged(sessions: [makeSession(cwd: root.appendingPathComponent("second").path)])
        await firstReload

        #expect(await scannerState.indexScanCount() == 2)
        #expect(store.visibleLocalRows.map(\.name) == ["Beta Skill"])
        #expect(store.selectedLocalDetail?.title == "Beta Skill")
    }

    @Test("Curated rows cache remote lookup and selected skill")
    func curatedRowsCacheRemoteLookup() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = RemoteSkillSummary(
            id: "owner/repo/skill",
            slug: "skill",
            name: "Skill",
            source: "owner/repo",
            installs: 42
        )
        let hiddenRemote = RemoteSkillSummary(
            id: "owner/repo/hidden",
            slug: "hidden",
            name: "Hidden",
            source: "owner/repo",
            installs: 1
        )
        let fakeClient = FakeSkillsShClient()
        fakeClient.curatedOwners = [
            SkillsShCuratedOwner(
                owner: "owner",
                totalInstalls: 42,
                featuredRepo: nil,
                featuredSkill: nil,
                skills: [remote, hiddenRemote]
            ),
        ]
        let store = SkillsStore(
            scanner: SkillsLocalScanner(homeDirectory: root),
            client: fakeClient,
            credentials: InMemorySkillsShCredentialStore(apiKey: "sk_test")
        )

        store.selectedTab = .curated
        await store.loadCurated()

        #expect(store.curatedOwnerRows.first?.owner == "owner")
        #expect(store.curatedOwnerRows.first?.skills.first?.skill.id == remote.id)
        store.selectRemoteSkill(remote)
        #expect(store.selectedRemoteSkill?.id == remote.id)

        store.searchText = "hidden"
        #expect(store.curatedSearchText == "hidden")
        #expect(store.curatedOwnerRows.first?.skills.map(\.skill.id) == [hiddenRemote.id])
        #expect(store.selectedRemoteSkill?.id == hiddenRemote.id)
    }

    @Test("Remote operations use cached API key after startup")
    func remoteOperationsUseCachedAPIKey() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let credentials = OneShotSkillsShCredentialStore(apiKey: "sk_cached")
        let fakeClient = FakeSkillsShClient()
        fakeClient.leaderboardResults = [
            RemoteSkillSummary(id: "owner/repo/skill", slug: "skill", name: "Skill"),
        ]
        let store = SkillsStore(
            scanner: SkillsLocalScanner(homeDirectory: root),
            client: fakeClient,
            credentials: credentials
        )

        store.selectedTab = .discover
        await store.searchOrLoadTrending()

        #expect(store.remoteResults.first?.id == "owner/repo/skill")
        #expect(credentials.readCount == 1)
    }
}

final class FakeSkillsShClient: SkillsShClienting, @unchecked Sendable {
    var leaderboardResults: [RemoteSkillSummary] = []
    var searchResults: [RemoteSkillSummary] = []
    var curatedOwners: [SkillsShCuratedOwner] = []
    var details: [String: RemoteSkillDetail] = [:]
    var audits: [String: SkillsShAuditReport] = [:]

    func leaderboard(apiKey: String, view: String, limit: Int) async throws -> [RemoteSkillSummary] {
        leaderboardResults
    }

    func search(query: String, apiKey: String, limit: Int) async throws -> [RemoteSkillSummary] {
        searchResults
    }

    func curated(apiKey: String) async throws -> [SkillsShCuratedOwner] {
        curatedOwners
    }

    func detail(id: String, apiKey: String) async throws -> RemoteSkillDetail {
        guard let detail = details[id] else { throw SkillsShClient.ClientError.notFound }
        return detail
    }

    func audit(id: String, apiKey: String) async throws -> SkillsShAuditReport? {
        audits[id]
    }
}

private struct DelayedFullHashScanner: SkillsLocalScanning {
    let indexSnapshot: SkillsSnapshot
    let fullHashSnapshot: SkillsSnapshot

    func scan(sessions: [Session], mode: SkillsScanMode) async -> SkillsSnapshot {
        switch mode {
        case .indexOnly:
            return indexSnapshot
        case .fullHash:
            try? await Task.sleep(nanoseconds: 150_000_000)
            return fullHashSnapshot
        }
    }
}

private struct QueuedSkillsScanner: SkillsLocalScanning {
    let state: QueuedSkillsScannerState

    func scan(sessions: [Session], mode: SkillsScanMode) async -> SkillsSnapshot {
        await state.scan(mode: mode)
    }
}

private actor QueuedSkillsScannerState {
    private var indexSnapshots: [SkillsSnapshot]
    private let fullHashSnapshot: SkillsSnapshot
    private var indexCalls = 0

    init(indexSnapshots: [SkillsSnapshot], fullHashSnapshot: SkillsSnapshot) {
        self.indexSnapshots = indexSnapshots
        self.fullHashSnapshot = fullHashSnapshot
    }

    func scan(mode: SkillsScanMode) async -> SkillsSnapshot {
        switch mode {
        case .indexOnly:
            indexCalls += 1
            if indexCalls == 1 {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !indexSnapshots.isEmpty else { return .empty }
            return indexSnapshots.removeFirst()
        case .fullHash:
            return fullHashSnapshot
        }
    }

    func indexScanCount() -> Int {
        indexCalls
    }
}

private func makeSession(cwd: String) -> Session {
    Session(
        id: "claude::\(cwd)",
        externalID: cwd,
        provider: .claude,
        projectDirectoryName: cwd.replacingOccurrences(of: "/", with: "-"),
        filePath: "\(cwd)/session.jsonl",
        cwd: cwd,
        lastModified: Date(timeIntervalSince1970: 100),
        fileSize: 100,
        stats: nil
    )
}

final class OneShotSkillsShCredentialStore: SkillsShCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private(set) var readCount = 0

    init(apiKey: String) {
        value = apiKey
    }

    func readAPIKey() -> String? {
        lock.withLock {
            readCount += 1
            defer { value = nil }
            return value
        }
    }

    func saveAPIKey(_ apiKey: String) {
        lock.withLock { value = apiKey }
    }

    func deleteAPIKey() {
        lock.withLock { value = nil }
    }
}

private extension RemoteSkillDetail {
    static func testValue(id: String, hash: String?) -> RemoteSkillDetail {
        let data = Data(
            """
            {
              "id": "\(id)",
              "source": "expo/skills",
              "slug": "react-native",
              "installs": 10,
              "hash": \(hash.map { "\"\($0)\"" } ?? "null"),
              "files": [
                { "path": "SKILL.md", "contents": "---\\nname: React Native\\n---\\n" }
              ]
            }
            """.utf8
        )
        return try! JSONDecoder().decode(RemoteSkillDetail.self, from: data)
    }
}
