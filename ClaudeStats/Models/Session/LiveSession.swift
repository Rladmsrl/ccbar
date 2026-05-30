import Foundation

/// A live, in-flight Claude Code session — the runtime counterpart to
/// ``Session`` (which represents a transcript file on disk).
///
/// Fed by two sources:
///   - **CC hook events** posted to `/state/<EVENT>` on our HTTP server.
///     Covers anything that triggers a hook: foreground terminal `claude`,
///     `claude --bg` daemon sessions, remote sessions, etc.
///   - **`claude agents --json`** at startup, to backfill background daemon
///     sessions that already exist when the app launches.
///
/// `id` is the CC `session_id` (a UUID string). When both sources see the
/// same id, the later event (by `updatedAt`) wins; `kind` only ever
/// "upgrades" from foreground → background (once we learn a session is in
/// the daemon roster we trust that classification).
struct LiveSession: Sendable, Identifiable, Hashable {
    /// CC `session_id`. Stable across the life of one chat.
    let id: String
    /// "claude-code" today; reserved for a future second provider.
    let agentId: String

    /// Identifier passed to daemon management commands. For background
    /// agents, the CLI roster is keyed by the short job id while hooks use
    /// the full daemon session UUID for merging.
    var managementId: String?

    /// Best-effort display title. Falls back through: explicit title from
    /// the hook payload → cwd basename → first 8 chars of `id`.
    var displayTitle: String
    var cwd: String?

    /// Where this session lives. Used by the HUD to decide which row
    /// actions to show (BG → stop / respawn / rm; FG → focus only).
    var kind: Kind

    /// Whether the session is mid-turn (`.working`) or sitting (`.idle`).
    /// Recomputed on every hook event.
    var state: State

    /// True when a `PermissionRequest` is currently pending against this
    /// session. Toggled by `PermissionStore` via `markNeedsInput(_:)`.
    var needsInput: Bool

    /// Process id of the terminal hosting this session, if known. Foreground
    /// sessions only; required for `SessionFocusService` to find the right
    /// Terminal/iTerm/Ghostty tab. Set by hook payload when present.
    var sourcePid: Int?

    /// Wall-clock when we first saw this session. For BG sessions we trust
    /// the `agents --json` `startedAt` field; for FG we fall back to the
    /// first hook arrival.
    let startedAt: Date
    var updatedAt: Date

    /// Last hook event name we saw, used by `badge` to distinguish
    /// `done` (Stop) from `interrupted` (StopFailure).
    var lastEvent: String?

    /// Last few hook events, capped. Used by ``badge`` to derive
    /// done / interrupted from the latest non-trivial event. Mirrors
    /// clawd's `recentEvents`.
    var recentEvents: [RecentEvent]

    init(
        id: String,
        agentId: String = "claude-code",
        managementId: String? = nil,
        displayTitle: String,
        cwd: String? = nil,
        kind: Kind = .foreground,
        state: State = .working,
        needsInput: Bool = false,
        sourcePid: Int? = nil,
        startedAt: Date = .now,
        updatedAt: Date = .now,
        lastEvent: String? = nil,
        recentEvents: [RecentEvent] = []
    ) {
        self.id = id
        self.agentId = agentId
        self.managementId = managementId
        self.displayTitle = displayTitle
        self.cwd = cwd
        self.kind = kind
        self.state = state
        self.needsInput = needsInput
        self.sourcePid = sourcePid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastEvent = lastEvent
        self.recentEvents = recentEvents
    }

    enum Kind: String, Sendable, Hashable, Codable {
        /// Hook-only sighting — assume an interactive terminal until proven
        /// otherwise.
        case foreground
        /// In the daemon roster (`claude agents --json` saw it).
        case background
        /// Ran with `-p` / `--print`. We don't currently detect this from
        /// hook payload (CC doesn't expose it), so this state is reserved
        /// for the future PID-chain inspection path.
        case headless
    }

    enum State: String, Sendable, Hashable, Codable {
        case working
        case idle
    }

    enum Badge: String, Sendable, Hashable {
        case running
        case done
        case interrupted
        case idle
        case needsInput
    }

    /// Finer-grained presentation state mirroring clawd's
    /// `EVENT_TO_STATE` table. Drives the floating tab's gradient fill
    /// (one colour per state). ``Badge`` is the legacy 5-bucket roll-up
    /// kept for the HUD count dot; ``DisplayState`` is the new richer
    /// signal so the tab can distinguish e.g. "thinking" (user just
    /// prompted) from "working" (mid tool call).
    enum DisplayState: String, Sendable, Hashable, Codable {
        case idle
        case thinking
        case working
        case juggling
        case attention
        case sweeping
        case error
        case sleeping
    }

    struct RecentEvent: Sendable, Hashable, Codable {
        let event: String
        let at: Date
    }

    /// Derive the clawd-style internal state from `state` + recent events.
    /// `state == .idle` 时优先扫 `recentEvents` 找终止事件(`Stop` /
    /// `StopFailure` / `PostToolUseFailure` / `PostCompact` / `SessionEnd`),跳过 `SubagentStop` /
    /// `PostToolUse` 这类"working 残音"——它们会在乱序 hook 到达时晚于
    /// `Stop` 覆盖 `lastEvent`,但 `state == .idle` 是 `Stop` 已经处理过的
    /// 铁证。`state == .working` 时退回 `lastEvent` 单值映射。
    /// Unknown / no event → ``DisplayState/idle``.
    var displayState: DisplayState {
        if state == .idle {
            for ev in recentEvents.reversed() {
                switch ev.event {
                case "Stop", "PostCompact":
                    return .attention
                case "StopFailure", "PostToolUseFailure":
                    return .error
                case "SessionEnd":
                    return .sleeping
                default:
                    continue
                }
            }
            return .idle
        }
        // state == .working
        switch lastEvent {
        case "UserPromptSubmit":
            return .thinking
        // SubagentStop 实际走 idle 分支 (它在 idleEvents 里, state 会被压成 .idle);
        // 留在这里是防御性: 若未来从 idleEvents 移除, displayState 仍然给出
        // "working" 色而不是 fall-through 到 .idle。
        case "PreToolUse", "PostToolUse", "SubagentStop":
            return .working
        case "SubagentStart":
            return .juggling
        case "PreCompact":
            return .sweeping
        case "StopFailure", "PostToolUseFailure":
            return .error
        default:
            return .idle
        }
    }

    /// Highest-priority status display. Order matches clawd's HUD legend:
    /// `needsInput` → red dot, `interrupted` → orange, `done` → grey
    /// (with bell on first sight), `running` → green, `idle` → grey.
    var badge: Badge {
        if needsInput { return .needsInput }
        if state == .working { return .running }
        // state == .idle: look at most recent event to distinguish
        //   - Stop / PostCompact → done
        //   - StopFailure / PostToolUseFailure → interrupted
        //   - SessionEnd / others → idle
        let latest = recentEvents.last?.event ?? lastEvent
        switch latest {
        case "StopFailure", "PostToolUseFailure":
            return .interrupted
        case "Stop", "PostCompact":
            return .done
        default:
            return .idle
        }
    }
}

extension LiveSession {
    static let recentEventLimit = 8

    /// Hook events that count as "currently doing work".
    static let workingEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit",
        "PreToolUse", "PostToolUse",
        "SubagentStart",
    ]

    /// Hook events that count as "settled / not actively running".
    static let idleEvents: Set<String> = [
        "Stop", "StopFailure",
        "SessionEnd", "SubagentStop",
        "PostCompact",
    ]
}

extension LiveSession.Badge {
    /// Higher = more attention-grabbing. The collapsed-tab badge picks the
    /// highest-priority badge among all tracked sessions.
    var priority: Int {
        switch self {
        case .needsInput:  return 4
        case .interrupted: return 3
        case .running:     return 2
        case .done:        return 1
        case .idle:        return 0
        }
    }
}

extension Array where Element == LiveSession {
    /// The badge to surface on the collapsed tab. `nil` when the list is
    /// empty (caller shows the title-only fallback).
    var dominantBadge: LiveSession.Badge? {
        guard !isEmpty else { return nil }
        return map(\.badge).max(by: { $0.priority < $1.priority })
    }
}

extension LiveSession.RecentEvent {
    /// Human-readable label for the hook event name. Used by the floating
    /// tab's hover preview to render a session's recent activity timeline
    /// without showing raw CC hook names like "PreToolUse".
    ///
    /// Tool-specific detail (which tool, which file) is intentionally NOT
    /// surfaced — `RecentEvent` only stores the event name + timestamp,
    /// not the payload. If a future change starts capturing the tool name,
    /// the `PreToolUse` branch can be enriched with it.
    var humanized: String {
        switch event {
        case "UserPromptSubmit":   return "Prompt submitted"
        case "PreToolUse":         return "Running tool"
        case "PostToolUse":        return "Tool done"
        case "PostToolUseFailure": return "Tool failed"
        case "SubagentStart":      return "Subagent started"
        case "SubagentStop":       return "Subagent done"
        case "Stop":               return "Turn finished"
        case "StopFailure":        return "Turn interrupted"
        case "PreCompact":         return "Compacting\u{2026}"
        case "PostCompact":        return "Compacted"
        case "SessionStart":       return "Session started"
        case "SessionEnd":         return "Session ended"
        default:                   return event
        }
    }
}
