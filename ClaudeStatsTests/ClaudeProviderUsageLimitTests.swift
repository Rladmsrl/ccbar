import Foundation
import Testing
@testable import ClaudeStats

@Suite("Claude provider usage limits")
struct ClaudeProviderUsageLimitTests {
    @Test("Fresh cache wins even when Claude CLI is missing")
    func freshCacheWinsWhenCLIMissing() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("claude-rate-limits.json")
        let now = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-05-20T08:00:00.000Z")
        try TempDir.write(#"{"five_hour":{"used_percentage":14,"resets_at":"2026-05-20T10:00:00Z"}}"#, to: cache)
        try setModified(cache, now.addingTimeInterval(-60))

        let provider = ClaudeProvider(
            paths: ClaudePaths(configDirectory: root),
            pricing: TestPricing.table,
            cliInstallDetector: FakeClaudeCLIInstallDetector(installed: false),
            usageLimitCacheURLs: [cache]
        )

        let report = await provider.usageLimitReport(now: now)

        #expect(report.status == .fresh)
        #expect(report.snapshot?.windows.first?.usedPercent == 14)
    }

    @Test("Missing cache keeps current setup guidance when Claude CLI is installed")
    func missingCacheKeepsBridgeGuidanceWhenCLIInstalled() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("missing.json")
        let provider = ClaudeProvider(
            paths: ClaudePaths(configDirectory: root),
            pricing: TestPricing.table,
            cliInstallDetector: FakeClaudeCLIInstallDetector(installed: true),
            usageLimitCacheURLs: [cache]
        )

        let report = await provider.usageLimitReport(now: .now)

        #expect(report.status == .setupRequired)
        #expect(report.message?.contains("status line") == true)
        #expect(report.message?.contains("Install Claude Code") == false)
    }

    @Test("Missing cache asks to install Claude CLI when CLI is missing")
    func missingCacheAsksToInstallCLIWhenMissing() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("missing.json")
        let provider = ClaudeProvider(
            paths: ClaudePaths(configDirectory: root),
            pricing: TestPricing.table,
            cliInstallDetector: FakeClaudeCLIInstallDetector(installed: false),
            usageLimitCacheURLs: [cache]
        )

        let report = await provider.usageLimitReport(now: .now)

        #expect(report.status == .setupRequired)
        #expect(report.message?.contains("Install Claude Code") == true)
    }

    @Test("Stale cache asks to install Claude CLI when CLI is missing")
    func staleCacheAsksToInstallCLIWhenMissing() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("claude-rate-limits.json")
        let now = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-05-20T08:00:00.000Z")
        try TempDir.write(#"{"five_hour":{"used_percentage":14,"resets_at":"2026-05-20T10:00:00Z"}}"#, to: cache)
        try setModified(cache, now.addingTimeInterval(-ClaudeUsageLimitLoader.snapshotTTL - 60))
        let provider = ClaudeProvider(
            paths: ClaudePaths(configDirectory: root),
            pricing: TestPricing.table,
            cliInstallDetector: FakeClaudeCLIInstallDetector(installed: false),
            usageLimitCacheURLs: [cache]
        )

        let report = await provider.usageLimitReport(now: now)

        #expect(report.status == .setupRequired)
        #expect(report.message?.contains("Install Claude Code") == true)
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

private struct FakeClaudeCLIInstallDetector: ClaudeCLIInstallDetecting {
    let installed: Bool

    func isClaudeCLIInstalled() async -> Bool {
        installed
    }
}
