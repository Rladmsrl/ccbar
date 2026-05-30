import Foundation

/// Time windows the Usage screen and menu-bar label can be scoped to.
enum StatsPeriod: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case today
    case last7Days
    case last30Days
    case allTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: L10n.string("stats.period.today", defaultValue: "Today")
        case .last7Days: L10n.string("stats.period.last_7_days", defaultValue: "Last 7 days")
        case .last30Days: L10n.string("stats.period.last_30_days", defaultValue: "Last 30 days")
        case .allTime: L10n.string("stats.period.all_time", defaultValue: "All time")
        }
    }

    /// Inclusive lower bound for "is this activity in the period?", or `nil`
    /// for ``allTime``. Uses the start of the relevant day in the current
    /// calendar.
    func lowerBound(now: Date = .now, calendar: Calendar = .current) -> Date? {
        switch self {
        case .allTime:
            return nil
        case .today:
            return calendar.startOfDay(for: now)
        case .last7Days:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .last30Days:
            return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        }
    }

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let lower = lowerBound(now: now, calendar: calendar) else { return true }
        return date >= lower
    }
}
