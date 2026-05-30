import CoreGraphics
import Testing
@testable import ClaudeStats

@Suite("Hoverable split view")
struct HoverableSplitViewTests {
    @Test("Default range uses 120 point pane minimums")
    func defaultRangeUsesMinimumPaneLength() throws {
        let range = try #require(HoverableSplitViewConfiguration.default.dividerPositionRange(for: 500))

        #expect(range.lowerBound == 120)
        #expect(range.upperBound == 380)
    }

    @Test("Explicit pane minimums constrain normal space")
    func explicitMinimumsConstrainNormalSpace() throws {
        let configuration = HoverableSplitViewConfiguration(
            primaryMinimumPaneLength: 220,
            secondaryMinimumPaneLength: 320
        )

        let range = try #require(configuration.dividerPositionRange(for: 800))

        #expect(range.lowerBound == 220)
        #expect(range.upperBound == 480)
    }

    @Test("Oversized pane minimums scale into available length")
    func oversizedMinimumsScaleIntoAvailableLength() throws {
        let configuration = HoverableSplitViewConfiguration(
            primaryMinimumPaneLength: 420,
            secondaryMinimumPaneLength: 360
        )

        let range = try #require(configuration.dividerPositionRange(for: 500))

        #expect(approximatelyEqual(range.lowerBound, 269.230_769))
        #expect(approximatelyEqual(range.upperBound, 269.230_769))
        #expect(range.lowerBound >= 0)
        #expect(range.upperBound <= 500)
    }

    @Test("Extremely narrow containers still return an in-bounds divider")
    func extremelyNarrowContainersStayInBounds() throws {
        let configuration = HoverableSplitViewConfiguration(
            primaryMinimumPaneLength: 420,
            secondaryMinimumPaneLength: 360
        )

        let range = try #require(configuration.dividerPositionRange(for: 1))

        #expect(range.lowerBound >= 0)
        #expect(range.upperBound <= 1)
        #expect(approximatelyEqual(range.lowerBound, range.upperBound))
    }

    @Test("Configurations compare by effective values")
    func configurationsCompareByEffectiveValues() {
        let first = HoverableSplitViewConfiguration(
            primaryMinimumPaneLength: 220,
            secondaryMinimumPaneLength: 320,
            dragUpdateInterval: 1.0 / 120.0
        )
        let matching = HoverableSplitViewConfiguration(
            primaryMinimumPaneLength: 220,
            secondaryMinimumPaneLength: 320,
            dragUpdateInterval: 1.0 / 120.0
        )
        let changed = HoverableSplitViewConfiguration(
            primaryMinimumPaneLength: 221,
            secondaryMinimumPaneLength: 320,
            dragUpdateInterval: 1.0 / 120.0
        )

        #expect(first == matching)
        #expect(first != changed)
    }

    @Test("Maximum pane lengths constrain divider range")
    func maximumPaneLengthsConstrainDividerRange() throws {
        let configuration = HoverableSplitViewConfiguration(
            primaryMinimumPaneLength: 120,
            primaryMaximumPaneLength: 260,
            secondaryMinimumPaneLength: 120,
            secondaryMaximumPaneLength: 300
        )

        let range = try #require(configuration.dividerPositionRange(for: 800))

        #expect(approximatelyEqual(range.lowerBound, 380))
        #expect(approximatelyEqual(range.lowerBound, range.upperBound))
    }

    private func approximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
