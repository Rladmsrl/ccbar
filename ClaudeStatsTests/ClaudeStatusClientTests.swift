import Foundation
import Testing
@testable import ClaudeStats

@Suite("ClaudeStatusClient")
struct ClaudeStatusClientTests {
    @Test("Decodes summary components and rollup")
    func decodesSummary() throws {
        let snapshot = try ClaudeStatusClient.decodeSummary(Self.operationalSummary, now: Date(timeIntervalSince1970: 100))

        #expect(snapshot.pageName == "Claude")
        #expect(snapshot.rollup.severity == .operational)
        #expect(snapshot.rollup.description == "All Systems Operational")
        #expect(snapshot.components.count == 2)
        #expect(snapshot.components[0].id == ClaudeStatusComponentCatalog.claudeAIID)
        #expect(snapshot.components[0].status == .operational)
        #expect(snapshot.components[1].name == "Claude Code")
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("Decodes abnormal incidents and scheduled maintenance")
    func decodesIncidentsAndMaintenance() throws {
        let snapshot = try ClaudeStatusClient.decodeSummary(Self.abnormalSummary, now: Date(timeIntervalSince1970: 200))

        #expect(snapshot.rollup.severity == .partialOutage)
        #expect(snapshot.components.first?.status == .degradedPerformance)
        #expect(snapshot.activeIncident?.name == "Elevated errors")
        #expect(snapshot.activeIncident?.impact == .partialOutage)
        #expect(snapshot.activeIncident?.shortlink?.absoluteString == "https://stspg.io/test")
        #expect(snapshot.scheduledMaintenances.first?.name == "Planned work")
        #expect(snapshot.scheduledMaintenances.first?.impact == .underMaintenance)
    }

    @Test("Unknown component status is preserved")
    func unknownStatus() throws {
        let snapshot = try ClaudeStatusClient.decodeSummary(Self.unknownSummary)

        #expect(snapshot.components.first?.status == .unknown("new_status"))
        #expect(snapshot.components.first?.status.displayName == L10n.string("status.severity.unknown", defaultValue: "Unknown"))
    }

    private static let operationalSummary = Data("""
    {
      "page": {"id": "tymt9n04zgry", "name": "Claude", "updated_at": "2026-05-16T18:24:42.297Z"},
      "components": [
        {"id": "rwppv331jlwc", "name": "claude.ai", "status": "operational", "updated_at": "2026-05-16T18:24:42.203Z", "position": 1},
        {"id": "yyzkbfz2thpt", "name": "Claude Code", "status": "operational", "updated_at": "2026-05-16T18:24:42.243Z", "position": 4}
      ],
      "incidents": [],
      "scheduled_maintenances": [],
      "status": {"indicator": "none", "description": "All Systems Operational"}
    }
    """.utf8)

    private static let abnormalSummary = Data("""
    {
      "page": {"id": "tymt9n04zgry", "name": "Claude", "updated_at": "2026-05-16T18:24:42Z"},
      "components": [
        {"id": "rwppv331jlwc", "name": "claude.ai", "status": "degraded_performance", "updated_at": "2026-05-16T18:24:42Z", "position": 1}
      ],
      "incidents": [
        {"id": "incident-1", "name": "Elevated errors", "status": "investigating", "impact": "major", "shortlink": "https://stspg.io/test", "started_at": "2026-05-16T18:00:00Z", "updated_at": "2026-05-16T18:10:00Z"}
      ],
      "scheduled_maintenances": [
        {"id": "maint-1", "name": "Planned work", "status": "scheduled", "impact": "maintenance", "shortlink": "https://stspg.io/maint", "scheduled_for": "2026-05-17T01:00:00Z", "scheduled_until": "2026-05-17T02:00:00Z", "updated_at": "2026-05-16T18:12:00Z"}
      ],
      "status": {"indicator": "major", "description": "Partial System Outage"}
    }
    """.utf8)

    private static let unknownSummary = Data("""
    {
      "page": {"id": "tymt9n04zgry", "name": "Claude", "updated_at": "2026-05-16T18:24:42Z"},
      "components": [
        {"id": "custom", "name": "Future Component", "status": "new_status", "updated_at": "2026-05-16T18:24:42Z", "position": 1}
      ],
      "incidents": [],
      "scheduled_maintenances": [],
      "status": {"indicator": "none", "description": "All Systems Operational"}
    }
    """.utf8)
}
