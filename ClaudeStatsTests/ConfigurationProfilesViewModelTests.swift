import Foundation
import Testing
@testable import ClaudeStats

@MainActor
@Suite("Configuration profiles view model")
struct ConfigurationProfilesViewModelTests {
    @Test("Project scope options are cached by provider with stable unique cwd order")
    func scopeOptionsAreCachedByProvider() async {
        let vm = makeViewModel()
        let sessions = [
            makeSession("claude-a", provider: .claude, cwd: "/work/alpha"),
            makeSession("claude-duplicate", provider: .claude, cwd: "/work/alpha"),
            makeSession("claude-empty", provider: .claude, cwd: ""),
            makeSession("claude-b", provider: .claude, cwd: "/work/beta"),
        ]

        await vm.refreshScopeOptions(from: sessions)

        #expect(vm.scopeOptions(for: .claude) == [
            .global,
            .project(path: "/work/alpha"),
            .project(path: "/work/beta"),
        ])
    }

    @Test("Loading the library rebuilds sorted profile and active-profile caches")
    func reloadRebuildsProfileCaches() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = ConfigurationProfileStore(rootDirectory: temp.appendingPathComponent("Profiles", isDirectory: true))
        let older = makeProfile(provider: .claude, name: "Older", updatedAt: Date(timeIntervalSince1970: 10))
        let newer = makeProfile(provider: .claude, name: "Newer", updatedAt: Date(timeIntervalSince1970: 20))
        try await store.saveLibrary(ConfigurationProfileLibrary(
            profiles: [older, newer],
            activeProfileIDsByProvider: [.claude: older.id]
        ))

        let vm = makeViewModel(store: store)
        await vm.reload()

        #expect(vm.profiles(for: .claude).map(\.id) == [newer.id, older.id])
        #expect(vm.activeProfile(for: .claude)?.id == older.id)
    }

    @Test("Loading the library skips persisted unsupported provider profiles")
    func reloadSkipsPersistedUnsupportedProviderProfiles() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let root = temp.appendingPathComponent("Profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let claudeID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let codexID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        try TempDir.write(
            """
            {
              "profiles" : [
                {
                  "id" : "\(claudeID.uuidString)",
                  "provider" : "claude",
                  "scope" : { "kind" : "global" },
                  "name" : "Claude",
                  "files" : [
                    {
                      "id" : "33333333-3333-3333-3333-333333333333",
                      "title" : "settings.json",
                      "path" : "/tmp/settings.json",
                      "fileKind" : "json",
                      "content" : "{}",
                      "contentHash" : "hash",
                      "capturedAt" : "2026-01-01T00:00:00Z"
                    }
                  ],
                  "createdAt" : "2026-01-01T00:00:00Z",
                  "updatedAt" : "2026-01-02T00:00:00Z"
                },
                {
                  "id" : "\(codexID.uuidString)",
                  "provider" : "codex",
                  "scope" : { "kind" : "global" },
                  "name" : "Codex",
                  "files" : [],
                  "createdAt" : "2026-01-01T00:00:00Z",
                  "updatedAt" : "2026-01-03T00:00:00Z"
                }
              ],
              "activeProfileIDsByProvider" : {
                "claude" : "\(claudeID.uuidString)",
                "codex" : "\(codexID.uuidString)"
              },
              "latestBackupDirectoryByProfileID" : {
                "\(claudeID.uuidString)" : "/tmp/claude-backup",
                "\(codexID.uuidString)" : "/tmp/codex-backup"
              }
            }
            """,
            to: root.appendingPathComponent("profiles.json", isDirectory: false)
        )

        let store = ConfigurationProfileStore(rootDirectory: root)
        let loaded = try await store.loadLibrary()
        let vm = makeViewModel(store: store)
        await vm.reload()

        #expect(loaded.profiles.map(\.id) == [claudeID])
        #expect(loaded.activeProfileIDsByProvider == [.claude: claudeID])
        #expect(loaded.latestBackupDirectoryByProfileID[claudeID] == "/tmp/claude-backup")
        #expect(loaded.latestBackupDirectoryByProfileID[codexID] == "/tmp/codex-backup")
        #expect(vm.profiles(for: .claude).map(\.id) == [claudeID])
        #expect(vm.activeProfile(for: .claude)?.id == claudeID)
    }

    @Test("Profile caches stay in sync after capture, duplicate, save, and delete")
    func mutationOperationsRefreshProfileCaches() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let claudeConfig = temp.appendingPathComponent("ClaudeConfig", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeConfig, withIntermediateDirectories: true)
        let settingsURL = claudeConfig.appendingPathComponent("settings.json", isDirectory: false)
        try #"{"theme":"dark"}"#.write(to: settingsURL, atomically: true, encoding: .utf8)

        let store = ConfigurationProfileStore(rootDirectory: temp.appendingPathComponent("Profiles", isDirectory: true))
        let registry = ProviderRegistry(pricing: TestPricing.table, claudePaths: ClaudePaths(configDirectory: claudeConfig))
        let vm = ConfigurationProfilesViewModel(store: store, registry: registry)

        await vm.reload()
        let capturedResult = await vm.captureCurrent(name: "Captured", provider: .claude, scope: .global)
        let captured = try #require(capturedResult)
        #expect(vm.profiles(for: .claude).map(\.id) == [captured.id])
        #expect(vm.activeProfile(for: .claude)?.id == captured.id)

        let copyResult = await vm.duplicate(captured)
        let copy = try #require(copyResult)
        #expect(vm.profiles(for: .claude).contains { $0.id == copy.id })

        let snapshotID = try #require(copy.files.first?.id)
        let updatedResult = await vm.saveSnapshotToProfile(
            profileID: copy.id,
            snapshotID: snapshotID,
            content: #"{"theme":"light"}"#
        )
        let updated = try #require(updatedResult)
        #expect(vm.profiles(for: .claude).first { $0.id == copy.id }?.files.first?.content == #"{"theme":"light"}"#)

        await vm.delete(updated)
        #expect(vm.profiles(for: .claude).contains { $0.id == copy.id } == false)
        #expect(vm.profiles(for: .claude).contains { $0.id == captured.id })
    }

    private func makeViewModel(
        store: ConfigurationProfileStore = ConfigurationProfileStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ConfigurationProfilesViewModelTests-\(UUID().uuidString)", isDirectory: true)
        )
    ) -> ConfigurationProfilesViewModel {
        ConfigurationProfilesViewModel(store: store, registry: ProviderRegistry(pricing: TestPricing.table))
    }

    private func makeSession(_ id: String, provider: ProviderKind, cwd: String?) -> Session {
        Session(
            id: id,
            externalID: id,
            provider: provider,
            projectDirectoryName: id,
            filePath: "/tmp/\(id).jsonl",
            cwd: cwd,
            lastModified: Date(timeIntervalSince1970: 1),
            fileSize: 1
        )
    }

    private func makeProfile(provider: ProviderKind, name: String, updatedAt: Date) -> ConfigProfile {
        ConfigProfile(
            provider: provider,
            scope: .global,
            name: name,
            files: [
                ConfigFileSnapshot(
                    title: "\(name).json",
                    path: "/tmp/\(name).json",
                    fileKind: .json,
                    content: "{}",
                    contentHash: ConfigurationProfileStore.hash("{}"),
                    capturedAt: updatedAt
                ),
            ],
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
