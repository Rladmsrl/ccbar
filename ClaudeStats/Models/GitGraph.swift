import Foundation

/// A ref (branch / tag / HEAD) pointing at a commit, parsed from `git log`'s
/// `%D` decoration field.
struct GitRef: Sendable, Hashable {
    enum Kind: Sendable { case head, branch, tag }
    let kind: Kind
    /// `"main"`, `"v1.0"`, `"claude/fix-drawer-card-bugs"`, …
    let name: String
}

/// One commit as it appears in the graph: enough to draw the DAG (parents) and
/// the row (refs, author, date, subject). No diff stats — those are fetched
/// lazily per row via ``GitAnalyzer/fileChanges(for:in:)``.
struct GraphCommit: Sendable, Identifiable, Hashable {
    let hash: String
    /// Parent hashes in git's order; more than one ⇒ a merge commit.
    let parentHashes: [String]
    let refs: [GitRef]
    let author: String
    let authorEmail: String
    let date: Date
    let subject: String

    var id: String { hash }
    var isMerge: Bool { parentHashes.count > 1 }
    var shortHash: String { String(hash.prefix(7)) }
}

/// One uncommitted working-tree change from `git status --porcelain`.
struct GitWorkingTreeChange: Sendable, Identifiable, Hashable {
    enum Kind: Sendable, Hashable {
        case added
        case modified
        case deleted
        case renamed
        case copied
        case untracked
        case conflicted
        case changed

        var label: String {
            switch self {
            case .added: return "Added"
            case .modified: return "Modified"
            case .deleted: return "Deleted"
            case .renamed: return "Renamed"
            case .copied: return "Copied"
            case .untracked: return "Untracked"
            case .conflicted: return "Conflict"
            case .changed: return "Changed"
            }
        }

        var shortLabel: String {
            switch self {
            case .added: return "ADD"
            case .modified: return "MOD"
            case .deleted: return "DEL"
            case .renamed: return "REN"
            case .copied: return "CPY"
            case .untracked: return "NEW"
            case .conflicted: return "CON"
            case .changed: return "CHG"
            }
        }
    }

    let path: String
    let oldPath: String?
    let indexStatus: String
    let worktreeStatus: String
    let kind: Kind

    var id: String { "\(indexStatus)\(worktreeStatus)|\(oldPath ?? "")|\(path)" }
    var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
    var isUnstaged: Bool { indexStatus == "?" || worktreeStatus != " " }

    var displayPath: String {
        guard let oldPath, !oldPath.isEmpty else { return path }
        return "\(oldPath) -> \(path)"
    }
}

/// Summary of changes that are present in the working tree but not represented
/// by any commit in the graph.
struct GitWorkingTreeSummary: Sendable, Equatable {
    let changes: [GitWorkingTreeChange]

    static let clean = GitWorkingTreeSummary(changes: [])

    var isDirty: Bool { !changes.isEmpty }
    var fileCount: Int { changes.count }
    var stagedCount: Int { changes.filter(\.isStaged).count }
    var unstagedCount: Int { changes.filter(\.isUnstaged).count }

    var title: String {
        "\(fileCount) modified file\(fileCount == 1 ? "" : "s")"
    }
}

/// The commit list for one repo, in display order (`--date-order`, newest first).
struct GitGraph: Sendable {
    let repo: GitRepo
    let commits: [GraphCommit]
    /// `true` when the log hit the requested limit (more history exists).
    let truncated: Bool
    let workingTree: GitWorkingTreeSummary

    init(
        repo: GitRepo,
        commits: [GraphCommit],
        truncated: Bool,
        workingTree: GitWorkingTreeSummary = .clean
    ) {
        self.repo = repo
        self.commits = commits
        self.truncated = truncated
        self.workingTree = workingTree
    }
}

/// One file's churn within a commit — the expanded-row detail in the graph.
/// `insertions`/`deletions` are `-1` for binary files (git prints `-`).
struct CommitFileChange: Sendable, Identifiable, Hashable {
    let path: String
    let insertions: Int
    let deletions: Int
    var id: String { path }
    var isBinary: Bool { insertions < 0 || deletions < 0 }

    /// The directory the file lives in (`""` ⇒ repo root); used to group the
    /// file list in ``CommitDetailView``.
    var directory: String { (path as NSString).deletingLastPathComponent }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// Full metadata + per-file churn for one commit — the ``CommitDetailView``
/// model, loaded via ``GitAnalyzer/commitDetail(for:in:)`` (`git show --numstat`).
struct CommitDetail: Sendable, Hashable, Identifiable {
    let hash: String
    let abbreviatedHash: String
    let parentHashes: [String]
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let committerEmail: String
    let commitDate: Date
    let subject: String
    /// The commit message body (everything after the subject), trimmed; may be empty.
    let body: String
    let files: [CommitFileChange]

    var id: String { hash }
    var isMerge: Bool { parentHashes.count > 1 }
    var totalInsertions: Int { files.lazy.filter { !$0.isBinary }.reduce(0) { $0 + $1.insertions } }
    var totalDeletions: Int { files.lazy.filter { !$0.isBinary }.reduce(0) { $0 + $1.deletions } }
}

/// One line of a unified diff, for the ``FileDiffView``.
struct DiffLine: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable { case fileHeader, hunkHeader, context, addition, deletion }
    let kind: Kind
    /// The line text without the leading `+`/`-`/space marker.
    let text: String
    let oldLine: Int?
    let newLine: Int?
    let id = UUID()
}

/// The unified diff of one file within a commit (`git show -- <path>`).
struct FileDiff: Sendable, Hashable {
    let path: String
    let isBinary: Bool
    let lines: [DiffLine]
}
