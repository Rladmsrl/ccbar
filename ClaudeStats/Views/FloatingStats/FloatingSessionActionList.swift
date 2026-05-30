import SwiftUI

struct FloatingSessionActionList: View {
    @Environment(AppEnvironment.self) private var env

    let model: FloatingSessionActionListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if model.rows.isEmpty {
                emptyState
            } else {
                rows
            }

            if let summary = model.backgroundSummary {
                backgroundSummary(summary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.sora(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.stxMuted)
                Text(headerSubtitle)
                    .font(.sora(12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(model.rows.count)")
                .font(.sora(10, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.stxMuted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private var headerTitle: String {
        model.rows.contains { $0.attention.isActionable }
            ? "NEEDS ATTENTION"
            : "CURRENT SESSIONS"
    }

    private var headerSubtitle: String {
        if model.rows.isEmpty { return "No action needed" }
        if model.rows.count == 1 { return "1 session shown" }
        return "\(model.rows.count) sessions shown"
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.rows) { row in
                    FloatingSessionActionRow(row: row) {
                        activate(row)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.stxMuted)
            Text("Nothing needs attention")
                .font(.sora(12, weight: .medium))
                .foregroundStyle(.primary)
            Text("No session needs review right now.")
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func backgroundSummary(_ summary: FloatingBackgroundSummaryModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 10, weight: .medium))
            Text(backgroundSummaryText(summary))
                .font(.sora(10).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(Color.stxMuted)
        .padding(.top, 2)
    }

    private func backgroundSummaryText(_ summary: FloatingBackgroundSummaryModel) -> String {
        let quiet = summary.hiddenCount == 1 ? "1 quiet BG" : "\(summary.hiddenCount) quiet BG"
        guard summary.runningCount > 0 else { return quiet }
        return "\(quiet) · \(summary.runningCount) running"
    }

    private func activate(_ row: FloatingSessionActionRowModel) {
        env.sessionRegistry.markRead(row.session.id)
        guard row.canFocus else { return }
        Task { await focus(row.session) }
    }

    private func focus(_ session: LiveSession) async {
        let result = await env.sessionFocus.focus(session: session)
        if case .failure(let error) = result {
            Log.session.error("focus failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct FloatingSessionActionRow: View {
    let row: FloatingSessionActionRowModel
    var onActivate: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onActivate) {
            HStack(alignment: .center, spacing: 9) {
                statusIcon
                textStack
                Spacer(minLength: 6)
                trailingContent
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help(row.canFocus ? "Focus this session" : "Acknowledge this session")
        .accessibilityLabel("\(row.session.displayTitle), \(row.subtitle)")
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(attentionColor.opacity(0.16))
                .frame(width: 22, height: 22)
            Image(systemName: attentionSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(attentionColor)
        }
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.session.displayTitle)
                    .font(.sora(11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                kindChip
            }
            Text(row.subtitle)
                .font(.sora(9))
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var kindChip: some View {
        Text(kindLabel)
            .font(.sora(7, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Color.stxMuted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private var trailingContent: some View {
        if row.canFocus {
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.stxAccent)
                .frame(width: 18, height: 18)
        } else if row.attention.isActionable {
            Image(systemName: "eye")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.stxMuted)
                .frame(width: 18, height: 18)
        }
    }

    private var kindLabel: String {
        switch row.session.kind {
        case .foreground: return "FG"
        case .background: return "BG"
        case .headless: return "HL"
        }
    }

    private var attentionSymbol: String {
        switch row.attention {
        case .needsAnswer: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .doneUnread: return "checkmark.circle.fill"
        case .running: return "play.fill"
        case .idle: return "circle.fill"
        }
    }

    private var attentionColor: Color {
        if row.attention == .needsAnswer {
            return TabFillSpec.needsInputSpec(reduceMotion: true).color
        }
        let spec = TabFillSpec.spec(for: row.session.displayState)
        return spec.fillVisible ? spec.color : Color.stxMuted.opacity(0.48)
    }
}

#if DEBUG
#Preview {
    let now = Date.now
    let sessions: [LiveSession] = [
        LiveSession(
            id: "needs",
            displayTitle: "claude-stats",
            kind: .foreground,
            state: .working,
            needsInput: true,
            sourcePid: 1234,
            startedAt: now.addingTimeInterval(-900),
            updatedAt: now,
            lastEvent: "PreToolUse"
        ),
        LiveSession(
            id: "done-bg",
            displayTitle: "release-worker",
            kind: .background,
            state: .idle,
            startedAt: now.addingTimeInterval(-800),
            updatedAt: now.addingTimeInterval(-60),
            lastEvent: "Stop",
            recentEvents: [.init(event: "Stop", at: now.addingTimeInterval(-60))]
        ),
        LiveSession(
            id: "quiet-bg",
            displayTitle: "quiet-worker",
            kind: .background,
            state: .working,
            startedAt: now.addingTimeInterval(-700),
            updatedAt: now.addingTimeInterval(-30),
            lastEvent: "PreToolUse"
        ),
    ]
    let model = FloatingSessionActionPresenter.makeModel(
        sessions: sessions,
        unreadDoneSessions: ["done-bg"],
        now: now
    )
    return FloatingSessionActionList(model: model)
        .environment(AppEnvironment.preview())
        .frame(width: 320, height: 360)
        .background(Color.stxBackground)
}
#endif
