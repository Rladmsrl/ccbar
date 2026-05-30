import Foundation
import Testing
@testable import ClaudeStats

@Suite("Claude usage-limit loader")
struct ClaudeUsageLimitLoaderTests {
    @Test("Parses app cache and legacy Open Island cache candidates")
    func parsesCacheCandidates() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let appCache = root.appendingPathComponent("claude-rate-limits.json")
        let legacy = root.appendingPathComponent("open-island-rl.json")
        let now = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-01-10T09:05:00.000Z")
        try TempDir.write(#"{"five_hour":{"used_percentage":14,"resets_at":1768100000}}"#, to: appCache)
        try TempDir.write(#"{"seven_day":{"used_percentage":2,"resets_at":1768100000}}"#, to: legacy)
        try Self.setModified(legacy, now.addingTimeInterval(-120))
        try Self.setModified(appCache, now.addingTimeInterval(-60))

        // First URL is the primary cache (CCBar's own), so we list
        // appCache first; the legacy island file is a fallback we only use
        // when the primary is missing.
        let report = ClaudeUsageLimitLoader(
            paths: ClaudePaths(configDirectory: root),
            cacheURLs: [appCache, legacy]
        ).report(now: now)

        #expect(report.status == .fresh)
        #expect(report.snapshot?.windows.map(\.label) == ["5h"])
        #expect(report.snapshot?.windows.first?.remainingPercent == 86)
    }

    @Test("Parses full status-line envelope and utilization aliases")
    func parsesFullEnvelopeAndAliases() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("claude-rate-limits.json")
        let now = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-01-10T09:05:00.000Z")
        try TempDir.write(#"{"rate_limits":{"five_hour":{"utilization":"33","resets_at":"2026-01-10T10:00:00Z"},"seven_day":{"used_percentage":"12","resets_at":1768100000}}}"#, to: cache)
        try Self.setModified(cache, now.addingTimeInterval(-60))

        let report = ClaudeUsageLimitLoader(
            paths: ClaudePaths(configDirectory: root),
            cacheURLs: [cache]
        ).report(now: now)

        #expect(report.status == .fresh)
        let windows = try #require(report.snapshot?.windows)
        #expect(windows.count == 2)
        #expect(windows[0].usedPercent == 33)
        #expect(windows[1].usedPercent == 12)
    }

    @Test("Missing cache reports setup required")
    func missingCacheRequiresSetup() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let report = ClaudeUsageLimitLoader(
            paths: ClaudePaths(configDirectory: root),
            cacheURLs: [root.appendingPathComponent("missing.json")]
        ).report()

        #expect(report.status == .setupRequired)
        #expect(report.snapshot == nil)
    }

    @Test("Cache older than one minute waits for the next response")
    func cacheOlderThanOneMinuteWaitsForNextResponse() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("claude-rate-limits.json")
        let now = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-01-10T09:05:00.000Z")
        try TempDir.write(#"{"five_hour":{"used_percentage":14,"resets_at":1768100000}}"#, to: cache)
        try Self.setModified(cache, now.addingTimeInterval(-61))

        let report = ClaudeUsageLimitLoader(
            paths: ClaudePaths(configDirectory: root),
            cacheURLs: [cache]
        ).report(now: now)

        #expect(report.status == .waitingForNextResponse)
        #expect(report.snapshot?.windows.first?.usedPercent == 14)
    }

    private static func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
