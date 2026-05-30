import Foundation
import Observation

/// Time window the git view is scoped to.
enum GitRange: String, CaseIterable, Identifiable, Sendable {
    case last7Days, last30Days, last90Days
    var id: String { rawValue }
    var shortLabel: String {
        switch self {
        case .last7Days: "7D"
        case .last30Days: "30D"
        case .last90Days: "90D"
        }
    }
    var dayCount: Int {
        switch self {
        case .last7Days: 7
        case .last30Days: 30
        case .last90Days: 90
        }
    }
    /// Calendar unit the correlation/timeline charts bucket by for this range.
    var bucketUnit: Calendar.Component { self == .last90Days ? .weekOfYear : .day }
}

@MainActor
@Observable
final class GitActivityViewModel {
    var range: GitRange = .last7Days {
        didSet { if range != oldValue { reloadToken &+= 1 } }
    }
    var onlyMyCommits: Bool = true {
        didSet { if onlyMyCommits != oldValue { reloadToken &+= 1 } }
    }
    private(set) var repos: [RepoActivity] = []
    /// Precomputed correlation points for the chart. Populated by `reload(...)`
    /// off-main so the view body reads a finished array instead of walking all
    /// session timelines on every Observable change.
    private(set) var correlationPoints: [CorrelationPoint] = []
    /// Preformatted, main-window overview data. This keeps resize/layout passes
    /// from rebuilding tables, stat strings, chart ticks, and recent commit rows.
    private(set) var overviewSnapshot: OverviewSnapshot = .empty
    private(set) var isLoading = false
    private(set) var gitAvailable = true
    private(set) var userEmail: String?

    /// Bumped whenever something the view should re-fetch for changes; the view
    /// drives `.task(id:)` off it.
    private(set) var reloadToken: UInt64 = 0

    private let calendar = Calendar.current
    private var activeReloadIdentity: ReloadIdentity?
    private var lastLoadedIdentity: ReloadIdentity?

    private struct ReloadIdentity: Equatable, Sendable {
        let provider: ProviderKind
        let lastRefreshedAt: Date?
        let range: GitRange
        let onlyMyCommits: Bool
        let reloadToken: UInt64
    }

    func bumpReload() { reloadToken &+= 1 }

    /// Start of the current window (start of the day, `dayCount - 1` days ago).
    var windowStart: Date {
        let today = calendar.startOfDay(for: .now)
        return calendar.date(byAdding: .day, value: -(range.dayCount - 1), to: today) ?? today
    }

    func reloadIfNeeded(sessions: [Session], provider: ProviderKind, lastRefreshedAt: Date?) async {
        let identity = ReloadIdentity(
            provider: provider,
            lastRefreshedAt: lastRefreshedAt,
            range: range,
            onlyMyCommits: onlyMyCommits,
            reloadToken: reloadToken
        )
        if lastLoadedIdentity == identity {
            Log.git.debug("Git activity reload skipped: cached view model snapshot")
            return
        }
        if activeReloadIdentity == identity {
            Log.git.debug("Git activity reload skipped: matching request already loading")
            return
        }
        await reload(sessions: sessions, identity: identity)
    }

    func reload(sessions: [Session]) async {
        await reload(sessions: sessions, identity: nil)
    }

    private func reload(sessions: [Session], identity: ReloadIdentity?) async {
        activeReloadIdentity = identity
        isLoading = true
        let startedAt = Date()

        let cwds = Array(Set(sessions.compactMap(\.cwd)))
        let since = windowStart
        let onlyMine = onlyMyCommits
        let unit = range.bucketUnit
        let cal = calendar
        let endExclusive = cal.dateInterval(of: .day, for: .now)?.end ?? Date.now

        let result = await Task.detached(priority: .userInitiated) {
            () -> (repos: [RepoActivity], email: String?, available: Bool, correlation: [CorrelationPoint], overview: OverviewSnapshot) in
            let git = GitAnalyzer()
            guard git.isAvailable else { return ([], nil, false, [], .empty) }
            let email = git.currentUserEmail()
            let reposList = git.repos(forCwds: cwds)
            let activity = git.activity(for: reposList, since: since, authorEmail: onlyMine ? email : nil)
            let sorted = activity.sorted {
                $0.churn != $1.churn ? $0.churn > $1.churn : $0.commitCount > $1.commitCount
            }
            let correlation = Self.makeCorrelationPoints(
                sessions: sessions,
                repos: sorted,
                unit: unit,
                since: since,
                endExclusive: endExclusive,
                calendar: cal
            )
            let overview = Self.makeOverviewSnapshot(repos: sorted, correlation: correlation)
            return (sorted, email, true, correlation, overview)
        }.value

        guard activeReloadIdentity == identity else { return }
        gitAvailable = result.available
        userEmail = result.email
        repos = result.repos
        correlationPoints = result.correlation
        overviewSnapshot = result.overview
        lastLoadedIdentity = identity
        activeReloadIdentity = nil
        isLoading = false
        let duration = Date().timeIntervalSince(startedAt)
        Log.git.info("Git activity loaded \(result.repos.count, privacy: .public) repos from \(cwds.count, privacy: .public) cwds in \(String(format: "%.2f", duration), privacy: .public)s")
    }

    // MARK: - Derived data

    var totalCommits: Int { repos.reduce(0) { $0 + $1.commitCount } }
    var totalInsertions: Int { repos.reduce(0) { $0 + $1.insertions } }
    var totalDeletions: Int { repos.reduce(0) { $0 + $1.deletions } }
    var totalFilesChanged: Int { repos.reduce(0) { $0 + $1.filesChanged } }
    var hasData: Bool { !repos.isEmpty }

    /// Newest-first commits across all repos, capped for the "recent" list.
    func recentCommits(limit: Int = 40) -> [GitCommit] {
        Array(repos.allCommitsNewestFirst.prefix(limit))
    }

    /// Commit buckets for one repo, oldest→newest, gap-filled across the window
    /// so the timeline reads continuously.
    func timeline(for activity: RepoActivity) -> [GitBucket] {
        let unit = range.bucketUnit
        let existing = Dictionary(
            [activity].buckets(by: unit, calendar: calendar).map { ($0.start, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        return slots(unit: unit).map { start in
            existing[start] ?? GitBucket(repoID: activity.repo.id, start: start, commitCount: 0, insertions: 0, deletions: 0)
        }
    }

    struct CorrelationPoint: Identifiable, Sendable {
        let start: Date
        let claudeTokens: Int
        let commitCount: Int
        let churn: Int
        var id: TimeInterval { start.timeIntervalSinceReferenceDate }
    }

    struct OverviewSnapshot: Sendable {
        let stats: [OverviewStat]
        let correlation: OverviewCorrelation
        let churnRows: [OverviewRepoRow]
        let churnRowsDetail: String
        let recentRows: [OverviewCommitRow]
        let totalCommits: Int
        let totalChurn: Int

        static let empty = OverviewSnapshot(
            stats: [
                OverviewStat(id: "repos", label: "Repos", value: "0"),
                OverviewStat(id: "commits", label: "Commits", value: "0"),
                OverviewStat(id: "lines", label: "Lines +/-", value: "0/0"),
                OverviewStat(id: "files", label: "Files touched", value: "0"),
            ],
            correlation: .empty,
            churnRows: [],
            churnRowsDetail: "0 repos",
            recentRows: [],
            totalCommits: 0,
            totalChurn: 0
        )
    }

    struct OverviewStat: Identifiable, Sendable {
        let id: String
        let label: String
        let value: String
    }

    struct OverviewRepoRow: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let insertionsLabel: String
        let deletionsLabel: String
        let filesLabel: String
    }

    struct OverviewCommitRow: Identifiable, Sendable, Equatable {
        let id: String
        let subject: String
        let repoName: String
        let shortHash: String
        let churnLabel: String
        let dateLabel: String
    }

    struct OverviewCorrelation: Sendable {
        let points: [CorrelationPoint]
        let tokenValues: [Int]
        let commitValues: [Int]
        let commitCountLabel: String
        let hasTokens: Bool
        let tokenMax: Int
        let commitMax: Int
        let tokenTicks: [OverviewAxisTick]
        let commitTicks: [OverviewAxisTick]
        let dateTicks: [OverviewDateTick]

        static let empty = OverviewCorrelation(
            points: [],
            tokenValues: [],
            commitValues: [],
            commitCountLabel: "0 commits",
            hasTokens: false,
            tokenMax: 0,
            commitMax: 0,
            tokenTicks: [OverviewAxisTick(value: 0, label: "0")],
            commitTicks: [OverviewAxisTick(value: 0, label: "0")],
            dateTicks: []
        )
    }

    struct OverviewAxisTick: Identifiable, Sendable {
        let value: Int
        let label: String
        var id: String { "\(value)|\(label)" }
    }

    struct OverviewDateTick: Identifiable, Sendable {
        let index: Int
        let label: String
        var id: String { "\(index)|\(label)" }
    }

    nonisolated private static func makeOverviewSnapshot(
        repos: [RepoActivity],
        correlation: [CorrelationPoint]
    ) -> OverviewSnapshot {
        let totalCommits = repos.reduce(0) { $0 + $1.commitCount }
        let totalInsertions = repos.reduce(0) { $0 + $1.insertions }
        let totalDeletions = repos.reduce(0) { $0 + $1.deletions }
        let totalFilesChanged = repos.reduce(0) { $0 + $1.filesChanged }
        let totalChurn = totalInsertions + totalDeletions
        let churnRowLimit = 40

        let stats = [
            OverviewStat(id: "repos", label: "Repos", value: "\(repos.count)"),
            OverviewStat(id: "commits", label: "Commits", value: "\(totalCommits)"),
            OverviewStat(id: "lines", label: "Lines +/-", value: "\(Format.tokens(totalInsertions))/\(Format.tokens(totalDeletions))"),
            OverviewStat(id: "files", label: "Files touched", value: "\(totalFilesChanged)"),
        ]

        let churnRows = repos.prefix(churnRowLimit).map { activity in
            OverviewRepoRow(
                id: activity.id,
                name: activity.repo.displayName,
                insertionsLabel: "+\(Format.tokens(activity.insertions))",
                deletionsLabel: "-\(Format.tokens(activity.deletions))",
                filesLabel: "\(activity.filesChanged) files"
            )
        }
        let churnRowsDetail = repos.count > churnRowLimit ? "top \(churnRows.count) of \(repos.count)" : "\(repos.count) repos"

        let repoNamesByID = Dictionary(
            repos.map { ($0.repo.id, $0.repo.displayName) },
            uniquingKeysWith: { a, _ in a }
        )
        let recentRows = Array(repos.allCommitsNewestFirst.prefix(40)).map { commit in
            OverviewCommitRow(
                id: commit.id,
                subject: TitleSanitizer.sanitize(commit.subject) ?? commit.subject,
                repoName: repoNamesByID[commit.repoID] ?? "-",
                shortHash: commit.shortHash,
                churnLabel: "+\(Format.tokens(commit.insertions)) -\(Format.tokens(commit.deletions))",
                dateLabel: Format.relativeDate(commit.date)
            )
        }

        return OverviewSnapshot(
            stats: stats,
            correlation: makeOverviewCorrelation(points: correlation),
            churnRows: churnRows,
            churnRowsDetail: churnRowsDetail,
            recentRows: recentRows,
            totalCommits: totalCommits,
            totalChurn: totalChurn
        )
    }

    nonisolated private static func makeOverviewCorrelation(points: [CorrelationPoint]) -> OverviewCorrelation {
        guard !points.isEmpty else { return .empty }

        let tokenValues = points.map(\.claudeTokens)
        let commitValues = points.map(\.commitCount)
        let tokenMax = niceCeiling(tokenValues.max() ?? 0)
        let commitMax = niceCeiling(commitValues.max() ?? 0)
        let totalCommits = commitValues.reduce(0, +)

        return OverviewCorrelation(
            points: points,
            tokenValues: tokenValues,
            commitValues: commitValues,
            commitCountLabel: "\(totalCommits) commits",
            hasTokens: tokenValues.contains { $0 > 0 },
            tokenMax: tokenMax,
            commitMax: commitMax,
            tokenTicks: axisTicks(maxValue: tokenMax, formatter: Format.tokens),
            commitTicks: axisTicks(maxValue: commitMax, formatter: { "\($0)" }),
            dateTicks: dateTicks(for: points)
        )
    }

    nonisolated private static func axisTicks(
        maxValue: Int,
        formatter: (Int) -> String
    ) -> [OverviewAxisTick] {
        guard maxValue > 0 else {
            return [OverviewAxisTick(value: 0, label: formatter(0))]
        }

        let values: [Int]
        if maxValue == 1 {
            values = [1, 0]
        } else {
            values = [maxValue, maxValue / 2, 0]
        }
        return values.map { OverviewAxisTick(value: $0, label: formatter($0)) }
    }

    nonisolated private static func dateTicks(for points: [CorrelationPoint]) -> [OverviewDateTick] {
        guard !points.isEmpty else { return [] }
        let indices = Set([0, points.count / 2, points.count - 1]).sorted()
        return indices.map { index in
            OverviewDateTick(index: index, label: Format.day(points[index].start))
        }
    }

    nonisolated private static func niceCeiling(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        let magnitude = pow(10.0, floor(log10(Double(value))))
        let scaled = Double(value) / magnitude
        let nice: Double
        switch scaled {
        case ...1: nice = 1
        case ...2: nice = 2
        case ...5: nice = 5
        default: nice = 10
        }
        return max(1, Int(nice * magnitude))
    }

    /// Every bucket-start in the current window, oldest→newest.
    private func slots(unit: Calendar.Component) -> [Date] {
        let endExclusive = calendar.dateInterval(of: .day, for: .now)?.end ?? Date.now
        return Self.slots(
            unit: unit,
            windowStart: windowStart,
            endExclusive: endExclusive,
            calendar: calendar
        )
    }

    nonisolated private static func slots(
        unit: Calendar.Component,
        windowStart: Date,
        endExclusive: Date,
        calendar: Calendar
    ) -> [Date] {
        var cursor = calendar.dateInterval(of: unit, for: windowStart)?.start ?? windowStart
        var out: [Date] = []
        while cursor < endExclusive {
            out.append(cursor)
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return out
    }

    /// Off-main builder for correlation points; mirrors what the old
    /// `correlation(sessions:)` method did but takes its inputs as parameters
    /// so it can run inside `Task.detached`.
    nonisolated private static func makeCorrelationPoints(
        sessions: [Session],
        repos: [RepoActivity],
        unit: Calendar.Component,
        since: Date,
        endExclusive: Date,
        calendar: Calendar
    ) -> [CorrelationPoint] {
        guard !repos.isEmpty else { return [] }
        let roots = repos.map(\.repo.rootPath)
        func belongsToTrackedRepo(_ cwd: String) -> Bool {
            roots.contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
        }
        func bucketStart(_ date: Date) -> Date {
            calendar.dateInterval(of: unit, for: date)?.start ?? date
        }

        var byStart: [Date: (tokens: Int, commits: Int, churn: Int)] = [:]
        for session in sessions {
            guard let cwd = session.cwd, belongsToTrackedRepo(cwd), let timeline = session.stats?.timeline else { continue }
            for bucket in timeline where bucket.start >= since {
                byStart[bucketStart(bucket.start), default: (0, 0, 0)].tokens += bucket.tokens
            }
        }
        for bucket in repos.buckets(by: unit, calendar: calendar) {
            byStart[bucket.start, default: (0, 0, 0)].commits += bucket.commitCount
            byStart[bucket.start, default: (0, 0, 0)].churn += bucket.churn
        }

        return Self.slots(unit: unit, windowStart: since, endExclusive: endExclusive, calendar: calendar).map { start in
            let v = byStart[start] ?? (0, 0, 0)
            return CorrelationPoint(start: start, claudeTokens: v.tokens, commitCount: v.commits, churn: v.churn)
        }
    }
}

#if DEBUG
extension GitActivityViewModel {
    /// A view model pre-populated with canned commit activity for `#Preview`.
    /// Repo paths line up with `Session.previewSamples` so the usage/commit
    /// correlation chart lights up too.
    static func preview() -> GitActivityViewModel {
        let vm = GitActivityViewModel()
        vm.range = .last30Days
        let cal = Calendar.current
        let now = Date.now
        func at(_ daysAgo: Int, _ hour: Int = 11) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now)) ?? now
            return cal.date(byAdding: .hour, value: hour, to: day) ?? day
        }
        func commit(_ repo: GitRepo, _ daysAgo: Int, _ subject: String,
                    _ insertions: Int, _ deletions: Int, _ files: Int,
                    mine: Bool = true) -> GitCommit {
            GitCommit(hash: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                      date: at(daysAgo), author: mine ? "Ada Lovelace" : "Grace Hopper",
                      authorEmail: mine ? "ada@example.com" : "grace@example.com",
                      subject: subject, insertions: insertions, deletions: deletions,
                      filesChanged: files, repoID: repo.id)
        }
        let aurora = GitRepo(rootPath: "/Users/dev/projects/aurora")
        let ledger = GitRepo(rootPath: "/Users/dev/projects/ledger")
        let designSystem = GitRepo(rootPath: "/Users/dev/work/design-system")

        let activity = [
            RepoActivity(repo: aurora, commits: [
                commit(aurora, 0, "feat: websocket reconnect with backoff", 312, 48, 7),
                commit(aurora, 0, "fix: drop stale subscriptions on close", 24, 11, 2),
                commit(aurora, 1, "refactor: extract ConnectionCoordinator", 188, 164, 5),
                commit(aurora, 3, "test: reconnect timing fixtures", 240, 6, 4),
                commit(aurora, 9, "feat: migrate settings screen to new design", 470, 90, 11),
                commit(aurora, 10, "chore: bump design-tokens dependency", 8, 8, 3, mine: false),
                commit(aurora, 16, "feat: initial websocket transport", 640, 12, 9),
            ]),
            RepoActivity(repo: ledger, commits: [
                commit(ledger, 2, "fix: off-by-one in pagination cursor", 18, 22, 3),
                commit(ledger, 2, "test: pagination edge cases", 130, 4, 2),
                commit(ledger, 6, "perf: batch balance recomputation", 92, 140, 6),
                commit(ledger, 13, "refactor: split ledger into modules", 280, 260, 8),
            ]),
            RepoActivity(repo: designSystem, commits: [
                commit(designSystem, 4, "feat: liquid-glass surface tokens", 150, 30, 5, mine: false),
                commit(designSystem, 12, "fix: dark-mode contrast on chips", 40, 38, 6),
                commit(designSystem, 22, "docs: component usage guide", 92, 4, 3),
            ]),
        ]
        vm.repos = activity.sorted { $0.churn != $1.churn ? $0.churn > $1.churn : $0.commitCount > $1.commitCount }
        vm.userEmail = "ada@example.com"
        vm.gitAvailable = true
        let endExclusive = cal.dateInterval(of: .day, for: now)?.end ?? now
        vm.correlationPoints = Self.makeCorrelationPoints(
            sessions: Session.previewSamples,
            repos: vm.repos,
            unit: vm.range.bucketUnit,
            since: vm.windowStart,
            endExclusive: endExclusive,
            calendar: cal
        )
        vm.overviewSnapshot = Self.makeOverviewSnapshot(repos: vm.repos, correlation: vm.correlationPoints)
        return vm
    }

    /// A view model in the "no git activity" state — same as the live view when
    /// none of your projects are git repos with commits in the window.
    static func previewEmpty() -> GitActivityViewModel {
        let vm = GitActivityViewModel()
        vm.gitAvailable = true
        vm.userEmail = "ada@example.com"
        return vm
    }
}
#endif
