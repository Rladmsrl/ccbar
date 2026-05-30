import CoreGraphics
import Foundation

/// Pure geometry for the floating stats tab. Coordinates are in AppKit's
/// global screen space, using `NSScreen.visibleFrame`-style rects.
enum FloatingPanelGeometry {
    static let collapsedVerticalSize = CGSize(width: 36, height: 108)
    static let collapsedHorizontalSize = CGSize(width: 108, height: 36)
    static let expandedSize = CGSize(width: 320, height: 360)
    /// Used when the expanded content is the permission bubble. Tall enough
    /// to read a multi-line command at a glance and surface the always-allow
    /// rule choices inline, but capped so the panel doesn't dominate the
    /// screen.
    static let permissionExpandedSize = CGSize(width: 380, height: 280)

    static func size(edge: FloatingPanelEdge, expanded: Bool, compact: Bool = false) -> CGSize {
        if expanded { return compact ? permissionExpandedSize : expandedSize }
        return edge.isVertical ? collapsedVerticalSize : collapsedHorizontalSize
    }

    static func frame(edge: FloatingPanelEdge, anchor: Double, in visibleFrame: CGRect, expanded: Bool, compact: Bool = false) -> CGRect {
        let panelSize = size(edge: edge, expanded: expanded, compact: compact)
        let clamped = clampedAnchor(anchor, edge: edge, size: panelSize, in: visibleFrame)

        switch edge {
        case .left:
            return CGRect(
                x: visibleFrame.minX,
                y: axisOrigin(anchor: clamped, length: panelSize.height, rangeStart: visibleFrame.minY, rangeLength: visibleFrame.height),
                width: panelSize.width,
                height: panelSize.height
            )
        case .right:
            return CGRect(
                x: visibleFrame.maxX - panelSize.width,
                y: axisOrigin(anchor: clamped, length: panelSize.height, rangeStart: visibleFrame.minY, rangeLength: visibleFrame.height),
                width: panelSize.width,
                height: panelSize.height
            )
        case .top:
            return CGRect(
                x: axisOrigin(anchor: clamped, length: panelSize.width, rangeStart: visibleFrame.minX, rangeLength: visibleFrame.width),
                y: visibleFrame.maxY - panelSize.height,
                width: panelSize.width,
                height: panelSize.height
            )
        case .bottom:
            return CGRect(
                x: axisOrigin(anchor: clamped, length: panelSize.width, rangeStart: visibleFrame.minX, rangeLength: visibleFrame.width),
                y: visibleFrame.minY,
                width: panelSize.width,
                height: panelSize.height
            )
        }
    }

    static func clampedAnchor(_ anchor: Double, edge: FloatingPanelEdge, size: CGSize, in visibleFrame: CGRect) -> Double {
        let axisLength = edge.isVertical ? visibleFrame.height : visibleFrame.width
        let panelLength = edge.isVertical ? size.height : size.width
        guard axisLength > 0 else { return 0.5 }
        guard panelLength < axisLength else { return 0.5 }

        let half = panelLength / 2
        let minAnchor = Double(half / axisLength)
        let maxAnchor = Double((axisLength - half) / axisLength)
        return min(max(anchor, minAnchor), maxAnchor)
    }

    static func anchor(for point: CGPoint, edge: FloatingPanelEdge, in visibleFrame: CGRect, size: CGSize) -> Double {
        let raw: Double
        if edge.isVertical {
            raw = Double((point.y - visibleFrame.minY) / max(visibleFrame.height, 1))
        } else {
            raw = Double((point.x - visibleFrame.minX) / max(visibleFrame.width, 1))
        }
        return clampedAnchor(raw, edge: edge, size: size, in: visibleFrame)
    }

    static func nearestEdge(to point: CGPoint, in visibleFrame: CGRect) -> FloatingPanelEdge {
        let distances: [(FloatingPanelEdge, CGFloat)] = [
            (.left, abs(point.x - visibleFrame.minX)),
            (.right, abs(visibleFrame.maxX - point.x)),
            (.bottom, abs(point.y - visibleFrame.minY)),
            (.top, abs(visibleFrame.maxY - point.y)),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }

    private static func axisOrigin(anchor: Double, length: CGFloat, rangeStart: CGFloat, rangeLength: CGFloat) -> CGFloat {
        let center = rangeStart + CGFloat(anchor) * rangeLength
        let minimum = rangeStart
        let maximum = rangeStart + max(0, rangeLength - length)
        return min(max(center - length / 2, minimum), maximum)
    }
}
