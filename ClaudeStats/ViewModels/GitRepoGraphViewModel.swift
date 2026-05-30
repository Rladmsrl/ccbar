import Foundation
import Observation

@MainActor
@Observable
final class GitRepoGraphViewModel {
    private(set) var graph: GitGraph?
    private(set) var layout: GraphLayout?
    private(set) var isGraphLoading = false
    private(set) var isDetailLoading = false
    private(set) var isDiffLoading = false
    private(set) var isBaseStatsLoading = false
    private(set) var isCodeOwnershipLoading = false
    private(set) var commitDetail: CommitDetail?
    private(set) var fileDiff: FileDiff?
    private(set) var repoBaseStats: GitRepoInspectorBaseStats?
    private(set) var codeOwnershipState: GitCodeOwnershipLoadState = .idle
    private(set) var currentRepoID: String?
    private(set) var loadedLimit = 0

    var statsScope: GitStatsScope = .head {
        didSet {
            guard oldValue != statsScope else { return }
            invalidateBaseStatsRequest()
            invalidateCodeOwnershipRequest()
            repoBaseStats = nil
            codeOwnershipState = .idle
        }
    }
    var selectedHash: String?
    var diffPath: String?
    var limit = 200

    private let isPreview: Bool
    @ObservationIgnored private var graphRequestID: UInt64 = 0
    @ObservationIgnored private var detailRequestID: UInt64 = 0
    @ObservationIgnored private var diffRequestID: UInt64 = 0
    @ObservationIgnored private var baseStatsRequestID: UInt64 = 0
    @ObservationIgnored private var codeOwnershipRequestID: UInt64 = 0

    init() {
        isPreview = false
    }

    #if DEBUG
    init(previewGraph: GitGraph) {
        graph = previewGraph
        layout = GraphLayout.build(previewGraph.commits)
        currentRepoID = previewGraph.repo.id
        loadedLimit = previewGraph.commits.count
        selectedHash = previewGraph.commits.first?.hash
        if let commit = previewGraph.commits.first {
            commitDetail = .preview(
                from: commit,
                files: GitGraph.previewFileChanges()[commit.hash] ?? []
            )
        }
        repoBaseStats = .preview
        codeOwnershipState = .loaded(GitRepoCodeOwnershipStats.preview.codeContributors)
        isPreview = true
    }
    #endif

    var isStatsLoading: Bool {
        isBaseStatsLoading || isCodeOwnershipLoading
    }

    var selectedCommit: GraphCommit? {
        guard let selectedHash else { return nil }
        return graph?.commits.first { $0.hash == selectedHash }
    }

    var graphLoadID: String {
        "\(currentRepoID ?? "")|\(limit)"
    }

    var detailLoadID: String {
        "\(currentRepoID ?? "")|\(selectedHash ?? "")"
    }

    var diffLoadID: String {
        "\(currentRepoID ?? "")|\(selectedHash ?? "")|\(diffPath ?? "")"
    }

    var statsLoadID: String {
        "\(currentRepoID ?? "")|\(statsScope.rawValue)"
    }

    func loadGraph(repo: GitRepo) async {
        if currentRepoID != repo.id {
            reset(for: repo)
        }
        if isPreview { return }
        if graph != nil, loadedLimit == limit { return }

        graphRequestID &+= 1
        let requestID = graphRequestID
        isGraphLoading = true
        defer { finishGraphRequest(requestID) }

        let requestedRepoID = repo.id
        let requestedLimit = limit
        let loadedGraph = await Task.detached(priority: .userInitiated) {
            GitAnalyzer().graph(for: repo, limit: requestedLimit)
        }.value

        guard graphRequestID == requestID,
              currentRepoID == requestedRepoID,
              limit == requestedLimit else { return }
        graph = loadedGraph
        layout = loadedGraph.map { GraphLayout.build($0.commits) }
        loadedLimit = requestedLimit
        reconcileSelection()
    }

    func loadDetail(repo: GitRepo) async {
        guard let hash = selectedHash else {
            invalidateDetailRequest()
            commitDetail = nil
            return
        }
        if isPreview { return }

        detailRequestID &+= 1
        let requestID = detailRequestID
        isDetailLoading = true
        defer { finishDetailRequest(requestID) }

        let requestedRepoID = repo.id
        let requestedHash = hash
        let detail = await Task.detached(priority: .userInitiated) {
            GitAnalyzer().commitDetail(for: requestedHash, in: repo)
        }.value

        guard detailRequestID == requestID,
              currentRepoID == requestedRepoID,
              selectedHash == requestedHash else { return }
        commitDetail = detail
    }

    func loadDiff(repo: GitRepo) async {
        guard let hash = selectedHash, let path = diffPath else {
            invalidateDiffRequest()
            fileDiff = nil
            return
        }
        if isPreview {
            #if DEBUG
            fileDiff = .preview(path: path)
            #endif
            return
        }

        diffRequestID &+= 1
        let requestID = diffRequestID
        isDiffLoading = true
        defer { finishDiffRequest(requestID) }

        let requestedRepoID = repo.id
        let requestedHash = hash
        let requestedPath = path
        let diff = await Task.detached(priority: .userInitiated) {
            GitAnalyzer().fileDiff(for: requestedHash, path: requestedPath, in: repo)
        }.value

        guard diffRequestID == requestID,
              currentRepoID == requestedRepoID,
              selectedHash == requestedHash,
              diffPath == requestedPath else { return }
        fileDiff = diff
    }

    func loadRepoStats(repo: GitRepo) async {
        if currentRepoID != repo.id {
            reset(for: repo)
        }
        if isPreview { return }

        let requestedScope = statsScope
        let baseStats: GitRepoInspectorBaseStats
        if let existing = repoBaseStats {
            baseStats = existing
        } else {
            baseStatsRequestID &+= 1
            let requestID = baseStatsRequestID
            isBaseStatsLoading = true
            defer { finishBaseStatsRequest(requestID) }

            let requestedRepoID = repo.id
            let task = Task.detached(priority: .userInitiated) {
                GitRepoStatsService().baseStats(for: repo, scope: requestedScope)
            }
            let loadedBaseStats = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }

            guard baseStatsRequestID == requestID,
                  currentRepoID == requestedRepoID,
                  statsScope == requestedScope,
                  !Task.isCancelled else { return }
            repoBaseStats = loadedBaseStats
            baseStats = loadedBaseStats
        }

        guard !isCodeOwnershipLoading else { return }
        if case .loaded = codeOwnershipState { return }
        await loadCodeOwnership(repo: repo, scope: requestedScope, codeFilePaths: baseStats.code.codeFilePaths)
    }

    private func loadCodeOwnership(repo: GitRepo, scope: GitStatsScope, codeFilePaths: [String]) async {
        codeOwnershipRequestID &+= 1
        let requestID = codeOwnershipRequestID
        isCodeOwnershipLoading = true
        codeOwnershipState = .loading
        defer { finishCodeOwnershipRequest(requestID) }

        let requestedRepoID = repo.id
        let task = Task.detached(priority: .utility) {
            await GitRepoStatsService().codeOwnershipStats(for: repo, scope: scope, codeFilePaths: codeFilePaths)
        }
        let ownership = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        guard codeOwnershipRequestID == requestID,
              currentRepoID == requestedRepoID,
              statsScope == scope,
              !Task.isCancelled else { return }
        codeOwnershipState = .loaded(ownership.codeContributors)
    }

    func selectCommit(_ hash: String) {
        guard selectedHash != hash else { return }
        invalidateDetailRequest()
        invalidateDiffRequest()
        selectedHash = hash
        commitDetail = nil
        diffPath = nil
        fileDiff = nil
    }

    func selectWorkingTree() {
        invalidateDetailRequest()
        invalidateDiffRequest()
        selectedHash = nil
        commitDetail = nil
        diffPath = nil
        fileDiff = nil
    }

    func openDiff(path: String) {
        guard diffPath != path else { return }
        invalidateDiffRequest()
        diffPath = path
        fileDiff = nil
    }

    func closeDiff() {
        invalidateDiffRequest()
        diffPath = nil
        fileDiff = nil
    }

    func loadMore() {
        limit += 200
    }

    private func reset(for repo: GitRepo) {
        invalidateGraphRequest()
        invalidateDetailRequest()
        invalidateDiffRequest()
        invalidateBaseStatsRequest()
        invalidateCodeOwnershipRequest()
        currentRepoID = repo.id
        graph = nil
        layout = nil
        commitDetail = nil
        fileDiff = nil
        repoBaseStats = nil
        codeOwnershipState = .idle
        selectedHash = nil
        diffPath = nil
        loadedLimit = 0
        limit = 200
    }

    private func reconcileSelection() {
        guard let commits = graph?.commits, !commits.isEmpty else {
            invalidateDetailRequest()
            invalidateDiffRequest()
            selectedHash = nil
            commitDetail = nil
            diffPath = nil
            fileDiff = nil
            return
        }
        if let selectedHash, commits.contains(where: { $0.hash == selectedHash }) {
            return
        }
        invalidateDetailRequest()
        invalidateDiffRequest()
        selectedHash = nil
        commitDetail = nil
        diffPath = nil
        fileDiff = nil
    }

    private func invalidateGraphRequest() {
        graphRequestID &+= 1
        isGraphLoading = false
    }

    private func invalidateDetailRequest() {
        detailRequestID &+= 1
        isDetailLoading = false
    }

    private func invalidateDiffRequest() {
        diffRequestID &+= 1
        isDiffLoading = false
    }

    private func invalidateBaseStatsRequest() {
        baseStatsRequestID &+= 1
        isBaseStatsLoading = false
    }

    private func invalidateCodeOwnershipRequest() {
        codeOwnershipRequestID &+= 1
        isCodeOwnershipLoading = false
        if case .loading = codeOwnershipState {
            codeOwnershipState = .idle
        }
    }

    private func finishGraphRequest(_ requestID: UInt64) {
        if graphRequestID == requestID {
            isGraphLoading = false
        }
    }

    private func finishDetailRequest(_ requestID: UInt64) {
        if detailRequestID == requestID {
            isDetailLoading = false
        }
    }

    private func finishDiffRequest(_ requestID: UInt64) {
        if diffRequestID == requestID {
            isDiffLoading = false
        }
    }

    private func finishBaseStatsRequest(_ requestID: UInt64) {
        if baseStatsRequestID == requestID {
            isBaseStatsLoading = false
        }
    }

    private func finishCodeOwnershipRequest(_ requestID: UInt64) {
        if codeOwnershipRequestID == requestID {
            isCodeOwnershipLoading = false
        }
    }
}

#if DEBUG
private extension GitRepoInspectorBaseStats {
    static let preview = GitRepoInspectorBaseStats(
        code: GitRepoCodeStats(
            engine: .linguist,
            scope: .head,
            warning: nil,
            totalFiles: 24,
            analyzedFiles: 19,
            skippedFiles: 5,
            totalBytes: 552_480,
            totalLines: 18_712,
            sourceLines: 15_920,
            codeFilePaths: [
                "ClaudeStats/App/ClaudeStatsApp.swift",
                "ClaudeStats/Services/GitAnalyzer.swift",
                "ClaudeStats/Views/Git/MainWindow/GitRepoWorkspaceView.swift",
                "project.yml",
                "scripts/run-debug.sh",
            ],
            languageRows: [
                .init(language: "Swift", fileCount: 14, sizeBytes: 489_600, byteShare: 0.886, totalLines: 17_313, sourceLines: 14_880),
                .init(language: "YAML", fileCount: 2, sizeBytes: 24_480, byteShare: 0.044, totalLines: 372, sourceLines: 320),
                .init(language: "Shell", fileCount: 2, sizeBytes: 17_880, byteShare: 0.032, totalLines: 360, sourceLines: 300),
                .init(language: "JSON", fileCount: 1, sizeBytes: 11_920, byteShare: 0.022, totalLines: 281, sourceLines: 260),
                .init(language: "Markdown", fileCount: 1, sizeBytes: 8_600, byteShare: 0.016, totalLines: 236, sourceLines: 160),
            ]
        ),
        contributors: [
            GitContributorStat(name: "Grace", email: "grace@example.com", commitCount: 46, share: 46.0 / 56.0),
            GitContributorStat(name: "Codex", email: "codex@example.com", commitCount: 7, share: 7.0 / 56.0),
            GitContributorStat(name: "Ada", email: "ada@example.com", commitCount: 3, share: 3.0 / 56.0),
        ]
    )
}

private extension GitRepoCodeOwnershipStats {
    static let preview = GitRepoCodeOwnershipStats(
        codeContributors: [
            GitCodeContributionStat(name: "Grace", email: "grace@example.com", lineCount: 15_840, share: 15_840.0 / 18_712.0),
            GitCodeContributionStat(name: "Codex", email: "codex@example.com", lineCount: 2_104, share: 2_104.0 / 18_712.0),
            GitCodeContributionStat(name: "Ada", email: "ada@example.com", lineCount: 768, share: 768.0 / 18_712.0),
        ]
    )
}
#endif
