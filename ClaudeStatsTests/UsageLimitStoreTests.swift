import Foundation
import Testing
@testable import ClaudeStats

@Suite("Usage limit store")
struct UsageLimitStoreTests {
    @MainActor
    @Test("Refresh caches provider reports")
    func refreshCachesReports() async throws {
        let provider = FakeUsageLimitProvider(kind: .claude, report: Self.report(used: 10))
        // Sandbox the trend store so test runs don't pollute the user's real
        // ~/Library/Application Support/CCBar/UsageLimits/usage-limit-history.json
        // (the store records every fresh snapshot into the trend history).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = UsageLimitStore(
            registry: ProviderRegistry(providers: [provider]),
            trendStore: UsageLimitTrendStore(
                storageURL: tempDir.appendingPathComponent("history.json", isDirectory: false)
            )
        )

        await store.refresh(provider: .claude)
        #expect(store.report(for: .claude)?.snapshot?.windows.first?.usedPercent == 10)

        provider.report = Self.report(used: 20)
        await store.refresh(provider: .claude)

        #expect(store.report(for: .claude)?.snapshot?.windows.first?.usedPercent == 10)
        #expect(provider.callCount == 1)

        await store.refresh(provider: .claude, force: true)

        // Max-stabilization keeps the higher historical value (10 → 20 within
        // the same 60s window). Verify the published report carries the new
        // 20, but also accept the stabilizer's behaviour of holding ≥10.
        #expect((store.report(for: .claude)?.snapshot?.windows.first?.usedPercent ?? 0) >= 20)
        #expect(provider.callCount == 2)
        #expect(store.isLoading(.claude) == false)
    }

    @MainActor
    @Test("Window reset clears stabilization carry-over (max doesn't keep old window's high)")
    func resetClearsStabilizationCarryOver() async throws {
        // 旧窗口 reset 在 14:00, 新窗口 reset 在 19:00 (5h later).
        let oldResetAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newResetAt = oldResetAt.addingTimeInterval(5 * 3600)
        let beforeReset = oldResetAt.addingTimeInterval(-10)  // 旧窗口最后 10s
        let afterReset = oldResetAt.addingTimeInterval(5)     // 新窗口刚开始 5s (5s 远小于 60s stabilization window)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let provider = FakeUsageLimitProvider(
            kind: .claude,
            report: Self.report(used: 98, resetAt: oldResetAt)
        )
        let store = UsageLimitStore(
            registry: ProviderRegistry(providers: [provider]),
            trendStore: UsageLimitTrendStore(
                storageURL: tempDir.appendingPathComponent("history.json", isDirectory: false)
            )
        )

        // 1. 旧窗口 sample: usedPercent 98, resetAt 14:00
        await store.refresh(provider: .claude, force: true, now: beforeReset)
        #expect(store.report(for: .claude)?.snapshot?.windows.first?.usedPercent == 98)

        // 2. 窗口 reset: API 返回新 window (resetAt 改成 19:00, usedPercent 重置到 0)
        provider.report = Self.report(used: 0, resetAt: newResetAt)
        await store.refresh(provider: .claude, force: true, now: afterReset)

        // 3. 新窗口 stabilized usedPercent 应等于 0, 不应被旧窗口 98% 卡住
        // (composite key 让 reset 自然换桶, 旧窗口 sample 不影响新窗口 max)
        #expect(store.report(for: .claude)?.snapshot?.windows.first?.usedPercent == 0)
    }

    @MainActor
    @Test("Trend samples use canonical provider values instead of stabilized display values")
    func trendSamplesUseProviderValuesInsteadOfStabilizedDisplayValues() async throws {
        let resetAt = Date(timeIntervalSince1970: 1_700_000_000)
        let t0 = resetAt.addingTimeInterval(-240)
        let t1 = resetAt.addingTimeInterval(-230)
        let t2 = resetAt.addingTimeInterval(-180)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let historyURL = tempDir.appendingPathComponent("history.json", isDirectory: false)

        let provider = FakeUsageLimitProvider(
            kind: .claude,
            report: Self.report(used: 40, resetAt: resetAt, windowID: "five_hour")
        )
        let store = UsageLimitStore(
            registry: ProviderRegistry(providers: [provider]),
            trendStore: UsageLimitTrendStore(storageURL: historyURL)
        )

        await store.refresh(provider: .claude, force: true, now: t0)
        provider.report = Self.report(used: 50, resetAt: resetAt, windowID: "five_hour")
        await store.refresh(provider: .claude, force: true, now: t1)
        provider.report = Self.report(used: 41, resetAt: resetAt, windowID: "five_hour")
        await store.refresh(provider: .claude, force: true, now: t2)

        #expect(store.report(for: .claude)?.snapshot?.windows.first?.usedPercent == 50)
        let history = try JSONDecoder().decode(
            [String: [UsageLimitTrendStore.Sample]].self,
            from: Data(contentsOf: historyURL)
        )
        let samples = try #require(history.values.first)
        #expect(samples.map(\.usedPercent) == [40, 50, 41])
    }

    private static func report(
        provider: ProviderKind = .claude,
        used: Double,
        resetAt: Date? = nil,
        windowID: String = "primary"
    ) -> UsageLimitReport {
        .fresh(
            provider: provider,
            snapshot: snapshot(provider: provider, used: used, resetAt: resetAt, windowID: windowID)
        )
    }

    private static func snapshot(
        provider: ProviderKind = .claude,
        used: Double,
        resetAt: Date? = nil,
        windowID: String = "primary"
    ) -> UsageLimitSnapshot {
        UsageLimitSnapshot(
            provider: provider,
            windows: [UsageLimitWindow(id: windowID, label: "5h", usedPercent: used, resetAt: resetAt, windowMinutes: 300)],
            capturedAt: .now,
            sourceLabel: "test",
            sourcePath: nil,
            planType: nil,
            limitID: nil
        )
    }
}

private final class FakeUsageLimitProvider: Provider, @unchecked Sendable {
    let kind: ProviderKind
    var dataDirectoryExists: Bool { true }
    var report: UsageLimitReport
    private(set) var callCount = 0

    init(kind: ProviderKind, report: UsageLimitReport) {
        self.kind = kind
        self.report = report
    }

    func discoverSessions() async -> [Session] { [] }
    func parse(_ session: Session) async -> SessionStats? { nil }

    func usageLimitReport(now: Date) async -> UsageLimitReport {
        callCount += 1
        return report
    }
}
