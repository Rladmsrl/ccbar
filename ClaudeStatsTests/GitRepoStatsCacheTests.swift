import Foundation
import Testing
@testable import ClaudeStats

@Suite("Git repo stats cache")
struct GitRepoStatsCacheTests {
    @Test("base and ownership stats read and write independently")
    func readWriteBaseAndOwnership() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = GitRepoStatsCache(directory: directory)
        let key = cache.key(
            repoRoot: "/repos/app",
            scope: .head,
            headHash: String(repeating: "a", count: 40),
            runtimeSignature: GitStatsRuntimeSignature(value: "runtime-a")
        )
        let base = GitRepoInspectorBaseStats(
            code: GitRepoCodeStats.unavailable(scope: .head, totalFiles: 3, warning: "missing"),
            contributors: [GitContributorStat(name: "Ada", email: "ada@example.com", commitCount: 2, share: 1)]
        )
        let ownership = GitRepoCodeOwnershipStats(
            codeContributors: [GitCodeContributionStat(name: "Ada", email: "ada@example.com", lineCount: 9, share: 1)]
        )

        cache.writeBase(base, for: key)
        cache.writeOwnership(ownership, for: key)

        #expect(cache.readBase(for: key) == base)
        #expect(cache.readOwnership(for: key) == ownership)
    }

    @Test("cache key changes with head, runtime and scope")
    func keyChangesWithInputs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = GitRepoStatsCache(directory: directory)

        let base = cache.key(repoRoot: "/repos/app", scope: .head, headHash: "a", runtimeSignature: GitStatsRuntimeSignature(value: "runtime-a"))
        let otherHead = cache.key(repoRoot: "/repos/app", scope: .head, headHash: "b", runtimeSignature: GitStatsRuntimeSignature(value: "runtime-a"))
        let otherRuntime = cache.key(repoRoot: "/repos/app", scope: .head, headHash: "a", runtimeSignature: GitStatsRuntimeSignature(value: "runtime-b"))
        let otherScope = cache.key(repoRoot: "/repos/app", scope: .workingTree, headHash: "a", runtimeSignature: GitStatsRuntimeSignature(value: "runtime-a"))

        #expect(base.digest != otherHead.digest)
        #expect(base.digest != otherRuntime.digest)
        #expect(base.digest != otherScope.digest)
    }

    @Test("schema mismatch returns nil")
    func schemaMismatchReturnsNil() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldCache = GitRepoStatsCache(directory: directory, schemaVersion: 0)
        let currentCache = GitRepoStatsCache(directory: directory, schemaVersion: 1)
        let oldKey = oldCache.key(
            repoRoot: "/repos/app",
            scope: .head,
            headHash: "a",
            runtimeSignature: GitStatsRuntimeSignature(value: "runtime-a")
        )
        let base = GitRepoInspectorBaseStats(
            code: GitRepoCodeStats.unavailable(scope: .head, totalFiles: 1, warning: "old"),
            contributors: []
        )

        oldCache.writeBase(base, for: oldKey)

        #expect(currentCache.readBase(for: oldKey) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("git-stats-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
