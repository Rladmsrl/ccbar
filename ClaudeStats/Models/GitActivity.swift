import Foundation

/// A git repository discovered among the working directories of Claude sessions.
struct GitRepo: Sendable, Identifiable, Hashable {
    /// Absolute path of the repository's top level (`git rev-parse --show-toplevel`).
    let rootPath: String
    var id: String { rootPath }
    var displayName: String {
        let name = (rootPath as NSString).lastPathComponent
        return name.isEmpty ? rootPath : name
    }
}

/// One commit, with its diff stats. Merge commits are excluded upstream.
struct GitCommit: Sendable, Identifiable, Hashable {
    let hash: String
    let date: Date
    let author: String
    let authorEmail: String
    let subject: String
    let insertions: Int
    let deletions: Int
    let filesChanged: Int
    /// `GitRepo.id` of the repo this commit belongs to.
    let repoID: String

    var id: String { "\(repoID)|\(hash)" }
    var churn: Int { insertions + deletions }
    var shortHash: String { String(hash.prefix(7)) }
}

/// All commits found for one repo in the queried window, newest first.
struct RepoActivity: Sendable, Identifiable {
    let repo: GitRepo
    let commits: [GitCommit]
    let commitCount: Int
    let insertions: Int
    let deletions: Int
    let filesChanged: Int
    let churn: Int

    init(repo: GitRepo, commits: [GitCommit]) {
        self.repo = repo
        self.commits = commits
        commitCount = commits.count
        insertions = commits.reduce(0) { $0 + $1.insertions }
        deletions = commits.reduce(0) { $0 + $1.deletions }
        filesChanged = commits.reduce(0) { $0 + $1.filesChanged }
        churn = insertions + deletions
    }

    var id: String { repo.id }
}

/// Commit activity for one repo in one time bucket — the git analogue of ``ModelBucket``.
struct GitBucket: Sendable, Hashable, Identifiable {
    let repoID: String
    /// Start of the bucket in the local calendar.
    let start: Date
    let commitCount: Int
    let insertions: Int
    let deletions: Int

    var id: String { "\(repoID)|\(start.timeIntervalSinceReferenceDate)" }
    var churn: Int { insertions + deletions }
}

extension Array where Element == RepoActivity {
    /// Re-bucket every commit to the start of the given calendar unit (e.g. `.day`),
    /// per repo. Result is sorted by `start` ascending.
    func buckets(by unit: Calendar.Component, calendar: Calendar = .current) -> [GitBucket] {
        var acc: [String: [Date: (count: Int, ins: Int, del: Int)]] = [:]
        for activity in self {
            for commit in activity.commits {
                let start = calendar.dateInterval(of: unit, for: commit.date)?.start ?? commit.date
                var cell = acc[activity.repo.id, default: [:]][start, default: (0, 0, 0)]
                cell.count += 1
                cell.ins += commit.insertions
                cell.del += commit.deletions
                acc[activity.repo.id, default: [:]][start] = cell
            }
        }
        return acc
            .flatMap { repoID, byStart in
                byStart.map { GitBucket(repoID: repoID, start: $0.key, commitCount: $0.value.count,
                                        insertions: $0.value.ins, deletions: $0.value.del) }
            }
            .sorted { $0.start < $1.start }
    }

    /// Every commit across all repos, newest first.
    var allCommitsNewestFirst: [GitCommit] {
        flatMap(\.commits).sorted { $0.date > $1.date }
    }
}
