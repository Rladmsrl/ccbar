import Foundation
import Testing
@testable import ClaudeStats

@Suite("Usage limit trend estimator")
struct UsageLimitTrendStoreTests {
    @Test("Returns nil under sample-count threshold")
    func belowSampleThreshold() {
        let now = Date()
        let samples = [
            sample(secondsAgo: 700, percent: 40, now: now),
            sample(secondsAgo: 300, percent: 45, now: now),
        ]
        let estimate = UsageLimitTrendStore.estimate(
            from: samples,
            currentPercent: 45,
            windowID: "five_hour",
            now: now
        )
        #expect(estimate == nil)
    }

    @Test("Returns nil under time-span threshold (<5 min)")
    func belowSpanThreshold() {
        let now = Date()
        // 3 个样本只跨 200s, 小于 300s 门控
        let samples = [
            sample(secondsAgo: 250, percent: 40, now: now),
            sample(secondsAgo: 150, percent: 43, now: now),
            sample(secondsAgo: 50, percent: 46, now: now),
        ]
        let estimate = UsageLimitTrendStore.estimate(
            from: samples,
            currentPercent: 46,
            windowID: "five_hour",
            now: now
        )
        #expect(estimate == nil)
    }

    @Test("Returns estimate in the 5-10 min window (post 2026-05-27 收紧前不会出)")
    func estimateInFiveToTenMinuteWindow() {
        let now = Date()
        // 3 个样本跨 400s (≈ 6.7 min), 涨 6pp — 满足新的 ≥5 min 门控,
        // 但跨度小于旧的 ≥10 min 门控, 用来锁住"加速预测"的行为变化。
        let samples = [
            sample(secondsAgo: 420, percent: 40, now: now),
            sample(secondsAgo: 210, percent: 43, now: now),
            sample(secondsAgo: 20, percent: 46, now: now),
        ]
        let estimate = UsageLimitTrendStore.estimate(
            from: samples,
            currentPercent: 46,
            windowID: "five_hour",
            now: now
        )
        #expect(estimate != nil)
    }

    @Test("Returns nil under rise threshold (<2 pct)")
    func belowRiseThreshold() {
        let now = Date()
        let samples = [
            sample(secondsAgo: 1200, percent: 40, now: now),
            sample(secondsAgo: 800, percent: 40.5, now: now),
            sample(secondsAgo: 400, percent: 41, now: now),
            sample(secondsAgo: 100, percent: 41.5, now: now),
        ]
        let estimate = UsageLimitTrendStore.estimate(
            from: samples,
            currentPercent: 41.5,
            windowID: "five_hour",
            now: now
        )
        #expect(estimate == nil)
    }

    @Test("Returns estimate when thresholds satisfied")
    func steadyBurnEstimate() {
        let now = Date()
        // 4 samples across 20 minutes, 8 percentage-point rise. Slope ≈ 0.4 %/min,
        // current=48, so remaining=52 → ~130 minutes.
        let samples = [
            sample(secondsAgo: 1200, percent: 40, now: now),
            sample(secondsAgo: 800, percent: 43, now: now),
            sample(secondsAgo: 400, percent: 45, now: now),
            sample(secondsAgo: 0, percent: 48, now: now),
        ]
        let estimate = UsageLimitTrendStore.estimate(
            from: samples,
            currentPercent: 48,
            windowID: "five_hour",
            now: now
        )
        #expect(estimate != nil)
        if let estimate {
            #expect(estimate.sampleCount == 4)
            #expect(estimate.slopePercentPerMinute > 0)
            // Allow some tolerance — least-squares slope from these 4 points is
            // roughly 0.385 %/min, so (100-48)/0.385 ≈ 135 minutes.
            #expect(estimate.minutesUntilExhaust >= 110 && estimate.minutesUntilExhaust <= 160)
        }
    }

    @Test("Records and reads back samples through the actor")
    func recordRoundtrip() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = UsageLimitTrendStore(
            storageURL: tempDir.appendingPathComponent("history.json", isDirectory: false)
        )
        let now = Date()
        let resetAt = now.addingTimeInterval(7200)
        for offset in stride(from: 1200, through: 0, by: -300) {
            let snapshot = snapshotWith(
                usedPercent: 40 + Double((1200 - offset) / 100),
                at: now.addingTimeInterval(-Double(offset)),
                resetAt: resetAt
            )
            await store.record(snapshot: snapshot, at: now.addingTimeInterval(-Double(offset)))
        }
        let window = UsageLimitWindow(
            id: "five_hour",
            label: "5h",
            usedPercent: 52,
            resetAt: resetAt,
            windowMinutes: 300
        )
        let estimate = await store.estimate(provider: .claude, window: window, now: now)
        #expect(estimate != nil)
    }

    @Test("Window reset (used_percent 下降) 清空旧样本")
    func resetClearsSamples() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = UsageLimitTrendStore(
            storageURL: tempDir.appendingPathComponent("history.json", isDirectory: false)
        )
        let now = Date()
        // 攒 3 个递增样本: 40 → 45 → 50%。这里模拟没有 resetAt 的
        // community cache, 仍然用百分比下降作为 reset fallback。
        for (offset, percent) in [(600.0, 40.0), (300.0, 45.0), (0.0, 50.0)] {
            let snapshot = snapshotWith(usedPercent: percent, at: now.addingTimeInterval(-offset), resetAt: nil)
            await store.record(snapshot: snapshot, at: now.addingTimeInterval(-offset))
        }
        let preReset = UsageLimitWindow(
            id: "five_hour", label: "5h", usedPercent: 50,
            resetAt: nil, windowMinutes: 300
        )
        #expect(await store.estimate(provider: .claude, window: preReset, now: now) != nil)

        // 窗口 reset, percent 砸回 5% (任意小于上一个的值即可)
        let afterReset = now.addingTimeInterval(60)
        let resetSnapshot = snapshotWith(usedPercent: 5, at: afterReset, resetAt: nil)
        await store.record(snapshot: resetSnapshot, at: afterReset)

        // reset 后的瞬间, 样本被清空 + 唯一一个新样本 = 5%。estimate 应该返 nil
        // (3 个 count 不够 / span 不够 / rise 不够都行, 这里 count 不够最直接)。
        let postReset = UsageLimitWindow(
            id: "five_hour", label: "5h", usedPercent: 5,
            resetAt: nil, windowMinutes: 300
        )
        let estimate = await store.estimate(provider: .claude, window: postReset, now: afterReset)
        #expect(estimate == nil)
    }

    @Test("resetAt change starts a new trend history even when percent does not drop")
    func resetAtChangeStartsNewHistory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = UsageLimitTrendStore(
            storageURL: tempDir.appendingPathComponent("history.json", isDirectory: false)
        )
        let now = Date()
        let oldResetAt = now.addingTimeInterval(3600)
        let newResetAt = now.addingTimeInterval(6 * 3600)
        for (offset, percent) in [(600.0, 40.0), (300.0, 45.0), (0.0, 50.0)] {
            let timestamp = now.addingTimeInterval(-offset)
            await store.record(
                snapshot: snapshotWith(usedPercent: percent, at: timestamp, resetAt: oldResetAt),
                at: timestamp
            )
        }

        let preReset = UsageLimitWindow(
            id: "five_hour", label: "5h", usedPercent: 50,
            resetAt: oldResetAt, windowMinutes: 300
        )
        #expect(await store.estimate(provider: .claude, window: preReset, now: now) != nil)

        let afterReset = now.addingTimeInterval(60)
        await store.record(
            snapshot: snapshotWith(usedPercent: 51, at: afterReset, resetAt: newResetAt),
            at: afterReset
        )

        let postReset = UsageLimitWindow(
            id: "five_hour", label: "5h", usedPercent: 51,
            resetAt: newResetAt, windowMinutes: 300
        )
        #expect(await store.estimate(provider: .claude, window: postReset, now: afterReset) == nil)
    }

    // MARK: - Helpers

    private func sample(secondsAgo: TimeInterval, percent: Double, now: Date) -> UsageLimitTrendStore.Sample {
        UsageLimitTrendStore.Sample(
            timestamp: now.addingTimeInterval(-secondsAgo),
            usedPercent: percent
        )
    }

    private func snapshotWith(usedPercent: Double, at capturedAt: Date, resetAt: Date? = nil) -> UsageLimitSnapshot {
        UsageLimitSnapshot(
            provider: .claude,
            windows: [
                UsageLimitWindow(
                    id: "five_hour",
                    label: "5h",
                    usedPercent: usedPercent,
                    resetAt: resetAt,
                    windowMinutes: 300
                ),
            ],
            capturedAt: capturedAt,
            sourceLabel: "test",
            sourcePath: nil,
            planType: nil,
            limitID: nil
        )
    }
}
