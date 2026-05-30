import Testing
import Foundation
@testable import ClaudeStats

@Suite("GitAnalyzer")
struct GitAnalyzerTests {

    // MARK: - parseLog (no git needed)

    private static let RS = "\u{1e}"
    private static let FS = "\u{1f}"

    @Test("parseLog reads header fields and sums numstat lines")
    func parseLogBasics() {
        let log = """
        \(Self.RS)abc123\(Self.FS)1705314600\(Self.FS)Ada\(Self.FS)ada@example.com\(Self.FS)Add parser
        3\t1\tsrc/a.swift
        10\t0\tsrc/b.swift
        \(Self.RS)def456\(Self.FS)1705222800\(Self.FS)Ada\(Self.FS)ada@example.com\(Self.FS)Tweak
        1\t1\tsrc/a.swift
        """
        let commits = GitAnalyzer.parseLog(log, repoID: "/repo")
        #expect(commits.count == 2)
        let first = commits[0]
        #expect(first.hash == "abc123")
        #expect(first.shortHash == "abc123")
        #expect(first.author == "Ada")
        #expect(first.authorEmail == "ada@example.com")
        #expect(first.subject == "Add parser")
        #expect(first.date == Date(timeIntervalSince1970: 1_705_314_600))
        #expect(first.insertions == 13)
        #expect(first.deletions == 1)
        #expect(first.filesChanged == 2)
        #expect(first.churn == 14)
        #expect(first.repoID == "/repo")
        #expect(commits[1].hash == "def456")
        #expect(commits[1].insertions == 1 && commits[1].deletions == 1 && commits[1].filesChanged == 1)
    }

    @Test("parseLog treats binary numstat ('-') as zero churn but counts the file")
    func parseLogBinary() {
        let log = "\(Self.RS)h1\(Self.FS)1705314600\(Self.FS)A\(Self.FS)a@x.com\(Self.FS)Add image\n-\t-\tassets/logo.png\n5\t2\tcode.swift"
        let commits = GitAnalyzer.parseLog(log, repoID: "r")
        #expect(commits.count == 1)
        #expect(commits[0].filesChanged == 2)
        #expect(commits[0].insertions == 5 && commits[0].deletions == 2)
    }

    @Test("parseLog ignores blank and malformed records")
    func parseLogMalformed() {
        let log = "\n\(Self.RS)\(Self.RS)onlytwo\(Self.FS)fields\n\(Self.RS)h1\(Self.FS)1705314600\(Self.FS)A\(Self.FS)a@x.com\(Self.FS)ok"
        let commits = GitAnalyzer.parseLog(log, repoID: "r")
        #expect(commits.count == 1)
        #expect(commits[0].subject == "ok")
    }

    // MARK: - parseNumstat / parseCommitShow / parseUnifiedDiff (no git needed)

    @Test("parseNumstat reads ins/del/path and maps binary '-' to -1")
    func parseNumstatBasics() {
        let out = "12\t3\tSources/A.swift\n0\t9\tSources/B.swift\n-\t-\tassets/logo.png\nmalformed line\n"
        let files = GitAnalyzer.parseNumstat(out)
        #expect(files.count == 3)
        #expect(files[0].path == "Sources/A.swift" && files[0].insertions == 12 && files[0].deletions == 3)
        #expect(files[0].directory == "Sources" && files[0].fileName == "A.swift")
        #expect(files[2].isBinary && files[2].insertions == -1 && files[2].deletions == -1)
    }

    @Test("parseCommitShow reads metadata, body and numstat")
    func parseCommitShowBasics() throws {
        let f = Self.FS, r = Self.RS
        let fields = ["abc123def456", "abc123d", "p1 p2",
                      "Ada", "ada@example.com", "1705314600",
                      "Grace", "grace@example.com", "1705315020",
                      "feat: do the thing", "Body line one\n\nBody line two\n"].joined(separator: f)
        let out = "\(r)\(fields)\(r)\n\n5\t1\tSources/A.swift\n-\t-\tlogo.png\n"
        let detail = try #require(GitAnalyzer.parseCommitShow(out))
        #expect(detail.hash == "abc123def456")
        #expect(detail.abbreviatedHash == "abc123d")
        #expect(detail.parentHashes == ["p1", "p2"])
        #expect(detail.isMerge)
        #expect(detail.authorName == "Ada" && detail.authorEmail == "ada@example.com")
        #expect(detail.authorDate == Date(timeIntervalSince1970: 1_705_314_600))
        #expect(detail.committerName == "Grace" && detail.commitDate == Date(timeIntervalSince1970: 1_705_315_020))
        #expect(detail.subject == "feat: do the thing")
        #expect(detail.body == "Body line one\n\nBody line two")
        #expect(detail.files.count == 2)
        #expect(detail.totalInsertions == 5 && detail.totalDeletions == 1)   // binary excluded
    }

    @Test("parseCommitShow on a merge commit (no numstat) yields empty files")
    func parseCommitShowMerge() throws {
        let f = Self.FS, r = Self.RS
        let fields = ["h", "h", "p1 p2", "A", "a@x", "1", "A", "a@x", "1", "Merge branch 'x'", ""].joined(separator: f)
        let detail = try #require(GitAnalyzer.parseCommitShow("\(r)\(fields)\(r)\n"))
        #expect(detail.isMerge && detail.files.isEmpty && detail.body.isEmpty)
    }

    @Test("parseUnifiedDiff classifies headers, hunk lines and tracks line numbers")
    func parseUnifiedDiffBasics() throws {
        let diff = """
        diff --git a/A.swift b/A.swift
        index 111..222 100644
        --- a/A.swift
        +++ b/A.swift
        @@ -10,3 +10,4 @@ func f() {
             let a = 1
        -    let b = 2
        +    let b = 3
        +    let c = 4
             return a
        """
        let lines = GitAnalyzer.parseUnifiedDiff(diff)
        #expect(lines.prefix(4).allSatisfy { $0.kind == .fileHeader })
        let hunk = try #require(lines.first { $0.kind == .hunkHeader })
        #expect(hunk.text.hasPrefix("@@ -10,3 +10,4 @@"))
        let body = lines.drop(while: { $0.kind != .hunkHeader }).dropFirst()
        #expect(Array(body).map(\.kind) == [.context, .deletion, .addition, .addition, .context])
        let firstContext = try #require(body.first)
        #expect(firstContext.oldLine == 10 && firstContext.newLine == 10)
        let delLine = try #require(body.first { $0.kind == .deletion })
        #expect(delLine.text == "    let b = 2" && delLine.oldLine == 11 && delLine.newLine == nil)
        let lastContext = try #require(body.last)
        #expect(lastContext.oldLine == 12 && lastContext.newLine == 13)
    }

    @Test("parseWorkingTreeStatus reads staged, unstaged, renamed and untracked files")
    func parseWorkingTreeStatusBasics() throws {
        let output = [
            " M Sources/App.swift",
            "M  Sources/Store.swift",
            "A  Sources/NewFile.swift",
            "R  Sources/OldName.swift -> Sources/NewName.swift",
            "?? Scratch Notes.md",
        ].joined(separator: "\n")
        let summary = GitAnalyzer.parseWorkingTreeStatus(output)

        #expect(summary.fileCount == 5)
        #expect(summary.stagedCount == 3)
        #expect(summary.unstagedCount == 2)
        #expect(summary.changes.contains { $0.path == "Sources/App.swift" && $0.kind == .modified && $0.isUnstaged })
        #expect(summary.changes.contains { $0.path == "Sources/Store.swift" && $0.kind == .modified && $0.isStaged })
        let renamed = try #require(summary.changes.first { $0.path == "Sources/NewName.swift" })
        #expect(renamed.oldPath == "Sources/OldName.swift")
        #expect(renamed.displayPath == "Sources/OldName.swift -> Sources/NewName.swift")
        #expect(summary.changes.contains { $0.path == "Scratch Notes.md" && $0.kind == .untracked })
    }

    // MARK: - bucketing

    @Test("RepoActivity.buckets groups commits per repo per calendar unit")
    func bucketing() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")!
        func date(_ s: String) -> Date { iso.date(from: s + "Z")! }
        func commit(_ id: String, _ iso: String, ins: Int, del: Int, repo: String) -> GitCommit {
            GitCommit(hash: id, date: date(iso), author: "A", authorEmail: "a", subject: "s",
                      insertions: ins, deletions: del, filesChanged: 1, repoID: repo)
        }
        let repoA = GitRepo(rootPath: "/a")
        let repoB = GitRepo(rootPath: "/b")
        let activity = [
            RepoActivity(repo: repoA, commits: [
                commit("1", "2024-01-15T10:00:00", ins: 5, del: 1, repo: "/a"),
                commit("2", "2024-01-15T18:00:00", ins: 2, del: 0, repo: "/a"),
                commit("3", "2024-01-16T09:00:00", ins: 1, del: 1, repo: "/a"),
            ]),
            RepoActivity(repo: repoB, commits: [
                commit("4", "2024-01-15T12:00:00", ins: 8, del: 3, repo: "/b"),
            ]),
        ]
        let buckets = activity.buckets(by: .day, calendar: cal)
        #expect(buckets.count == 3)
        let aDay15 = buckets.first { $0.repoID == "/a" && cal.component(.day, from: $0.start) == 15 }
        #expect(aDay15?.commitCount == 2)
        #expect(aDay15?.insertions == 7 && aDay15?.deletions == 1)
        #expect(activity.allCommitsNewestFirst.map(\.hash) == ["3", "2", "4", "1"])
    }

    // MARK: - against a real temp repo

    @Test("repos / activity / author filter against a real git repo", .enabled(if: GitAnalyzer().isAvailable))
    func realRepo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitanalyzer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try run(["init", "-q"], in: dir)
        try run(["config", "user.email", "me@example.com"], in: dir)
        try run(["config", "user.name", "Me"], in: dir)
        try run(["config", "commit.gpgsign", "false"], in: dir)

        try (Array(repeating: "line", count: 3).joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "a.txt"], in: dir)
        try run(["commit", "-q", "-m", "Add a.txt"], in: dir)

        try (Array(repeating: "line", count: 5).joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["commit", "-q", "-am", "Grow a.txt"], in: dir)

        // A commit by a different author.
        try "one\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try run(["add", "b.txt"], in: dir)
        try run(["-c", "user.email=other@example.com", "-c", "user.name=Other", "commit", "-q", "-m", "Add b.txt"], in: dir)

        let analyzer = GitAnalyzer()
        let resolvedRoot = try run(["rev-parse", "--show-toplevel"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)

        // Discovery + de-dup: the dir and a subdir resolve to the same root.
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let repos = analyzer.repos(forCwds: [dir.path, sub.path, "/nonexistent/path/xyz"])
        #expect(repos.count == 1)
        #expect(repos.first?.rootPath == resolvedRoot)

        // All commits (no author filter).
        let all = analyzer.activity(for: repos, since: .distantPast, authorEmail: nil)
        #expect(all.count == 1)
        let activity = try #require(all.first)
        #expect(activity.commitCount == 3)
        // a.txt: +3 then +2 (no deletions when growing a file); b.txt: +1.
        #expect(activity.insertions == 6)
        #expect(activity.deletions == 0)
        #expect(activity.churn == 6)
        #expect(activity.filesChanged == 3)
        #expect(activity.commits.map(\.subject) == ["Add b.txt", "Grow a.txt", "Add a.txt"])

        // Author filter excludes "Other".
        let mine = analyzer.activity(for: repos, since: .distantPast, authorEmail: "me@example.com")
        #expect(mine.first?.commitCount == 2)
        #expect(mine.first?.commits.allSatisfy { $0.authorEmail == "me@example.com" } == true)

        // `since` in the future → nothing.
        let none = analyzer.activity(for: repos, since: Date(timeIntervalSinceNow: 86_400), authorEmail: nil)
        #expect(none.isEmpty)
    }

    // MARK: helpers

    @discardableResult
    private func run(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: GitAnalyzer.gitPath)
        p.arguments = ["-C", dir.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
