import SwiftUI
import AppKit

/// Detail pane shown when the user picks a session from the sidebar tree.
/// The layout uses the same `StatCard` + `ModelTable` visual language as the
/// Dashboard so the main window reads as one coherent surface.
///
/// Values are read fresh from the session every render — no view model, since
/// the underlying stats are already cached on ``Session/stats`` by
/// ``SessionStore``. If `stats` is `nil` (transcript hasn't been parsed yet
/// or failed to parse), the view shows a thin placeholder.
struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let session: Session
    @State private var transcriptMessages: [SessionTranscriptMessage] = []
    @State private var transcriptIsLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let stats = session.stats {
                statCards(stats)
                modelBreakdown(stats)
            } else {
                missingStatsPlaceholder
            }

            transcriptSection
            actionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session.id) {
            await loadTranscript()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.stxMuted)
                Text(session.projectDisplayName)
                    .font(.sora(11, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(Color.stxMuted)
            }

            Text(session.stats?.title.nonEmpty ?? session.externalID)
                .font(.sora(22, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if let cwd = session.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.sora(10).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Stat cards

    @ViewBuilder
    private func statCards(_ stats: SessionStats) -> some View {
        let includeCache = env.preferences.includeCacheInTokens
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCard(label: L10n.string("session.stat.total_tokens", defaultValue: "TOTAL TOKENS"),
                         value: Format.tokens(stats.totalTokens(includingCacheRead: includeCache)))
                StatCard(label: L10n.string("session.stat.estimated_cost", defaultValue: "ESTIMATED COST"),
                         value: Format.cost(stats.totalCost(for: env.preferences.costEstimationMode)))
                StatCard(label: L10n.string("session.stat.messages", defaultValue: "MESSAGES"),
                         value: "\(stats.messageCount)")
                StatCard(label: L10n.string("session.stat.last_activity", defaultValue: "LAST ACTIVITY"),
                         value: Format.relativeDate(stats.lastActivity ?? session.lastModified),
                         animatesNumericValue: false)
            }
        }
    }

    // MARK: - Model breakdown

    @ViewBuilder
    private func modelBreakdown(_ stats: SessionStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BY MODEL")
                .font(.sora(10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.stxMuted)
            ModelTable(
                models: stats.models,
                includeCacheInTotals: env.preferences.includeCacheInTokens,
                displayName: { env.store.displayName(forModel: $0, provider: session.provider) }
            )
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CONVERSATION")
                    .font(.sora(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.stxMuted)

                Spacer(minLength: 0)

                if transcriptIsLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                } else if !transcriptMessages.isEmpty {
                    Text(L10n.messageCount(transcriptMessages.count))
                        .font(.sora(10))
                        .foregroundStyle(Color.stxMuted)
                }
            }

            if transcriptIsLoading && transcriptMessages.isEmpty {
                transcriptPlaceholder(L10n.string("session.transcript.loading",
                                                  defaultValue: "Loading transcript…"))
            } else if transcriptMessages.isEmpty {
                transcriptPlaceholder(L10n.string("session.transcript.empty",
                                                  defaultValue: "No readable conversation content found in this transcript."))
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(transcriptMessages) { message in
                        TranscriptMessageRow(
                            message: message,
                            modelDisplayName: message.model.map {
                                env.store.displayName(forModel: $0, provider: session.provider)
                            }
                        )
                    }
                }
            }
        }
    }

    private func transcriptPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.sora(12))
            .foregroundStyle(Color.stxMuted)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(.compactCard(radius: 8), padding: nil)
    }

    private func loadTranscript() async {
        transcriptIsLoading = true
        let messages = await env.store.transcriptMessages(for: session)
        guard !Task.isCancelled else { return }
        transcriptMessages = messages
        transcriptIsLoading = false
    }

    // MARK: - Missing stats placeholder

    private var missingStatsPlaceholder: some View {
        Text(L10n.string("session.stats.not_parsed",
                         defaultValue: "Transcript stats haven't been parsed yet."))
            .font(.sora(12))
            .foregroundStyle(Color.stxMuted)
            .appSurface(.mainWindowCard, padding: 16)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.filePath)])
            } label: {
                Label("Reveal Transcript", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)

            if let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                } label: {
                    Label("Open Project Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .font(.sora(11))
    }
}

private struct TranscriptMessageRow: View {
    let message: SessionTranscriptMessage
    let modelDisplayName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(message.role.displayName, systemImage: message.role.symbol)
                    .font(.sora(10, weight: .semibold))
                    .foregroundStyle(message.role.accentColor)

                if let modelDisplayName {
                    Text(modelDisplayName)
                        .font(.sora(10))
                        .foregroundStyle(Color.stxMuted)
                }

                Spacer(minLength: 0)

                if let timestamp = message.timestamp {
                    Text(Format.shortDate(timestamp))
                        .font(.sora(10).monospacedDigit())
                        .foregroundStyle(Color.stxMuted)
                }
            }

            Text(message.text)
                .font(.sora(12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.compactCard(radius: 8), padding: nil)
    }
}

private extension SessionTranscriptMessage.Role {
    var symbol: String {
        switch self {
        case .user: "person"
        case .assistant: "sparkles"
        case .tool: "wrench.and.screwdriver"
        case .system: "gearshape"
        }
    }

    var accentColor: Color {
        switch self {
        case .user: .stxAccent
        case .assistant: .primary
        case .tool: .stxMuted
        case .system: .stxMuted
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
#Preview {
    SessionDetailView(session: Session.previewSamples.first!)
        .environment(AppEnvironment.preview())
        .padding(24)
        .frame(width: 760, height: 600)
        .background(Color.stxBackground)
}
#endif
