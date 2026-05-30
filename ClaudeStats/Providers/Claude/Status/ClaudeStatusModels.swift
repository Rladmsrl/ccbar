import Foundation

enum ClaudeStatusSeverity: Sendable, Codable, Equatable, Comparable {
    case operational
    case degradedPerformance
    case partialOutage
    case majorOutage
    case underMaintenance
    case unknown(String)

    init(componentStatus rawValue: String) {
        switch rawValue {
        case "operational": self = .operational
        case "degraded_performance": self = .degradedPerformance
        case "partial_outage": self = .partialOutage
        case "major_outage": self = .majorOutage
        case "under_maintenance": self = .underMaintenance
        default: self = .unknown(rawValue)
        }
    }

    init(indicator rawValue: String) {
        switch rawValue {
        case "none": self = .operational
        case "minor": self = .degradedPerformance
        case "major": self = .partialOutage
        case "critical": self = .majorOutage
        case "maintenance": self = .underMaintenance
        default: self = .unknown(rawValue)
        }
    }

    var isOperational: Bool {
        self == .operational
    }

    var rawStatus: String {
        switch self {
        case .operational: "operational"
        case .degradedPerformance: "degraded_performance"
        case .partialOutage: "partial_outage"
        case .majorOutage: "major_outage"
        case .underMaintenance: "under_maintenance"
        case .unknown(let raw): raw
        }
    }

    var displayName: String {
        switch self {
        case .operational:
            L10n.string("status.severity.operational", defaultValue: "Operational")
        case .degradedPerformance:
            L10n.string("status.severity.degraded_performance", defaultValue: "Degraded Performance")
        case .partialOutage:
            L10n.string("status.severity.partial_outage", defaultValue: "Partial Outage")
        case .majorOutage:
            L10n.string("status.severity.major_outage", defaultValue: "Major Outage")
        case .underMaintenance:
            L10n.string("status.severity.under_maintenance", defaultValue: "Under Maintenance")
        case .unknown:
            L10n.string("status.severity.unknown", defaultValue: "Unknown")
        }
    }

    var badgeText: String {
        switch self {
        case .operational:
            L10n.string("status.badge.operational", defaultValue: "OPERATIONAL")
        case .degradedPerformance:
            L10n.string("status.badge.degraded", defaultValue: "DEGRADED")
        case .partialOutage:
            L10n.string("status.badge.partial_outage", defaultValue: "PARTIAL OUTAGE")
        case .majorOutage:
            L10n.string("status.badge.major_outage", defaultValue: "MAJOR OUTAGE")
        case .underMaintenance:
            L10n.string("status.badge.maintenance", defaultValue: "MAINTENANCE")
        case .unknown:
            L10n.string("status.badge.unknown", defaultValue: "UNKNOWN")
        }
    }

    private var rank: Int {
        switch self {
        case .operational: 0
        case .underMaintenance: 1
        case .degradedPerformance: 2
        case .partialOutage: 3
        case .majorOutage: 4
        case .unknown: 5
        }
    }

    static func < (lhs: ClaudeStatusSeverity, rhs: ClaudeStatusSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self.init(componentStatus: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawStatus)
    }
}

struct ClaudeStatusRollup: Sendable, Codable, Equatable {
    let severity: ClaudeStatusSeverity
    let description: String
}

struct ClaudeStatusComponent: Identifiable, Sendable, Codable, Equatable {
    let id: String
    let name: String
    let status: ClaudeStatusSeverity
    let updatedAt: Date?
    let position: Int

    var isOperational: Bool { status.isOperational }
}

struct ClaudeStatusIncident: Identifiable, Sendable, Codable, Equatable {
    let id: String
    let name: String
    let status: String
    let impact: ClaudeStatusSeverity
    let shortlink: URL?
    let startedAt: Date?
    let updatedAt: Date?

    var isResolved: Bool {
        status == "resolved" || status == "completed"
    }
}

struct ClaudeStatusMaintenance: Identifiable, Sendable, Codable, Equatable {
    let id: String
    let name: String
    let status: String
    let impact: ClaudeStatusSeverity
    let shortlink: URL?
    let scheduledFor: Date?
    let scheduledUntil: Date?
    let updatedAt: Date?

    var isActive: Bool {
        status == "in_progress"
    }
}

struct ClaudeStatusSnapshot: Sendable, Codable, Equatable {
    let pageName: String
    let pageUpdatedAt: Date?
    let rollup: ClaudeStatusRollup
    let components: [ClaudeStatusComponent]
    let incidents: [ClaudeStatusIncident]
    let scheduledMaintenances: [ClaudeStatusMaintenance]
    let fetchedAt: Date

    var worstVisibleSeverity: ClaudeStatusSeverity {
        components.map(\.status).max() ?? rollup.severity
    }

    var activeIncident: ClaudeStatusIncident? {
        incidents.first { !$0.isResolved }
    }
}

enum ClaudeStatusComponentCatalog {
    static let claudeAIID = "rwppv331jlwc"
    static let claudeConsoleID = "0qbwn08sd68x"
    static let claudeAPIID = "k8w3r06qmzrp"
    static let claudeCodeID = "yyzkbfz2thpt"
    static let claudeCoworkID = "bpp5gb3hpjcl"
    static let claudeGovernmentID = "0scnb50nvy53"

    static let defaultVisibleComponentIDs: Set<String> = [claudeAIID, claudeCodeID]
    static let defaultVisibleComponentNames: Set<String> = ["claude.ai", "Claude Code"]

    static let fallbackComponents: [ClaudeStatusComponent] = [
        ClaudeStatusComponent(id: claudeAIID, name: "claude.ai", status: .unknown("unknown"), updatedAt: nil, position: 1),
        ClaudeStatusComponent(id: claudeConsoleID, name: "Claude Console (platform.claude.com)", status: .unknown("unknown"), updatedAt: nil, position: 2),
        ClaudeStatusComponent(id: claudeAPIID, name: "Claude API (api.anthropic.com)", status: .unknown("unknown"), updatedAt: nil, position: 3),
        ClaudeStatusComponent(id: claudeCodeID, name: "Claude Code", status: .unknown("unknown"), updatedAt: nil, position: 4),
        ClaudeStatusComponent(id: claudeCoworkID, name: "Claude Cowork", status: .unknown("unknown"), updatedAt: nil, position: 5),
        ClaudeStatusComponent(id: claudeGovernmentID, name: "Claude for Government", status: .unknown("unknown"), updatedAt: nil, position: 6),
    ]

    static func visibleComponentIDs(from storedIDs: Set<String>, components: [ClaudeStatusComponent]) -> Set<String> {
        guard !components.isEmpty else { return storedIDs.isEmpty ? defaultVisibleComponentIDs : storedIDs }

        let ids = Set(components.map(\.id))
        var visible = storedIDs.intersection(ids)

        let fallbackByID = Dictionary(uniqueKeysWithValues: fallbackComponents.map { ($0.id, $0.name) })
        for missingID in storedIDs.subtracting(ids) {
            guard let name = fallbackByID[missingID],
                  let current = components.first(where: { $0.name == name }) else {
                continue
            }
            visible.insert(current.id)
        }

        if visible.isEmpty {
            visible = Set(components.filter { defaultVisibleComponentNames.contains($0.name) }.map(\.id))
        }
        if visible.isEmpty {
            visible = defaultVisibleComponentIDs.intersection(ids)
        }
        if visible.isEmpty, let first = components.sorted(by: { $0.position < $1.position }).first {
            visible.insert(first.id)
        }
        return visible
    }

    static func visibleComponents(from components: [ClaudeStatusComponent], storedIDs: Set<String>) -> [ClaudeStatusComponent] {
        let effectiveIDs = visibleComponentIDs(from: storedIDs, components: components)
        return components
            .filter { effectiveIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.position == rhs.position { return lhs.name < rhs.name }
                return lhs.position < rhs.position
            }
    }

    static func equivalentIDs(for component: ClaudeStatusComponent) -> Set<String> {
        let known = fallbackComponents.filter { $0.name == component.name }.map(\.id)
        return Set(known + [component.id])
    }
}
