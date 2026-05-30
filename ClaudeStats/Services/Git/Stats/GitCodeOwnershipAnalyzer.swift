import Foundation

struct GitCodeContributionCounter: Sendable, Equatable {
    let name: String
    let email: String
    var lineCount: Int

    var key: String { "\(name.lowercased())|\(email.lowercased())" }
}

struct GitCodeOwnershipAnalyzer: Sendable {
    let maxConcurrentBlameJobs: Int

    init(maxConcurrentBlameJobs: Int = Self.defaultMaxConcurrentBlameJobs) {
        self.maxConcurrentBlameJobs = max(1, maxConcurrentBlameJobs)
    }

    static var defaultMaxConcurrentBlameJobs: Int {
        min(3, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    func stats(repo: GitRepo, codeFiles: [String], scope: GitStatsScope) async -> GitRepoCodeOwnershipStats {
        let paths = Array(Set(codeFiles.map { Self.repoRelativePath($0, repoRoot: repo.rootPath) }))
            .filter { !$0.isEmpty }
            .sorted()
        guard !paths.isEmpty else { return .empty }

        var merged: [String: GitCodeContributionCounter] = [:]
        var index = 0
        while index < paths.count {
            guard !Task.isCancelled else { return GitRepoCodeOwnershipStats(codeContributors: Self.stats(from: Array(merged.values))) }
            let end = min(paths.count, index + maxConcurrentBlameJobs)
            let batch = Array(paths[index..<end])

            await withTaskGroup(of: [GitCodeContributionCounter].self) { group in
                for path in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return [] }
                        return Self.blameCounters(repo: repo, path: path, scope: scope)
                    }
                }
                for await counters in group {
                    Self.merge(counters, into: &merged)
                }
            }

            index = end
        }

        return GitRepoCodeOwnershipStats(codeContributors: Self.stats(from: Array(merged.values)))
    }

    static func parsePorcelainBlameCounters(_ output: String) -> [GitCodeContributionCounter] {
        struct AuthorMetadata {
            var name: String
            var email: String
        }

        var metadataByHash: [String: AuthorMetadata] = [:]
        var currentHash: String?
        var counters: [String: GitCodeContributionCounter] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let hash = blameHeaderHash(line) {
                currentHash = hash
                continue
            }

            if line.hasPrefix("author "), let currentHash {
                var metadata = metadataByHash[currentHash] ?? AuthorMetadata(name: "", email: "")
                metadata.name = String(line.dropFirst("author ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                metadataByHash[currentHash] = metadata
                continue
            }

            if line.hasPrefix("author-mail "), let currentHash {
                var metadata = metadataByHash[currentHash] ?? AuthorMetadata(name: "", email: "")
                metadata.email = normalizeBlameEmail(String(line.dropFirst("author-mail ".count)))
                metadataByHash[currentHash] = metadata
                continue
            }

            guard line.hasPrefix("\t"), let currentHash else { continue }
            let content = String(line.dropFirst())
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let metadata = metadataByHash[currentHash] else {
                continue
            }

            let name = metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = metadata.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !email.isEmpty else { continue }
            let key = "\(name.lowercased())|\(email.lowercased())"
            var counter = counters[key] ?? GitCodeContributionCounter(name: name, email: email, lineCount: 0)
            counter.lineCount += 1
            counters[key] = counter
        }

        return Array(counters.values)
    }

    static func stats(from counters: [GitCodeContributionCounter]) -> [GitCodeContributionStat] {
        var merged: [String: GitCodeContributionCounter] = [:]
        merge(counters, into: &merged)
        let total = merged.values.reduce(0) { $0 + $1.lineCount }
        guard total > 0 else { return [] }

        return merged.values.map { counter in
            GitCodeContributionStat(
                name: counter.name,
                email: counter.email,
                lineCount: counter.lineCount,
                share: Double(counter.lineCount) / Double(total)
            )
        }
        .sorted {
            if $0.lineCount != $1.lineCount { return $0.lineCount > $1.lineCount }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func blameCounters(repo: GitRepo, path: String, scope: GitStatsScope) -> [GitCodeContributionCounter] {
        guard !Task.isCancelled else { return [] }
        var args = ["-C", repo.rootPath, "blame", "--porcelain"]
        if scope == .head {
            args.append("HEAD")
        }
        args.append(contentsOf: ["--", path])
        let result = GitStatsProcess.run(
            executablePath: GitAnalyzer.gitPath,
            arguments: args,
            currentDirectoryPath: repo.rootPath
        )
        guard result.exitCode == 0 else { return [] }
        return parsePorcelainBlameCounters(result.output)
    }

    private static func merge(
        _ counters: [GitCodeContributionCounter],
        into merged: inout [String: GitCodeContributionCounter]
    ) {
        for counter in counters {
            var existing = merged[counter.key] ?? GitCodeContributionCounter(
                name: counter.name,
                email: counter.email,
                lineCount: 0
            )
            existing.lineCount += counter.lineCount
            merged[counter.key] = existing
        }
    }

    private static func blameHeaderHash(_ line: Substring) -> String? {
        guard let first = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        let hash = first.drop(while: { $0 == "^" })
        guard hash.count >= 7, hash.count <= 64, hash.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return String(hash)
    }

    private static func normalizeBlameEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n\t"))
    }

    private static func repoRelativePath(_ path: String, repoRoot: String) -> String {
        guard path.hasPrefix("/") else { return path }
        if path == repoRoot { return "" }
        let prefix = repoRoot.hasSuffix("/") ? repoRoot : repoRoot + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }
}
