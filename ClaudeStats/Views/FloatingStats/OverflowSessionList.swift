import SwiftUI

/// Mini list view for the floating tab's overflow segment hover preview.
/// Shows the N sessions aggregated into that segment, each as a compact
/// row with status + Focus button. Used in place of `SingleSessionPreview`
/// when the user hovers the overflow segment instead of an independent one.
///
/// `sessions` is the slice that `TabSegmenter` aggregated into the overflow
/// segment — typically `visibleSessions.suffix(from: cap - 1)`.
struct OverflowSessionList: View {
    let sessions: [LiveSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        OverflowSessionRow(session: session)
                        if index < sessions.count - 1 {
                            Rectangle()
                                .fill(Color.stxStroke.opacity(0.4))
                                .frame(height: 1)
                                .padding(.vertical, 4)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.format(
                "floating.tab.preview.overflow.header",
                defaultValue: "%d SESSIONS · OVERFLOW",
                sessions.count
            ))
                .font(.sora(9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.stxMuted)
            Spacer(minLength: 6)
        }
    }
}

/// Single row inside `OverflowSessionList`. Mirrors `SingleSessionPreview`'s
/// header row but compressed; intentionally NOT exposed (private to the
/// overflow list).
private struct OverflowSessionRow: View {
    @Environment(AppEnvironment.self) private var env
    let session: LiveSession

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(TabFillSpec.spec(for: session.displayState).color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.sora(11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(stateVerb) · \(Format.relativeDate(session.updatedAt))")
                    .font(.sora(9).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Task { await focus() }
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canFocus ? Color.stxAccent : Color.stxMuted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canFocus)
            .help(canFocus ? "Focus this session's terminal tab" : "No terminal to focus")
        }
        .padding(.vertical, 4)
    }

    private var stateVerb: String {
        switch session.displayState {
        case .idle:      return L10n.string("floating.tab.preview.state.idle",      defaultValue: "Idle")
        case .thinking:  return L10n.string("floating.tab.preview.state.thinking",  defaultValue: "Thinking")
        case .working:   return L10n.string("floating.tab.preview.state.working",   defaultValue: "Working")
        case .juggling:  return L10n.string("floating.tab.preview.state.juggling",  defaultValue: "Juggling")
        case .attention: return L10n.string("floating.tab.preview.state.attention", defaultValue: "Attention")
        case .sweeping:  return L10n.string("floating.tab.preview.state.sweeping",  defaultValue: "Compacting")
        case .error:     return L10n.string("floating.tab.preview.state.error",     defaultValue: "Error")
        case .sleeping:  return L10n.string("floating.tab.preview.state.sleeping",  defaultValue: "Ended")
        }
    }

    private var canFocus: Bool {
        session.sourcePid != nil && session.kind != .background
    }

    private func focus() async {
        let result = await env.sessionFocus.focus(session: session)
        if case .failure(let error) = result {
            Log.session.error("focus failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#if DEBUG
#Preview {
    let now = Date.now
    let sessions: [LiveSession] = [
        LiveSession(id: "ov-1", displayTitle: "another-project",
                    kind: .foreground, state: .working, sourcePid: 1000,
                    startedAt: now, updatedAt: now.addingTimeInterval(-60),
                    lastEvent: "PreToolUse"),
        LiveSession(id: "ov-2", displayTitle: "test-runner",
                    kind: .foreground, state: .idle, sourcePid: 1001,
                    startedAt: now, updatedAt: now.addingTimeInterval(-180),
                    lastEvent: "Stop"),
        LiveSession(id: "ov-3", displayTitle: "bg-worker",
                    kind: .background, state: .working,
                    startedAt: now, updatedAt: now.addingTimeInterval(-30),
                    lastEvent: "PreToolUse"),
    ]
    return OverflowSessionList(sessions: sessions)
        .environment(AppEnvironment.preview())
        .frame(width: 320, height: 280)
        .background(Color.stxBackground)
}
#endif
