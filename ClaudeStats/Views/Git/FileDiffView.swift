import SwiftUI

/// The unified diff of one file within a commit — reached by double-clicking a
/// file in ``CommitDetailView``. Shells out to `git show -- <path>` via
/// ``GitAnalyzer``.
struct FileDiffView: View {
    let repo: GitRepo
    let hash: String
    let path: String
    var onBack: () -> Void
    private let isPreview: Bool

    @State private var diff: FileDiff?
    @State private var isLoading = false

    private static let lineFont = Font.system(size: 11, design: .monospaced)

    init(repo: GitRepo, hash: String, path: String, onBack: @escaping () -> Void) {
        self.repo = repo
        self.hash = hash
        self.path = path
        self.onBack = onBack
        self.isPreview = false
    }

    #if DEBUG
    /// Preview-only: starts already populated so the Xcode canvas renders the
    /// diff — the live view shells out to `git`.
    init(diff: FileDiff, onBack: @escaping () -> Void = {}) {
        self.repo = GitRepo(rootPath: "/Users/dev/projects/aurora")
        self.hash = "preview"
        self.path = diff.path
        self.onBack = onBack
        self.isPreview = true
        _diff = State(initialValue: diff)
    }
    #endif

    private var addCount: Int { diff?.lines.lazy.filter { $0.kind == .addition }.count ?? 0 }
    private var delCount: Int { diff?.lines.lazy.filter { $0.kind == .deletion }.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            StxRule()
            content
        }
        .task(id: path) {
            if isPreview { return }
            isLoading = true
            let r = repo, h = hash, p = path
            diff = await Task.detached(priority: .userInitiated) { GitAnalyzer().fileDiff(for: h, path: p, in: r) }.value
            isLoading = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            GitBackButton(help: "Back to the commit detail", action: onBack)

            Text(path)
                .font(.sora(11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
                .help(path)

            if isLoading { ProgressView().controlSize(.mini) }
            Spacer()
            if diff != nil {
                Text("+\(addCount)").font(.sora(9).monospacedDigit()).foregroundStyle(GitPalette.add)
                Text("−\(delCount)").font(.sora(9).monospacedDigit()).foregroundStyle(GitPalette.del)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let diff {
            if diff.isBinary {
                Text("Binary file — no textual diff.")
                    .font(.sora(10)).foregroundStyle(Color.stxMuted.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if diff.lines.isEmpty {
                Text("No changes to show.")
                    .font(.sora(10)).foregroundStyle(Color.stxMuted.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                AppScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { line in
                            diffLineRow(line)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        } else if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Text("Couldn't load the diff.")
                .font(.sora(10)).foregroundStyle(Color.stxMuted.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func diffLineRow(_ line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(gutter(line.oldLine))
                .font(Self.lineFont).foregroundStyle(Color.stxMuted.opacity(0.6))
                .frame(width: 34, alignment: .trailing)
            Text(gutter(line.newLine))
                .font(Self.lineFont).foregroundStyle(Color.stxMuted.opacity(0.6))
                .frame(width: 34, alignment: .trailing)
            Text(marker(line.kind))
                .font(Self.lineFont).foregroundStyle(markerColor(line.kind))
                .frame(width: 8, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Self.lineFont)
                .foregroundStyle(textColor(line.kind))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(rowBackground(line.kind))
    }

    private func gutter(_ n: Int?) -> String { n.map(String.init) ?? "" }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private func markerColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: GitPalette.add
        case .deletion: GitPalette.del
        default: .clear
        }
    }

    private func textColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .fileHeader, .hunkHeader: Color.stxMuted
        default: .primary
        }
    }

    private func rowBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: GitPalette.add.opacity(0.14)
        case .deletion: GitPalette.del.opacity(0.14)
        case .hunkHeader: Color.primary.opacity(0.06)
        case .fileHeader, .context: .clear
        }
    }
}

#if DEBUG
#Preview("File diff") {
    FileDiffView(diff: .preview())
        .environment(AppEnvironment.preview())
        .frame(width: 460, height: 540)
        .background(Color.stxBackground)
}
#endif
