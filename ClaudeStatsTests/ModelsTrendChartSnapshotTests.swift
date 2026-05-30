import Foundation
import Testing
@testable import ClaudeStats

@Suite("ModelsTrendChartSnapshot")
struct ModelsTrendChartSnapshotTests {
    @Test("Precomputes day columns, axis ticks, and labels")
    func precomputesChartData() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day0 = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let day1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 2)))
        let series = TrendSeries(
            granularity: .day,
            models: ["model-a", "model-b"],
            buckets: [
                ModelBucket(
                    model: "model-a",
                    start: day0,
                    usage: TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 25)
                ),
                ModelBucket(
                    model: "model-b",
                    start: day0,
                    usage: TokenUsage(inputTokens: 40, outputTokens: 10, cacheReadTokens: 0)
                ),
                ModelBucket(
                    model: "model-a",
                    start: day1,
                    usage: TokenUsage(inputTokens: 20, outputTokens: 0, cacheReadTokens: 0)
                ),
            ]
        )

        let snapshot = ModelsTrendChartSnapshot(
            key: ModelsTrendChartSnapshot.Key(seriesID: "test", includeCacheInTotals: true),
            series: series
        )

        #expect(snapshot.days.map(\.date) == [day0, day1])
        #expect(snapshot.days[0].segments.map(\.model) == ["model-a", "model-b"])
        #expect(snapshot.days[0].segments.first?.solid == 150)
        #expect(snapshot.days[0].segments.first?.cache == 25)
        #expect(snapshot.days[0].total == 225)
        #expect(snapshot.yMax == ModelsTrendChartSnapshot.niceCeiling(225))
        #expect(snapshot.yTicks.count == ModelsTrendChartSnapshot.yTickCount + 1)
        #expect(snapshot.xLabelIndices == Set([0, 1]))
    }

    @Test("Cache reads are omitted from stacked segments when excluded from totals")
    func excludesCacheReadsWhenRequested() throws {
        let calendar = Calendar(identifier: .gregorian)
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))
        let series = TrendSeries(
            granularity: .day,
            models: ["model-a"],
            buckets: [
                ModelBucket(
                    model: "model-a",
                    start: day,
                    usage: TokenUsage(inputTokens: 100, outputTokens: 50, cacheReadTokens: 200)
                ),
            ]
        )

        let snapshot = ModelsTrendChartSnapshot(
            key: ModelsTrendChartSnapshot.Key(seriesID: "test", includeCacheInTotals: false),
            series: series
        )

        let segment = try #require(snapshot.days.first?.segments.first)
        #expect(segment.solid == 150)
        #expect(segment.cache == 0)
        #expect(snapshot.days.first?.total == 150)
    }
}
