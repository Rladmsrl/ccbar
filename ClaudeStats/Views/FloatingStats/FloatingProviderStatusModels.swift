import Foundation

struct FloatingProviderStatusSummary: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let statusText: String
    let severity: FloatingStatusSeverity
    let days: [FloatingStatusDay]
    let uptimePercent: Double?
    let isStale: Bool
}

enum FloatingStatusSeverity: Sendable, Equatable {
    case operational
    case underMaintenance
    case degradedPerformance
    case partialOutage
    case majorOutage
    case unknown
}

struct FloatingStatusDay: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable {
        case operational
        case partialOutage
        case majorOutage
        case noData
    }

    let date: Date
    let state: State
    let helpText: String

    var id: Date { date }
}
