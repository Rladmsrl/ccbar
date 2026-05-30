import Foundation

struct ClaudeStatusUptimeSnapshot: Sendable, Codable, Equatable {
    let histories: [String: ClaudeStatusUptimeHistory]
    let fetchedAt: Date

    func history(for component: ClaudeStatusComponent) -> ClaudeStatusUptimeHistory? {
        histories[component.id]
            ?? histories.values.first { $0.componentName == component.name }
    }
}

struct ClaudeStatusUptimeHistory: Identifiable, Sendable, Codable, Equatable {
    let componentID: String
    let componentName: String
    let startDate: Date?
    let days: [ClaudeStatusUptimeDay]
    let sourceUptimePercent: Double?

    var id: String { componentID }

    func recentDays(count: Int = ClaudeStatusUptimeWindow.dayCount) -> [ClaudeStatusUptimeDay] {
        guard days.count > count else { return days }
        return Array(days.suffix(count))
    }

    func uptimePercent(recentDayCount: Int = ClaudeStatusUptimeWindow.dayCount) -> Double? {
        let window = recentDays(count: recentDayCount)
        let validDays = window.filter { day in
            guard let startDate else { return true }
            return day.date >= startDate
        }
        guard !validDays.isEmpty else { return nil }

        let totalSeconds = validDays.count * ClaudeStatusUptimeWindow.secondsPerDay
        let downtimeSeconds = validDays.reduce(0) { total, day in
            total + min(ClaudeStatusUptimeWindow.secondsPerDay, day.outageSeconds)
        }
        guard totalSeconds > 0 else { return nil }

        let uptimeRatio = 1 - (Double(downtimeSeconds) / Double(totalSeconds))
        return max(0, min(1, uptimeRatio)) * 100
    }
}

struct ClaudeStatusUptimeDay: Identifiable, Sendable, Codable, Equatable {
    let date: Date
    let partialOutageSeconds: Int
    let majorOutageSeconds: Int
    let relatedEvents: [ClaudeStatusUptimeEvent]
    let barFillHex: String?

    var id: Date { date }

    var outageSeconds: Int {
        partialOutageSeconds + majorOutageSeconds
    }

    var hasOutage: Bool {
        outageSeconds > 0
    }
}

struct ClaudeStatusUptimeEvent: Sendable, Codable, Equatable {
    let name: String
    let code: String
}

enum ClaudeStatusUptimeWindow {
    static let dayCount = 90
    static let sourceDayCount = 90
    static let secondsPerDay = 24 * 60 * 60
}

struct ClaudeStatusUptimeRow: Identifiable, Sendable, Equatable {
    let component: ClaudeStatusComponent
    let history: ClaudeStatusUptimeHistory?

    var id: String { component.id }
}
