import SwiftUI

struct GitRepoWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env

    let repo: GitRepo
    let repoSelectionToken: UInt64
    @State private var vm: GitRepoGraphViewModel
    @State private var inspectorMode: GitInspectorMode = .repo

    private static let rowHeight: CGFloat = 36
    private static let workingTreeRowHeight: CGFloat = 56
    private static let laneSpacing: CGFloat = 14
    private static let railPad: CGFloat = 15
    private static let nodeRadius: CGFloat = 3
    private static let graphInspectorSplitFraction: CGFloat = 0.63
    private static let graphMinWidth: CGFloat = 220
    private static let graphIdealWidth: CGFloat = 520
    private static let inspectorMinWidth: CGFloat = 290
    private static let inspectorIdealWidth: CGFloat = 300
    private static let inspectorMaxWidth: CGFloat = 360

    init(repo: GitRepo, repoSelectionToken: UInt64 = 0) {
        self.repo = repo
        self.repoSelectionToken = repoSelectionToken
        _vm = State(wrappedValue: GitRepoGraphViewModel())
    }

    #if DEBUG
    init(repo: GitRepo, previewGraph: GitGraph?, repoSelectionToken: UInt64 = 0) {
        self.repo = repo
        self.repoSelectionToken = repoSelectionToken
        if let previewGraph {
            _vm = State(wrappedValue: GitRepoGraphViewModel(previewGraph: previewGraph))
        } else {
            _vm = State(wrappedValue: GitRepoGraphViewModel())
        }
    }
    #endif

    private var railWidth: CGFloat {
        CGFloat((vm.layout?.maxColumn ?? 0)) * Self.laneSpacing + Self.railPad * 2
    }

    var body: some View {
        HoverableSplitView(
            axis: .vertical,
            primaryFraction: Self.graphInspectorSplitFraction,
            configuration: HoverableSplitViewConfiguration(
                primaryMinimumPaneLength: Self.graphMinWidth,
                secondaryMinimumPaneLength: Self.inspectorMinWidth,
                secondaryMaximumPaneLength: Self.inspectorMaxWidth
            )
        ) {
            graphColumn
                .frame(minWidth: Self.graphMinWidth, idealWidth: Self.graphIdealWidth, maxWidth: .infinity)
        } secondary: {
            GitCommitInspector(repo: repo, vm: vm, mode: $inspectorMode)
                .frame(
                    minWidth: Self.inspectorMinWidth,
                    idealWidth: Self.inspectorIdealWidth,
                    maxWidth: Self.inspectorMaxWidth
                )
        }
        .task(id: "\(repo.id)|\(vm.limit)") {
            await vm.loadGraph(repo: repo)
        }
        .task(id: "\(repo.id)|\(vm.selectedHash ?? "")") {
            await vm.loadDetail(repo: repo)
        }
        .task(id: "\(repo.id)|\(vm.selectedHash ?? "")|\(vm.diffPath ?? "")") {
            await vm.loadDiff(repo: repo)
        }
        .onAppear {
            vm.statsScope = env.preferences.gitStatsScope
        }
        .onChange(of: env.preferences.gitStatsScope) { _, newValue in
            vm.statsScope = newValue
        }
        .onChange(of: repo.id) { _, _ in
            showRepoInspector()
        }
        .onChange(of: repoSelectionToken) { _, _ in
            showRepoInspector()
        }
    }

    private var graphColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            graphHeader
            StxRule()
            graphContent
        }
    }

    private var graphHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                FadingLineText(
                    repo.displayName,
                    font: .sora(18, weight: .semibold),
                    foregroundStyle: .primary,
                    fadeWidth: 42
                )
                FadingLineText(
                    repo.rootPath,
                    font: .sora(10),
                    foregroundStyle: Color.stxMuted,
                    fadeWidth: 42
                )
                    .help(repo.rootPath)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if vm.isGraphLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if let graph = vm.graph {
                Text("\(graph.commits.count)\(graph.truncated ? "+" : "") commits")
                    .font(.sora(10).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                if graph.workingTree.isDirty {
                    Text("\(graph.workingTree.fileCount) modified")
                        .font(.sora(10).monospacedDigit())
                        .foregroundStyle(Color.stxMuted)
                }
                if graph.truncated {
                    Button {
                        vm.loadMore()
                    } label: {
                        Label("More", systemImage: "plus")
                            .font(.sora(10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.stxAccent)
                    .help("Load more commits")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var graphContent: some View {
        if let graph = vm.graph, let layout = vm.layout, graph.workingTree.isDirty || !layout.rows.isEmpty {
            let hasWorkingTree = graph.workingTree.isDirty
            AppScrollView {
                LazyVStack(spacing: 0) {
                    if hasWorkingTree {
                        GitWorkingTreeRowView(
                            summary: graph.workingTree,
                            rowHeight: Self.workingTreeRowHeight,
                            railPad: Self.railPad,
                            nodeRadius: Self.nodeRadius,
                            railWidth: railWidth,
                            railColorIndex: layout.rows.first?.colorIndex ?? 0,
                            isSelected: inspectorMode == .workingTree
                        ) {
                            inspectorMode = .workingTree
                            vm.selectWorkingTree()
                        }
                    }
                    ForEach(layout.rows) { row in
                        GitGraphRowView(
                            row: row,
                            rowHeight: Self.rowHeight,
                            laneSpacing: Self.laneSpacing,
                            railPad: Self.railPad,
                            nodeRadius: Self.nodeRadius,
                            railWidth: railWidth,
                            isSelected: inspectorMode == .commit && vm.selectedHash == row.commit.hash,
                            connectsFromTop: hasWorkingTree && row.id == layout.rows.first?.id
                        ) {
                            inspectorMode = .commit
                            vm.selectCommit(row.commit.hash)
                        }
                    }
                }
            }
        } else if vm.isGraphLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GitWorkspaceInlineEmptyState("No commits to graph.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func showRepoInspector() {
        inspectorMode = .repo
        vm.closeDiff()
    }
}

private struct GitCommitInspector: View {
    let repo: GitRepo
    @Bindable var vm: GitRepoGraphViewModel

    @Binding var mode: GitInspectorMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeader
            StxRule()
            if vm.diffPath != nil {
                diffBody
            } else {
                switch mode {
                case .commit:
                    commitBody
                case .workingTree:
                    workingTreeBody
                case .repo:
                    repoBody
                }
            }
        }
        .background(Color.primary.opacity(0.025))
        .task(id: "\(repo.id)|\(mode.rawValue)|\(vm.statsLoadID)") {
            guard mode == .repo else { return }
            await vm.loadRepoStats(repo: repo)
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            FadingLineText(
                inspectorTitle,
                font: .sora(11, weight: .semibold),
                foregroundStyle: Color.stxMuted,
                tracking: 1.0,
                fadeWidth: 36
            )
            if vm.diffPath == nil {
                Picker("", selection: $mode) {
                    ForEach(GitInspectorMode.modes(hasWorkingTree: vm.graph?.workingTree.isDirty == true)) { mode in
                        Text(LocalizedStringKey(mode.label)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: vm.graph?.workingTree.isDirty == true ? 176 : 112)
                .help("Switch inspector mode")
            }
            if vm.isDetailLoading || vm.isDiffLoading || vm.isStatsLoading {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var inspectorTitle: String {
        if vm.diffPath != nil { return "FILE DIFF" }
        switch mode {
        case .commit: return "COMMIT INSPECTOR"
        case .workingTree: return "WORKING TREE"
        case .repo: return "REPO INSPECTOR"
        }
    }

    @ViewBuilder
    private var commitBody: some View {
        if let commit = vm.selectedCommit {
            AppScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    commitSummary(commit)
                    if let detail = vm.commitDetail {
                        commitMessage(detail)
                        changedFiles(detail)
                    } else if vm.isDetailLoading {
                        GitWorkspaceInlineEmptyState("Loading commit detail.")
                    } else {
                        GitWorkspaceInlineEmptyState("Couldn't load this commit.")
                    }
                }
                .padding(14)
            }
        } else {
            GitWorkspaceInlineEmptyState("Select a commit.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func commitSummary(_ commit: GraphCommit) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GitAvatar(name: commit.author, email: commit.authorEmail)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.author)
                        .font(.sora(12, weight: .semibold))
                        .lineLimit(1)
                    Text(commit.authorEmail)
                        .font(.sora(9))
                        .foregroundStyle(Color.stxMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text(TitleSanitizer.sanitize(commit.subject) ?? commit.subject)
                .font(.sora(13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.sora(10).monospacedDigit())
                    .foregroundStyle(Color.stxAccent)
                    .textSelection(.enabled)
                Text(Format.shortDate(commit.date))
                    .font(.sora(10).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                if commit.isMerge {
                    Text("merge")
                        .font(.sora(9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }

            if !commit.refs.isEmpty {
                FlowPills(refs: commit.refs)
            }
        }
        .padding(12)
        .gitWorkspaceCard()
    }

    @ViewBuilder
    private func commitMessage(_ detail: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MESSAGE")
                .font(.sora(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.stxMuted)
            if detail.body.isEmpty {
                Text("No commit body.")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
            } else {
                Text(detail.body)
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .gitWorkspaceCard()
    }

    private func changedFiles(_ detail: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("FILES CHANGED")
                    .font(.sora(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.stxMuted)
                Spacer()
                Text("+\(detail.totalInsertions) -\(detail.totalDeletions)")
                    .font(.sora(9).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
            }
            .padding(12)

            StxRule()

            if detail.files.isEmpty {
                GitWorkspaceInlineEmptyState(detail.isMerge ? "Merge commit with no file diff." : "No file changes.")
                    .padding(12)
            } else {
                ForEach(detail.files) { file in
                    Button {
                        vm.openDiff(path: file.path)
                    } label: {
                        HStack(spacing: 8) {
                            if file.isBinary {
                                Text("bin")
                                    .font(.sora(9).monospacedDigit())
                                    .foregroundStyle(Color.stxMuted)
                            } else {
                                Text("+\(file.insertions)")
                                    .font(.sora(9).monospacedDigit())
                                    .foregroundStyle(GitPalette.add)
                                Text("-\(file.deletions)")
                                    .font(.sora(9).monospacedDigit())
                                    .foregroundStyle(GitPalette.del)
                            }
                            Text(file.path)
                                .font(.sora(10))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.stxMuted)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open diff for \(file.path)")
                    if file.id != detail.files.last?.id { StxRule() }
                }
            }
        }
        .gitWorkspaceCard()
    }

    @ViewBuilder
    private var workingTreeBody: some View {
        if let summary = vm.graph?.workingTree, summary.isDirty {
            AppScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workingTreeSummary(summary)
                    workingTreeFiles(summary)
                }
                .padding(14)
            }
        } else {
            GitWorkspaceInlineEmptyState("No working tree changes.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workingTreeSummary(_ summary: GitWorkingTreeSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(GitPalette.head)
                    .frame(width: 28, height: 28)
                    .background(Color.stxAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.sora(13, weight: .semibold))
                    Text("Changes not represented by any commit in the graph.")
                        .font(.sora(10))
                        .foregroundStyle(Color.stxMuted)
                }
            }

            HStack(spacing: 6) {
                if summary.stagedCount > 0 {
                    WorkingTreeCountPill(label: "staged", count: summary.stagedCount)
                }
                if summary.unstagedCount > 0 {
                    WorkingTreeCountPill(label: "unstaged", count: summary.unstagedCount)
                }
            }
        }
        .padding(12)
        .gitWorkspaceCard()
    }

    private func workingTreeFiles(_ summary: GitWorkingTreeSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("FILES CHANGED")
                    .font(.sora(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.stxMuted)
                Spacer()
                Text("\(summary.fileCount)")
                    .font(.sora(9).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
            }
            .padding(12)

            StxRule()

            ForEach(summary.changes) { change in
                HStack(spacing: 8) {
                    GitWorkingTreeKindPill(kind: change.kind)
                    Text(change.displayPath)
                        .font(.sora(10))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if change.isStaged {
                        Text("staged")
                            .font(.sora(8, weight: .semibold))
                            .foregroundStyle(Color.stxMuted)
                    }
                    if change.isUnstaged {
                        Text("unstaged")
                            .font(.sora(8, weight: .semibold))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if change.id != summary.changes.last?.id { StxRule() }
            }
        }
        .gitWorkspaceCard()
    }

    @ViewBuilder
    private var repoBody: some View {
        if let stats = vm.repoBaseStats {
            AppScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let warning = stats.code.warning {
                        GitWorkspaceInlineEmptyState(warning)
                            .padding(12)
                            .gitWorkspaceCard()
                    }
                    GitRepoLanguagePanel(stats: stats.code)
                    GitRepoCodeContributorsPanel(state: vm.codeOwnershipState)
                    GitRepoContributorsPanel(
                        title: "TOP COMMITTERS",
                        rows: stats.contributors,
                        value: { "\($0.commitCount)" }
                    )
                }
                .padding(14)
            }
        } else if vm.isBaseStatsLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GitWorkspaceInlineEmptyState("Couldn't load repo statistics.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        AppScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    GitBackButton(help: "Back to changed files") {
                        vm.closeDiff()
                    }
                    Text(vm.diffPath ?? "")
                        .font(.sora(12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(vm.diffPath ?? "")
                }
                .padding(12)
                .gitWorkspaceCard()

                if vm.isDiffLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if let diff = vm.fileDiff {
                    diffLines(diff)
                } else {
                    GitWorkspaceInlineEmptyState("Couldn't load this diff.")
                }
            }
            .padding(14)
        }
    }

    private func diffLines(_ diff: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if diff.isBinary {
                GitWorkspaceInlineEmptyState("Binary file.")
                    .padding(12)
            } else if diff.lines.isEmpty {
                GitWorkspaceInlineEmptyState("No diff lines.")
                    .padding(12)
            } else {
                ForEach(diff.lines) { line in
                    DiffLineRow(line: line)
                }
            }
        }
        .gitWorkspaceCard()
    }
}

private enum GitInspectorMode: String, CaseIterable, Identifiable {
    case commit
    case workingTree
    case repo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commit: return "Commit"
        case .workingTree: return "Worktree"
        case .repo: return "Repo"
        }
    }

    static func modes(hasWorkingTree: Bool) -> [GitInspectorMode] {
        hasWorkingTree ? [.commit, .workingTree, .repo] : [.commit, .repo]
    }
}

private struct WorkingTreeCountPill: View {
    let label: String
    let count: Int

    var body: some View {
        Text("\(count) \(label)")
            .font(.sora(9, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.stxMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private struct GitRepoLanguagePanel: View {
    let stats: GitRepoCodeStats

    private var totalLines: Int { max(stats.totalLines, 0) }
    private var rows: [GitStatBarRow.Model] {
        let languageRows = stats.languageRows.prefix(7).enumerated().map { index, row in
            GitStatBarRow.Model(
                id: row.language,
                rank: index + 1,
                label: row.language,
                value: languageValue(row),
                ratio: row.byteShare,
                color: Color.stxRamp[index % Color.stxRamp.count]
            )
        }
        return [
            GitStatBarRow.Model(
                id: "total",
                rank: nil,
                label: "Total Lines",
                value: Format.tokens(totalLines),
                ratio: totalLines > 0 ? 1 : 0,
                color: GitPalette.head
            )
        ] + languageRows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader(title: "LANGUAGE MIX", detail: "Linguist bytes + scc SLOC")
            if stats.languageRows.isEmpty {
                GitWorkspaceInlineEmptyState("No language statistics available.")
                    .gitWorkspaceCard()
            } else {
                GitStatBarList(rows: rows)
            }
            HStack(spacing: 6) {
                Text("\(stats.analyzedFiles) analyzed")
                Text("-")
                Text("\(stats.skippedFiles) skipped")
                Text("-")
                Text(Format.bytes(stats.totalBytes))
            }
            .font(.sora(9))
            .foregroundStyle(Color.stxMuted)
        }
    }

    private func languageValue(_ row: GitRepoCodeStats.LanguageRow) -> String {
        "\(Format.percent(row.byteShare)) \(Format.bytes(row.sizeBytes)) / \(Format.tokens(row.sourceLines))"
    }
}

private struct GitRepoContributorsPanel: View {
    let title: String
    let rows: [GitContributorStat]
    let value: (GitContributorStat) -> String

    private var totalCommits: Int {
        rows.reduce(0) { $0 + $1.commitCount }
    }

    private var models: [GitStatBarRow.Model] {
        guard totalCommits > 0 else { return [] }
        let total = GitStatBarRow.Model(
            id: "total",
            rank: nil,
            label: "Total Commits",
            value: "\(totalCommits)",
            ratio: 1,
            color: GitPalette.head
        )
        return [total] + rows.prefix(7).enumerated().map { index, row in
            GitStatBarRow.Model(
                id: row.id,
                rank: index + 1,
                label: row.displayName,
                value: value(row),
                ratio: row.share,
                color: Color.stxRamp[index % Color.stxRamp.count]
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader(title: title, detail: nil)
            if models.isEmpty {
                GitWorkspaceInlineEmptyState("No commits to count.")
                    .gitWorkspaceCard()
            } else {
                GitStatBarList(rows: models)
            }
        }
    }
}

private struct GitRepoCodeContributorsPanel: View {
    let state: GitCodeOwnershipLoadState

    private var rows: [GitCodeContributionStat] {
        if case .loaded(let rows) = state {
            return rows
        }
        return []
    }

    private var totalLines: Int {
        rows.reduce(0) { $0 + $1.lineCount }
    }

    private var models: [GitStatBarRow.Model] {
        guard totalLines > 0 else { return [] }
        let total = GitStatBarRow.Model(
            id: "total",
            rank: nil,
            label: "Total Lines",
            value: Format.tokens(totalLines),
            ratio: 1,
            color: GitPalette.head
        )
        return [total] + rows.prefix(7).enumerated().map { index, row in
            GitStatBarRow.Model(
                id: row.id,
                rank: index + 1,
                label: row.displayName,
                value: "\(Format.tokens(row.lineCount)) \(Format.percent(row.share))",
                ratio: row.share,
                color: Color.stxRamp[index % Color.stxRamp.count]
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader(title: "CODE SHARE", detail: "Blamed Lines")
            switch state {
            case .idle:
                GitWorkspaceInlineEmptyState("Code attribution is waiting for language statistics.")
                    .gitWorkspaceCard()
            case .loading:
                GitWorkspaceInlineEmptyState("Attributing code lines.")
                    .gitWorkspaceCard()
            case .failed(let message):
                GitWorkspaceInlineEmptyState(message)
                    .gitWorkspaceCard()
            case .loaded where models.isEmpty:
                GitWorkspaceInlineEmptyState("No code lines to attribute.")
                    .gitWorkspaceCard()
            case .loaded:
                GitStatBarList(rows: models)
            }
        }
    }
}

private struct GitStatBarList: View {
    let rows: [GitStatBarRow.Model]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                GitStatBarRow(row: row)
                if row.id != rows.last?.id { StxRule() }
            }
        }
        .gitWorkspaceCard()
    }
}

private struct GitStatBarRow: View {
    struct Model: Identifiable {
        let id: String
        let rank: Int?
        let label: String
        let value: String
        let ratio: Double
        let color: Color
    }

    let row: Model

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.035))
                    .frame(height: 28)
                Capsule()
                    .fill(row.color.opacity(0.88))
                    .frame(width: max(6, proxy.size.width * min(max(row.ratio, 0), 1)), height: 28)
                HStack(spacing: 7) {
                    Text(rankLabel)
                        .font(.sora(9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(width: 18)
                    Text(row.label)
                        .font(.sora(11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(row.value)
                        .font(.sora(11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 42)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.label), \(row.value)"))
    }

    private var rankLabel: String {
        row.rank.map { "\($0)" } ?? "#"
    }
}

private func panelHeader(title: String, detail: String?) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(title)
            .font(.sora(13, weight: .semibold))
            .tracking(0.8)
        Spacer()
        if let detail {
            Text(detail)
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
        }
    }
}

private struct FlowPills: View {
    let refs: [GitRef]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                    GitRefPill(ref: ref)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "")
                .font(.sora(9).monospacedDigit())
                .foregroundStyle(Color.stxMuted.opacity(0.65))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 6)
            Text(line.newLine.map(String.init) ?? "")
                .font(.sora(9).monospacedDigit())
                .foregroundStyle(Color.stxMuted.opacity(0.65))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 8)
            Text(prefix)
                .font(.sora(9).monospacedDigit())
                .foregroundStyle(prefixColor)
                .frame(width: 14, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(backgroundColor)
    }

    private var prefix: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .hunkHeader: "@"
        default: " "
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .addition: GitPalette.add
        case .deletion: GitPalette.del
        case .hunkHeader: Color.stxAccent
        default: Color.stxMuted
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .fileHeader, .hunkHeader: Color.stxMuted
        case .addition: GitPalette.add
        case .deletion: GitPalette.del
        case .context: .primary
        }
    }

    private var backgroundColor: Color {
        switch line.kind {
        case .addition: GitPalette.add.opacity(0.10)
        case .deletion: GitPalette.del.opacity(0.10)
        case .hunkHeader: Color.stxAccent.opacity(0.08)
        default: .clear
        }
    }
}

private struct GitWorkspaceInlineEmptyState: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.sora(10))
            .foregroundStyle(Color.stxMuted.opacity(0.8))
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
    }
}

private extension View {
    func gitWorkspaceCard() -> some View {
        appSurface(.compactCard(radius: 10))
    }
}

#if DEBUG
#Preview("Repo workspace") {
    GitRepoWorkspaceView(repo: GitGraph.preview().repo, previewGraph: .preview())
        .environment(AppEnvironment.preview())
        .frame(width: 760, height: 560)
        .background(Color.stxBackground)
}
#endif
