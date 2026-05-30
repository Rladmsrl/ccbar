import Foundation

struct GitRepoStatsService: Sendable {
    private let analyzer: GitAnalyzer
    private let cache: GitRepoStatsCache
    private let runtimeSignature: GitStatsRuntimeSignature
    private let ownershipAnalyzer: GitCodeOwnershipAnalyzer

    init(
        analyzer: GitAnalyzer = GitAnalyzer(),
        cache: GitRepoStatsCache = GitRepoStatsCache(),
        runtimeSignature: GitStatsRuntimeSignature = .current(),
        ownershipAnalyzer: GitCodeOwnershipAnalyzer = GitCodeOwnershipAnalyzer()
    ) {
        self.analyzer = analyzer
        self.cache = cache
        self.runtimeSignature = runtimeSignature
        self.ownershipAnalyzer = ownershipAnalyzer
    }

    func baseStats(for repo: GitRepo, scope: GitStatsScope) -> GitRepoInspectorBaseStats {
        let startedAt = Date()
        let key = cacheKey(for: repo, scope: scope)
        if let key, let cached = cache.readBase(for: key) {
            Log.git.info("Git base stats cache hit for \(repo.displayName, privacy: .public)")
            return cached
        }

        if key != nil {
            Log.git.info("Git base stats cache miss for \(repo.displayName, privacy: .public)")
        }

        let trackedFiles = analyzer.trackedFiles(in: repo)
        let code = GitLinguistAnalyzer().stats(repo: repo, scope: scope, trackedFiles: trackedFiles)
        let stats = GitRepoInspectorBaseStats(
            code: code,
            contributors: analyzer.contributorStats(for: repo)
        )

        if let key {
            cache.writeBase(stats, for: key)
        }
        logDuration("Git base stats loaded", repo: repo, startedAt: startedAt)
        return stats
    }

    func codeOwnershipStats(
        for repo: GitRepo,
        scope: GitStatsScope,
        codeFilePaths: [String]
    ) async -> GitRepoCodeOwnershipStats {
        let startedAt = Date()
        let key = cacheKey(for: repo, scope: scope)
        if let key, let cached = cache.readOwnership(for: key) {
            Log.git.info("Git ownership stats cache hit for \(repo.displayName, privacy: .public)")
            return cached
        }

        if key != nil {
            Log.git.info("Git ownership stats cache miss for \(repo.displayName, privacy: .public)")
        }

        let stats = await ownershipAnalyzer.stats(repo: repo, codeFiles: codeFilePaths, scope: scope)
        if let key {
            cache.writeOwnership(stats, for: key)
        }
        logDuration("Git ownership stats loaded", repo: repo, startedAt: startedAt)
        return stats
    }

    private func cacheKey(for repo: GitRepo, scope: GitStatsScope) -> GitRepoStatsCache.Key? {
        guard scope == .head, let headHash = headHash(for: repo) else { return nil }
        return cache.key(repoRoot: repo.rootPath, scope: scope, headHash: headHash, runtimeSignature: runtimeSignature)
    }

    private func headHash(for repo: GitRepo) -> String? {
        let result = GitStatsProcess.run(
            executablePath: GitAnalyzer.gitPath,
            arguments: ["-C", repo.rootPath, "rev-parse", "HEAD"],
            currentDirectoryPath: repo.rootPath
        )
        guard result.exitCode == 0 else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private func logDuration(_ message: String, repo: GitRepo, startedAt: Date) {
        let duration = String(format: "%.2f", Date().timeIntervalSince(startedAt))
        Log.git.info("\(message, privacy: .public) for \(repo.displayName, privacy: .public) in \(duration, privacy: .public)s")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
