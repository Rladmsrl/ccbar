import CoreGraphics
import Testing
@testable import ClaudeStats

@Suite("FloatingStats hover interactions")
struct FloatingStatsHoverInteractionTests {
    @Test("Panel hover opens the current-session action list")
    func panelHoverOpensActionList() {
        #expect(FloatingStatsPanelHoverExpansionPolicy.shouldExpandOnPanelHover(
            hasHoveredSegment: false,
            hasPendingPermission: false
        ))
    }

    @Test("Segment hover and pending permission can expand the panel")
    func concreteHoverReasonsExpandPanel() {
        #expect(FloatingStatsPanelHoverExpansionPolicy.shouldExpandOnPanelHover(
            hasHoveredSegment: true,
            hasPendingPermission: false
        ))
        #expect(FloatingStatsPanelHoverExpansionPolicy.shouldExpandOnPanelHover(
            hasHoveredSegment: false,
            hasPendingPermission: true
        ))
    }

    @Test("Segment tracker maps collapsed tab points to segment indexes")
    func segmentTrackerMapsPointsToIndexes() {
        let size = CGSize(width: 36, height: 108)

        #expect(SegmentHoverTrackerGeometry.index(
            at: CGPoint(x: 18, y: 10),
            in: size,
            segmentCount: 3,
            edge: .right
        ) == 0)
        #expect(SegmentHoverTrackerGeometry.index(
            at: CGPoint(x: 18, y: 50),
            in: size,
            segmentCount: 3,
            edge: .right
        ) == 1)
        #expect(SegmentHoverTrackerGeometry.index(
            at: CGPoint(x: 18, y: 100),
            in: size,
            segmentCount: 3,
            edge: .right
        ) == 2)
        #expect(SegmentHoverTrackerGeometry.index(
            at: CGPoint(x: -1, y: 50),
            in: size,
            segmentCount: 3,
            edge: .right
        ) == nil)
    }

    @Test("Hover trackers pass mouse clicks through to real controls")
    func hoverTrackerDoesNotOwnMouseClicks() {
        #expect(SegmentHoverTrackerHitPolicy.acceptsMouseHits == false)
    }

    @Test("Drag handle only owns clicks while the tab is collapsed")
    func dragHandleDoesNotCoverExpandedContent() {
        #expect(FloatingDragHandleHitPolicy.isEnabled(isExpanded: false))
        #expect(FloatingDragHandleHitPolicy.isEnabled(isExpanded: true) == false)
    }
}
