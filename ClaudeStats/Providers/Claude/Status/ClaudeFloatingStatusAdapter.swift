import Foundation

enum ClaudeFloatingStatusAdapter {
    static let targetComponentID = ClaudeStatusComponentCatalog.claudeCodeID
    static let dayCount = 30

    @MainActor
    static func summary(from status: ClaudeStatusViewModel) -> FloatingProviderStatusSummary? {
        guard let snapshot = status.snapshot else { return nil }
        return summary(
            snapshot: snapshot,
            uptimeSnapshot: status.uptimeSnapshot,
            isStale: status.isStale,
            isUptimeStale: status.isUptimeStale
        )
    }

    static func summary(
        snapshot: ClaudeStatusSnapshot,
        uptimeSnapshot: ClaudeStatusUptimeSnapshot?,
        isStale: Bool = false,
        isUptimeStale: Bool = false
    ) -> FloatingProviderStatusSummary? {
        guard let component = targetComponent(in: snapshot) else { return nil }
        let history = uptimeSnapshot?.history(for: component)

        return FloatingProviderStatusSummary(
            id: "claude:\(component.id)",
            title: component.name,
            statusText: component.status.displayName,
            severity: FloatingStatusSeverity(component.status),
            days: days(from: history),
            uptimePercent: history?.uptimePercent(recentDayCount: dayCount),
            isStale: isStale || isUptimeStale
        )
    }

    private static func targetComponent(in snapshot: ClaudeStatusSnapshot) -> ClaudeStatusComponent? {
        snapshot.components.first { $0.id == targetComponentID }
            ?? snapshot.components.first { $0.name.caseInsensitiveCompare("Claude Code") == .orderedSame }
    }

    private static func days(from history: ClaudeStatusUptimeHistory?) -> [FloatingStatusDay] {
        guard let history else { return [] }
        return history.recentDays(count: dayCount).map { day in
            FloatingStatusDay(
                date: day.date,
                state: state(for: day, startDate: history.startDate),
                helpText: helpText(for: day)
            )
        }
    }

    private static func state(for day: ClaudeStatusUptimeDay, startDate: Date?) -> FloatingStatusDay.State {
        if let startDate, day.date < startDate {
            return .noData
        }
        if day.majorOutageSeconds > 0 {
            return .majorOutage
        }
        if day.partialOutageSeconds > 0 {
            return .partialOutage
        }
        return .operational
    }

    private static func helpText(for day: ClaudeStatusUptimeDay) -> String {
        let date = Format.day(day.date)
        guard day.hasOutage else { return "\(date): no downtime recorded" }

        var parts: [String] = []
        if day.partialOutageSeconds > 0 {
            parts.append("partial outage \(Format.duration(TimeInterval(day.partialOutageSeconds)))")
        }
        if day.majorOutageSeconds > 0 {
            parts.append("major outage \(Format.duration(TimeInterval(day.majorOutageSeconds)))")
        }
        if let event = day.relatedEvents.first {
            parts.append(event.name)
        }
        return "\(date): \(parts.joined(separator: ", "))"
    }
}

private extension FloatingStatusSeverity {
    init(_ severity: ClaudeStatusSeverity) {
        switch severity {
        case .operational:
            self = .operational
        case .underMaintenance:
            self = .underMaintenance
        case .degradedPerformance:
            self = .degradedPerformance
        case .partialOutage:
            self = .partialOutage
        case .majorOutage:
            self = .majorOutage
        case .unknown:
            self = .unknown
        }
    }
}
