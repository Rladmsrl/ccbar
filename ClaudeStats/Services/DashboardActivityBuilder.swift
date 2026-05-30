import Foundation

/// One day-cell on a heatmap: the local-day start date and the metric value.
/// `value` is whatever the source produces — commit count for commits, token
/// count for Claude sessions.
struct HeatmapCell: Sendable, Hashable, Codable {
    let date: Date
    let value: Int
}

/// Builds per-day metric cells for the Dashboard heatmaps. Stateless and
/// `Sendable`; methods are `async` so the caller can await results on the main
/// actor without blocking it.
///
/// - `commitCells`: shells out to `git` via ``GitAnalyzer`` (off the main
///   actor in a `Task.detached`).
/// - `sessionCells`: pure in-memory bucketing of ``SessionStats/timeline``;
///   still detached so a large session set doesn't stall the UI.
struct DashboardActivityBuilder: Sendable {
    /// Discover repos from the union of session `cwd`s, then count commits per
    /// day. Repos with no commits in `range` are omitted by ``GitAnalyzer``.
    /// `nil`-returning indicates git isn't available; the UI shows that state.
    func commitCells(
        sessions: [Session],
        range: DateInterval,
        onlyMyCommits: Bool
    ) async -> (cells: [HeatmapCell], gitAvailable: Bool) {
        let cwds = Array(Set(sessions.compactMap(\.cwd)))
        return await Task.detached(priority: .userInitiated) {
            let git = GitAnalyzer()
            guard git.isAvailable else { return ([HeatmapCell](), false) }
            let email = onlyMyCommits ? git.currentUserEmail() : nil
            let repos = git.repos(forCwds: cwds)
            let activity = git.activity(for: repos, since: range.start, authorEmail: email)
            let cells = Self.bucket(commits: activity, range: range)
            return (cells, true)
        }.value
    }

    /// Sum session tokens per local day, filtered to `range`. Tokens come from
    /// ``SessionStats/timeline`` (hourly), re-bucketed to days.
    func sessionCells(
        sessions: [Session],
        range: DateInterval
    ) async -> [HeatmapCell] {
        await Task.detached(priority: .userInitiated) {
            Self.bucket(sessions: sessions, range: range)
        }.value
    }

    // MARK: - Bucketing

    private static func bucket(commits activity: [RepoActivity], range: DateInterval, calendar: Calendar = .current) -> [HeatmapCell] {
        var byDay: [Date: Int] = [:]
        for repo in activity {
            for commit in repo.commits where range.contains(commit.date) {
                let day = calendar.startOfDay(for: commit.date)
                byDay[day, default: 0] += 1
            }
        }
        return byDay
            .map { HeatmapCell(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }

    private static func bucket(sessions: [Session], range: DateInterval, calendar: Calendar = .current) -> [HeatmapCell] {
        var byDay: [Date: Int] = [:]
        for session in sessions {
            guard let timeline = session.stats?.timeline else { continue }
            for bucket in timeline.rebucketed(by: .day, calendar: calendar) where range.contains(bucket.start) {
                byDay[bucket.start, default: 0] += bucket.tokens
            }
        }
        return byDay
            .map { HeatmapCell(date: $0.key, value: $0.value) }
            .sorted { $0.date < $1.date }
    }
}
