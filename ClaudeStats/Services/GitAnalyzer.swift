import Foundation

/// Reads git history by shelling out to `git`. Stateless and `Sendable`; all of
/// its methods block on `Process`, so callers run them off the main actor (the
/// view model does this via `Task.detached`, mirroring `ScreenTimeService`).
struct GitAnalyzer: Sendable {
    /// macOS ships the Xcode command-line-tools shim here; if the tools aren't
    /// installed, invoking it triggers the install prompt — acceptable for a
    /// dev-facing tool, and `isAvailable` lets the UI degrade gracefully first.
    static let gitPath = "/usr/bin/git"

    /// ASCII record/field separators used in the `--pretty=format:` string —
    /// safe because commit subjects never contain control characters.
    private static let recordSep = "\u{1e}"
    private static let fieldSep = "\u{1f}"

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: Self.gitPath) }

    /// The `user.email` from the (global) git config, if any.
    func currentUserEmail() -> String? {
        runGit(["config", "user.email"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Resolve each working directory to its repo top level and de-duplicate
    /// (several `cwd`s can sit in the same repo). Non-repos / missing paths are
    /// dropped silently.
    func repos(forCwds cwds: [String]) -> [GitRepo] {
        var seen = Set<String>()
        var out: [GitRepo] = []
        for cwd in cwds {
            guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else { continue }
            guard let root = runGit(["-C", cwd, "rev-parse", "--show-toplevel"])?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { continue }
            if seen.insert(root).inserted { out.append(GitRepo(rootPath: root)) }
        }
        return out.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Commit activity for each repo since `date`. Repos with no matching
    /// commits are omitted. When `authorEmail` is non-nil only that author's
    /// commits are counted.
    func activity(for repos: [GitRepo], since date: Date, authorEmail: String?) -> [RepoActivity] {
        repos.compactMap { repo in
            let commits = commits(in: repo, since: date, authorEmail: authorEmail)
            return commits.isEmpty ? nil : RepoActivity(repo: repo, commits: commits)
        }
    }

    /// Files tracked by git at `HEAD` / the index. Untracked and ignored files
    /// are intentionally excluded so repository code stats remain reproducible.
    func trackedFiles(in repo: GitRepo) -> [String] {
        guard isAvailable else { return [] }
        guard let output = runGit(["-C", repo.rootPath, "ls-files", "-z"]) else { return [] }
        return output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func codeStats(for repo: GitRepo) -> GitRepoCodeStats {
        codeStats(for: repo, scope: .head)
    }

    func codeStats(for repo: GitRepo, scope: GitStatsScope) -> GitRepoCodeStats {
        let trackedFiles = trackedFiles(in: repo)
        return GitLinguistAnalyzer().stats(repo: repo, scope: scope, trackedFiles: trackedFiles)
    }

    private func commits(in repo: GitRepo, since date: Date, authorEmail: String?) -> [GitCommit] {
        let sinceArg = ISO8601DateFormatter().string(from: date)
        let format = "format:\(Self.recordSep)%H\(Self.fieldSep)%at\(Self.fieldSep)%an\(Self.fieldSep)%ae\(Self.fieldSep)%s"
        var args = ["-C", repo.rootPath, "log", "--no-merges", "--since=\(sinceArg)",
                    "--numstat", "--pretty=\(format)"]
        if let authorEmail, !authorEmail.isEmpty { args.append("--author=\(authorEmail)") }
        guard let output = runGit(args) else { return [] }
        return Self.parseLog(output, repoID: repo.id)
    }

    /// Parse `git log --numstat --pretty=format:<rec>%H<f>%at<f>%an<f>%ae<f>%s`
    /// output (`%at` = author date as a Unix timestamp). Each record is the
    /// header line followed by zero or more numstat lines (`<ins>\t<del>\t<path>`;
    /// binary files show `-`/`-`).
    static func parseLog(_ output: String, repoID: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        for rawRecord in output.components(separatedBy: recordSep) {
            let record = rawRecord.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            guard !record.isEmpty else { continue }
            var lines = record.components(separatedBy: "\n")
            let header = lines.removeFirst()
            let fields = header.components(separatedBy: fieldSep)
            guard fields.count >= 5 else { continue }
            let hash = fields[0]
            guard !hash.isEmpty else { continue }
            let date = Double(fields[1]).map { Date(timeIntervalSince1970: $0) } ?? Date.distantPast
            var insertions = 0, deletions = 0, filesChanged = 0
            for line in lines where !line.isEmpty {
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 3 else { continue }
                filesChanged += 1
                insertions += Int(cols[0]) ?? 0   // "-" for binary → 0
                deletions += Int(cols[1]) ?? 0
            }
            commits.append(GitCommit(
                hash: hash, date: date, author: fields[2], authorEmail: fields[3], subject: fields[4],
                insertions: insertions, deletions: deletions, filesChanged: filesChanged, repoID: repoID
            ))
        }
        return commits
    }

    func contributorStats(for repo: GitRepo) -> [GitContributorStat] {
        guard isAvailable else { return [] }
        let format = "format:\(Self.recordSep)%an\(Self.fieldSep)%ae"
        let args = ["-C", repo.rootPath, "log", "--branches", "--tags", "--pretty=\(format)"]
        guard let output = runGit(args) else { return [] }
        return Self.parseContributorStats(output)
    }

    static func parseContributorStats(_ output: String) -> [GitContributorStat] {
        struct Counter {
            var name: String
            var email: String
            var count: Int
        }

        var counters: [String: Counter] = [:]
        for rawRecord in output.components(separatedBy: recordSep) {
            let record = rawRecord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !record.isEmpty else { continue }
            let fields = record.components(separatedBy: fieldSep)
            guard fields.count >= 2 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let email = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(name.lowercased())|\(email.lowercased())"
            var counter = counters[key] ?? Counter(name: name, email: email, count: 0)
            counter.count += 1
            counters[key] = counter
        }

        let total = counters.values.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        return counters.values.map { counter in
            GitContributorStat(
                name: counter.name,
                email: counter.email,
                commitCount: counter.count,
                share: Double(counter.count) / Double(total)
            )
        }
        .sorted {
            if $0.commitCount != $1.commitCount { return $0.commitCount > $1.commitCount }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: - Commit graph

    /// The commit DAG for a repo: up to `limit` commits reachable from local
    /// branches and tags, in `--date-order` (newest first). `nil` if `git`
    /// couldn't be run.
    func graph(for repo: GitRepo, limit: Int) -> GitGraph? {
        guard isAvailable else { return nil }
        let f = Self.fieldSep
        let format = "format:\(Self.recordSep)%H\(f)%P\(f)%D\(f)%an\(f)%ae\(f)%at\(f)%s"
        let args = ["-C", repo.rootPath, "log", "--branches", "--tags", "--date-order",
                    "--decorate-refs-exclude=refs/remotes", "-n", "\(limit)", "--pretty=\(format)"]
        guard let output = runGit(args) else { return nil }
        let commits = Self.parseGraphLog(output)
        return GitGraph(
            repo: repo,
            commits: commits,
            truncated: commits.count >= limit,
            workingTree: workingTreeSummary(for: repo)
        )
    }

    /// Working tree changes that are not represented by a commit. This includes
    /// staged, unstaged, conflicted, and untracked files.
    func workingTreeSummary(for repo: GitRepo) -> GitWorkingTreeSummary {
        guard isAvailable else { return .clean }
        guard let output = runGit(["-C", repo.rootPath, "status", "--porcelain=v1"]) else { return .clean }
        return Self.parseWorkingTreeStatus(output)
    }

    static func parseWorkingTreeStatus(_ output: String) -> GitWorkingTreeSummary {
        let changes = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap(parseWorkingTreeStatusLine)
            .sorted {
                if $0.kind.shortLabel != $1.kind.shortLabel {
                    return $0.kind.shortLabel < $1.kind.shortLabel
                }
                return $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending
            }
        return GitWorkingTreeSummary(changes: changes)
    }

    private static func parseWorkingTreeStatusLine(_ rawLine: Substring) -> GitWorkingTreeChange? {
        let line = String(rawLine)
        guard line.count >= 4 else { return nil }
        let indexStatus = String(line.prefix(1))
        let worktreeStatus = String(line.dropFirst().prefix(1))
        var path = String(line.dropFirst(3))
        var oldPath: String?

        if let arrow = path.range(of: " -> ") {
            oldPath = String(path[..<arrow.lowerBound])
            path = String(path[arrow.upperBound...])
        }

        let kind = workingTreeKind(indexStatus: indexStatus, worktreeStatus: worktreeStatus)
        return GitWorkingTreeChange(
            path: path,
            oldPath: oldPath,
            indexStatus: indexStatus,
            worktreeStatus: worktreeStatus,
            kind: kind
        )
    }

    private static func workingTreeKind(indexStatus: String, worktreeStatus: String) -> GitWorkingTreeChange.Kind {
        if indexStatus == "?" && worktreeStatus == "?" { return .untracked }
        if indexStatus == "U" || worktreeStatus == "U" { return .conflicted }
        if indexStatus == "R" || worktreeStatus == "R" { return .renamed }
        if indexStatus == "C" || worktreeStatus == "C" { return .copied }
        if indexStatus == "D" || worktreeStatus == "D" { return .deleted }
        if indexStatus == "A" || worktreeStatus == "A" { return .added }
        if indexStatus == "M" || worktreeStatus == "M" { return .modified }
        return .changed
    }

    /// Per-file churn for one commit (`git show --numstat`). Empty for merge
    /// commits (git prints no diff for them by default) and on error.
    func fileChanges(for hash: String, in repo: GitRepo) -> [CommitFileChange] {
        guard isAvailable, !hash.isEmpty else { return [] }
        guard let output = runGit(["-C", repo.rootPath, "show", "--numstat", "--format=", "--no-color", hash]) else { return [] }
        return Self.parseNumstat(output)
    }

    /// Parse `git`'s `--numstat` block (`<ins>\t<del>\t<path>` lines; binary
    /// files print `-`/`-`, mapped to `-1`/`-1`). Renames printed as
    /// `old => new` are kept verbatim.
    static func parseNumstat(_ output: String) -> [CommitFileChange] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return nil }
            let ins = cols[0] == "-" ? -1 : (Int(cols[0]) ?? 0)
            let del = cols[1] == "-" ? -1 : (Int(cols[1]) ?? 0)
            return CommitFileChange(path: String(cols[2]), insertions: ins, deletions: del)
        }
    }

    /// Full metadata + per-file churn for one commit (`git show --numstat`).
    /// `nil` if `git` couldn't be run; `files` is empty for merge commits (git
    /// prints no diff for them by default).
    func commitDetail(for hash: String, in repo: GitRepo) -> CommitDetail? {
        guard isAvailable, !hash.isEmpty else { return nil }
        let f = Self.fieldSep, r = Self.recordSep
        let format = "format:\(r)%H\(f)%h\(f)%P\(f)%an\(f)%ae\(f)%at\(f)%cn\(f)%ce\(f)%ct\(f)%s\(f)%b\(r)"
        guard let output = runGit(["-C", repo.rootPath, "show", "--numstat", "--no-color", "--pretty=\(format)", hash]) else { return nil }
        return Self.parseCommitShow(output)
    }

    /// Parse `git show --numstat --pretty=format:<rec>%H<f>%h<f>%P<f>%an<f>%ae<f>%at<f>%cn<f>%ce<f>%ct<f>%s<f>%b<rec>`.
    /// The output is `<rec>field0<f>…<f>body<rec>\n\n<numstat lines>`.
    static func parseCommitShow(_ output: String) -> CommitDetail? {
        let parts = output.components(separatedBy: recordSep)
        guard parts.count >= 2 else { return nil }
        let fields = parts[1].components(separatedBy: fieldSep)
        guard fields.count >= 11 else { return nil }
        let hash = fields[0]
        guard !hash.isEmpty else { return nil }
        func date(_ s: String) -> Date { Double(s).map { Date(timeIntervalSince1970: $0) } ?? .distantPast }
        let parents = fields[2].split(separator: " ").map(String.init)
        let body = fields[10...].joined(separator: fieldSep).trimmingCharacters(in: .whitespacesAndNewlines)
        let numstat = parts.count >= 3 ? parts[2] : ""
        return CommitDetail(
            hash: hash, abbreviatedHash: fields[1], parentHashes: parents,
            authorName: fields[3], authorEmail: fields[4], authorDate: date(fields[5]),
            committerName: fields[6], committerEmail: fields[7], commitDate: date(fields[8]),
            subject: fields[9], body: body, files: parseNumstat(numstat)
        )
    }

    /// The unified diff of one file within a commit (`git show -- <path>`).
    /// `nil` if `git` couldn't be run.
    func fileDiff(for hash: String, path: String, in repo: GitRepo) -> FileDiff? {
        guard isAvailable, !hash.isEmpty, !path.isEmpty else { return nil }
        guard let output = runGit(["-C", repo.rootPath, "show", "--format=", "--no-color", hash, "--", path]) else { return nil }
        let lines = Self.parseUnifiedDiff(output)
        let isBinary = lines.isEmpty && output.contains("Binary files")
        return FileDiff(path: path, isBinary: isBinary, lines: lines)
    }

    /// Parse a unified diff (the body of `git show`/`git diff` after the
    /// `diff --git` headers). Lines outside any hunk (`diff --git`, `index`,
    /// `---`, `+++`, `new file mode`, …) become `.fileHeader`; `@@ … @@`
    /// becomes `.hunkHeader` and seeds the old/new line counters.
    static func parseUnifiedDiff(_ output: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldNo = 0, newNo = 0
        var inHunk = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff --git ") { inHunk = false }
            if line.hasPrefix("@@") {
                inHunk = true
                if let (o, n) = parseHunkHeader(line) { oldNo = o; newNo = n }
                result.append(DiffLine(kind: .hunkHeader, text: line, oldLine: nil, newLine: nil))
                continue
            }
            if !inHunk {
                if line.isEmpty { continue }
                result.append(DiffLine(kind: .fileHeader, text: line, oldLine: nil, newLine: nil))
                continue
            }
            if line.hasPrefix("+") {
                result.append(DiffLine(kind: .addition, text: String(line.dropFirst()), oldLine: nil, newLine: newNo)); newNo += 1
            } else if line.hasPrefix("-") {
                result.append(DiffLine(kind: .deletion, text: String(line.dropFirst()), oldLine: oldNo, newLine: nil)); oldNo += 1
            } else if line.hasPrefix("\\") {
                // "\ No newline at end of file" — render as context, no numbers.
                result.append(DiffLine(kind: .context, text: line, oldLine: nil, newLine: nil))
            } else {
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                result.append(DiffLine(kind: .context, text: text, oldLine: oldNo, newLine: newNo)); oldNo += 1; newNo += 1
            }
        }
        return result
    }

    /// `"@@ -12,7 +12,9 @@ context"` → `(oldStart: 12, newStart: 12)`.
    private static func parseHunkHeader(_ line: String) -> (Int, Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        let old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
        let new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
        return (old, new)
    }

    /// Parse `git log --pretty=format:<rec>%H<f>%P<f>%D<f>%an<f>%ae<f>%at<f>%s`.
    /// Each record is a single line (the `%s` subject has no newlines).
    static func parseGraphLog(_ output: String) -> [GraphCommit] {
        var commits: [GraphCommit] = []
        for rawRecord in output.components(separatedBy: recordSep) {
            let record = rawRecord.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            guard !record.isEmpty else { continue }
            let fields = record.components(separatedBy: fieldSep)
            guard fields.count >= 7 else { continue }
            let hash = fields[0]
            guard !hash.isEmpty else { continue }
            let parents = fields[1].split(separator: " ").map(String.init)
            let refs = parseRefs(fields[2])
            let date = Double(fields[5]).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let subject = fields.count == 7 ? fields[6] : fields[6...].joined(separator: fieldSep)
            commits.append(GraphCommit(hash: hash, parentHashes: parents, refs: refs,
                                       author: fields[3], authorEmail: fields[4], date: date, subject: subject))
        }
        return commits
    }

    /// Parse the `%D` decoration string (`"HEAD -> main, tag: v1.0, feature/x"`).
    static func parseRefs(_ decoration: String) -> [GitRef] {
        decoration.split(separator: ",").compactMap { piece in
            let s = piece.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return nil }
            if let arrow = s.range(of: "HEAD -> ") { return GitRef(kind: .head, name: String(s[arrow.upperBound...])) }
            if s == "HEAD" { return GitRef(kind: .head, name: "HEAD") }
            if s.hasPrefix("tag: ") { return GitRef(kind: .tag, name: String(s.dropFirst(5))) }
            return GitRef(kind: .branch, name: s)
        }
    }

    // MARK: - Process plumbing

    private func runGit(_ arguments: [String]) -> String? {
        guard isAvailable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Keep git from touching the calling tty / pager.
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        do {
            try process.run()
        } catch {
            Log.git.error("git \(arguments.first ?? "?", privacy: .public) failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
