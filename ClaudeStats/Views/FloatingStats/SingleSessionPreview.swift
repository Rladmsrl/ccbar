import SwiftUI

/// Deep preview for a single Claude session, rendered inside the floating
/// tab's expanded panel when the user is hovering an independent segment.
///
/// Layout (top-down, see spec 2026-05-28-floating-tab-hover-preview-design §4):
///   header — colored status dot + displayTitle + kind chip (FG/BG/HL)
///   activity line — "Working · <last event humanized>"
///   RECENT divider + 3 most recent events with timestamps
///   Focus button (bottom right)
///
/// The status dot's color comes from `TabFillSpec.spec(for:)` so it matches
/// the tab's segment color exactly (single source of truth for state→color).
struct SingleSessionPreview: View {
    @Environment(AppEnvironment.self) private var env
    let session: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            activityLine
            recentSection
            Spacer(minLength: 0)
            focusButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(TabFillSpec.spec(for: session.displayState).color)
                .frame(width: 9, height: 9)
            Text(session.displayTitle)
                .font(.sora(15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            kindChip
        }
    }

    private var kindChip: some View {
        Text(kindLabel)
            .font(.sora(8, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Color.stxMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private var kindLabel: String {
        switch session.kind {
        case .foreground: return L10n.string("floating.tab.session.foreground", defaultValue: "FG").uppercased()
        case .background: return L10n.string("floating.tab.session.background", defaultValue: "BG").uppercased()
        case .headless:   return L10n.string("floating.tab.session.headless",   defaultValue: "HL").uppercased()
        }
    }

    private var activityLine: some View {
        HStack(spacing: 6) {
            Text(stateVerb)
                .font(.sora(12, weight: .medium))
                .foregroundStyle(.primary)
            if let recent = session.recentEvents.last {
                Text("·")
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                Text(recent.humanized)
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
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

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("RECENT")
                    .font(.sora(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.stxMuted)
                Spacer(minLength: 6)
                Text(Format.relativeDate(session.updatedAt))
                    .font(.sora(9).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
            }
            if session.recentEvents.isEmpty {
                Text("No recent activity")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
            } else {
                ForEach(Array(session.recentEvents.suffix(3).reversed().enumerated()), id: \.offset) { _, ev in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Format.shortTime(ev.at))
                            .font(.sora(10).monospacedDigit())
                            .foregroundStyle(Color.stxMuted)
                            .frame(width: 44, alignment: .leading)
                        Text(ev.humanized)
                            .font(.sora(11))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private var focusButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await focus() }
            } label: {
                HStack(spacing: 4) {
                    Text("Focus")
                        .font(.sora(12, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canFocus ? Color.stxAccent : Color.stxMuted)
            .disabled(!canFocus)
            .help(canFocus ? "Focus this session's terminal tab" : "No terminal to focus")
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
    let session = LiveSession(
        id: "preview-001",
        displayTitle: "claude-stats",
        cwd: "/Users/dev/projects/claude-stats",
        kind: .foreground,
        state: .working,
        needsInput: false,
        sourcePid: 1234,
        startedAt: now.addingTimeInterval(-3600),
        updatedAt: now,
        lastEvent: "PreToolUse",
        recentEvents: [
            .init(event: "Bash", at: now.addingTimeInterval(-180)),
            .init(event: "Edit", at: now.addingTimeInterval(-90)),
            .init(event: "PreToolUse", at: now.addingTimeInterval(-10)),
        ]
    )
    return SingleSessionPreview(session: session)
        .environment(AppEnvironment.preview())
        .frame(width: 320, height: 280)
        .background(Color.stxBackground)
}
#endif
