import Foundation

enum FloatingSessionAttention: Int, Sendable, Hashable, Comparable {
    case idle = 0
    case running = 1
    case doneUnread = 2
    case warning = 3
    case error = 4
    case needsAnswer = 5

    static func < (lhs: FloatingSessionAttention, rhs: FloatingSessionAttention) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct FloatingSessionActionRowModel: Identifiable, Sendable, Hashable {
    let id: String
    let session: LiveSession
    let attention: FloatingSessionAttention
    let reason: String
    let action: String
    let canFocus: Bool

    var subtitle: String {
        guard !action.isEmpty else { return reason }
        return "\(reason) · \(action)"
    }
}

struct FloatingBackgroundSummaryModel: Sendable, Hashable {
    let hiddenCount: Int
    let runningCount: Int
}

struct FloatingSessionActionListModel: Sendable, Hashable {
    let rows: [FloatingSessionActionRowModel]
    let segmentSessions: [LiveSession]
    let backgroundSummary: FloatingBackgroundSummaryModel?
}

enum FloatingSessionActionPresenter {
    static func makeModel(
        sessions: [LiveSession],
        unreadDoneSessions: Set<String>,
        now: Date = .now
    ) -> FloatingSessionActionListModel {
        let indexedRows = sessions.enumerated().compactMap { offset, session -> (Int, FloatingSessionActionRowModel)? in
            let attention = attention(for: session, unreadDoneSessions: unreadDoneSessions)
            guard shouldInclude(session: session, attention: attention) else { return nil }
            return (
                offset,
                FloatingSessionActionRowModel(
                    id: session.id,
                    session: session,
                    attention: attention,
                    reason: reason(for: attention),
                    action: action(for: session, attention: attention, now: now),
                    canFocus: canFocus(session)
                )
            )
        }

        let rows = indexedRows
            .sorted { lhs, rhs in
                if lhs.1.attention != rhs.1.attention {
                    return lhs.1.attention > rhs.1.attention
                }
                return lhs.0 < rhs.0
            }
            .map(\.1)
        let segmentSessions = indexedRows
            .sorted { lhs, rhs in lhs.0 < rhs.0 }
            .map(\.1.session)

        let visibleIds = Set(rows.map(\.session.id))
        let hiddenBackground = sessions.filter { session in
            session.kind == .background && !visibleIds.contains(session.id)
        }
        let summary: FloatingBackgroundSummaryModel? = hiddenBackground.isEmpty
            ? nil
            : FloatingBackgroundSummaryModel(
                hiddenCount: hiddenBackground.count,
                runningCount: hiddenBackground.filter { $0.state == .working }.count
            )

        return FloatingSessionActionListModel(
            rows: rows,
            segmentSessions: segmentSessions,
            backgroundSummary: summary
        )
    }

    private static func shouldInclude(
        session: LiveSession,
        attention: FloatingSessionAttention
    ) -> Bool {
        switch session.kind {
        case .foreground:
            return true
        case .headless:
            return canFocus(session) || attention.isActionable
        case .background:
            return attention.isActionable
        }
    }

    private static func attention(
        for session: LiveSession,
        unreadDoneSessions: Set<String>
    ) -> FloatingSessionAttention {
        if session.needsInput { return .needsAnswer }

        switch session.displayState {
        case .error:
            return .error
        case .sweeping:
            return .warning
        case .attention:
            return unreadDoneSessions.contains(session.id) ? .doneUnread : .idle
        case .thinking, .working, .juggling:
            return .running
        case .idle, .sleeping:
            return .idle
        }
    }

    private static func reason(for attention: FloatingSessionAttention) -> String {
        switch attention {
        case .needsAnswer: return "Needs answer"
        case .error: return "Error"
        case .warning: return "Warning"
        case .doneUnread: return "Done"
        case .running: return "Running"
        case .idle: return "Idle"
        }
    }

    private static func action(
        for session: LiveSession,
        attention: FloatingSessionAttention,
        now: Date
    ) -> String {
        if attention == .needsAnswer, session.needsInput {
            return "permission request"
        }
        if let recent = session.recentEvents.last {
            return recent.humanized
        }
        if let lastEvent = session.lastEvent {
            return LiveSession.RecentEvent(event: lastEvent, at: session.updatedAt).humanized
        }
        switch attention {
        case .running:
            return "working"
        case .idle:
            return "last active \(Format.relativeDate(session.updatedAt, now: now))"
        case .needsAnswer:
            return "needs input"
        case .error:
            return "needs review"
        case .warning:
            return "needs review"
        case .doneUnread:
            return "review output"
        }
    }

    private static func canFocus(_ session: LiveSession) -> Bool {
        session.sourcePid != nil && session.kind != .background
    }
}

extension FloatingSessionAttention {
    var isActionable: Bool {
        switch self {
        case .needsAnswer, .error, .warning, .doneUnread:
            return true
        case .running, .idle:
            return false
        }
    }
}
