import CoreGraphics
import Foundation
import Testing
@testable import ClaudeStats

@Suite("FloatingPanelGeometry")
struct FloatingPanelGeometryTests {
    private let visible = CGRect(x: 100, y: 50, width: 1000, height: 700)

    @Test("Collapsed frames dock to all four edges")
    func collapsedFramesDockToEdges() {
        let right = FloatingPanelGeometry.frame(edge: .right, anchor: 0.5, in: visible, expanded: false)
        #expect(right.maxX == visible.maxX)
        #expect(right.size == FloatingPanelGeometry.collapsedVerticalSize)

        let left = FloatingPanelGeometry.frame(edge: .left, anchor: 0.5, in: visible, expanded: false)
        #expect(left.minX == visible.minX)
        #expect(left.size == FloatingPanelGeometry.collapsedVerticalSize)

        let top = FloatingPanelGeometry.frame(edge: .top, anchor: 0.5, in: visible, expanded: false)
        #expect(top.maxY == visible.maxY)
        #expect(top.size == FloatingPanelGeometry.collapsedHorizontalSize)

        let bottom = FloatingPanelGeometry.frame(edge: .bottom, anchor: 0.5, in: visible, expanded: false)
        #expect(bottom.minY == visible.minY)
        #expect(bottom.size == FloatingPanelGeometry.collapsedHorizontalSize)
    }

    @Test("Expanded frames keep the docked edge fixed")
    func expandedFramesKeepDockedEdge() {
        for edge in FloatingPanelEdge.allCases {
            let collapsed = FloatingPanelGeometry.frame(edge: edge, anchor: 0.42, in: visible, expanded: false)
            let expanded = FloatingPanelGeometry.frame(edge: edge, anchor: 0.42, in: visible, expanded: true)

            switch edge {
            case .left:
                #expect(expanded.minX == collapsed.minX)
            case .right:
                #expect(expanded.maxX == collapsed.maxX)
            case .top:
                #expect(expanded.maxY == collapsed.maxY)
            case .bottom:
                #expect(expanded.minY == collapsed.minY)
            }
        }
    }

    @Test("Anchors clamp near corners")
    func anchorsClampNearCorners() {
        let size = FloatingPanelGeometry.collapsedVerticalSize
        let low = FloatingPanelGeometry.clampedAnchor(0, edge: .right, size: size, in: visible)
        let high = FloatingPanelGeometry.clampedAnchor(1, edge: .right, size: size, in: visible)

        #expect(low > 0)
        #expect(high < 1)

        let lowFrame = FloatingPanelGeometry.frame(edge: .right, anchor: 0, in: visible, expanded: false)
        let highFrame = FloatingPanelGeometry.frame(edge: .right, anchor: 1, in: visible, expanded: false)
        #expect(lowFrame.minY >= visible.minY)
        #expect(highFrame.maxY <= visible.maxY)
    }

    @Test("Placement reclamps when visible frame shrinks")
    func reclampsWhenVisibleFrameShrinks() {
        let small = CGRect(x: 0, y: 0, width: 240, height: 160)
        let frame = FloatingPanelGeometry.frame(edge: .left, anchor: 0.96, in: small, expanded: false)
        #expect(frame.minY >= small.minY)
        #expect(frame.maxY <= small.maxY)
    }

    @Test("Nearest edge uses the shortest distance")
    func nearestEdge() {
        #expect(FloatingPanelGeometry.nearestEdge(to: CGPoint(x: 102, y: 400), in: visible) == .left)
        #expect(FloatingPanelGeometry.nearestEdge(to: CGPoint(x: 1098, y: 400), in: visible) == .right)
        #expect(FloatingPanelGeometry.nearestEdge(to: CGPoint(x: 500, y: 748), in: visible) == .top)
        #expect(FloatingPanelGeometry.nearestEdge(to: CGPoint(x: 500, y: 52), in: visible) == .bottom)
    }
}
