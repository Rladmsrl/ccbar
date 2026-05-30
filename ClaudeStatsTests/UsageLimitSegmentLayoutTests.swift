import Testing
@testable import ClaudeStats

@Suite("Usage limit segment layout")
struct UsageLimitSegmentLayoutTests {
    @Test("Zero usage leaves all segments remaining")
    func zeroUsageLeavesAllSegmentsRemaining() {
        let layout = UsageLimitSegmentLayout(usedPercent: 0)

        #expect(layout.usedSegmentCount == 0)
        #expect(layout.remainingSegmentCount == UsageLimitSegmentLayout.defaultSegmentCount)
    }

    @Test("Tiny non-zero usage reserves one used segment")
    func tinyNonZeroUsageReservesOneUsedSegment() {
        let layout = UsageLimitSegmentLayout(usedPercent: 0.1)

        #expect(layout.usedSegmentCount == 1)
        #expect(layout.remainingSegmentCount == UsageLimitSegmentLayout.defaultSegmentCount - 1)
    }

    @Test("Full or greater usage fills all used segments")
    func fullOrGreaterUsageFillsAllUsedSegments() {
        let layout = UsageLimitSegmentLayout(usedPercent: 140)

        #expect(layout.usedSegmentCount == UsageLimitSegmentLayout.defaultSegmentCount)
        #expect(layout.remainingSegmentCount == 0)
    }

    @Test("Negative usage clamps to zero used segments")
    func negativeUsageClampsToZeroUsedSegments() {
        let layout = UsageLimitSegmentLayout(usedPercent: -25)

        #expect(layout.clampedUsedPercent == 0)
        #expect(layout.usedSegmentCount == 0)
        #expect(layout.remainingSegmentCount == UsageLimitSegmentLayout.defaultSegmentCount)
    }
}
