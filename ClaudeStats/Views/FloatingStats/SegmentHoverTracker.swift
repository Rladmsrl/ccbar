import AppKit
import SwiftUI

enum SegmentHoverTrackerGeometry {
    static func index(
        at point: CGPoint,
        in size: CGSize,
        segmentCount: Int,
        edge: FloatingPanelEdge
    ) -> Int? {
        guard segmentCount > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.contains(point) else { return nil }

        let rects = TabSegmenter.rects(in: size, count: segmentCount, edge: edge)
        return rects.firstIndex { $0.contains(point) }
    }
}

enum SegmentHoverTrackerHitPolicy {
    static let acceptsMouseHits = false
}

/// Transparent SwiftUI overlay that turns mouse position into a segment
/// index. Used by the floating tab to drive `hoveredSegmentIndex` while
/// collapsed; the expanded panel renders a stable action list.
///
/// Two modes:
/// - Collapsed (`isExpanded == false`): N segment-shaped `Color.clear`
///   rects, each with `.onHover` reporting that segment's index when
///   entered and `nil` when exited.
/// - Expanded (`isExpanded == true`): a single full-panel rect that only
///   fires `onSegmentHover(nil)` when the cursor leaves the panel entirely.
///   Inner-panel movement does not change `hoveredSegmentIndex`.
///
/// See spec 2026-05-28-floating-tab-hover-preview-design §1, §6.
struct SegmentHoverTracker: View {
    let segments: [TabSegment]
    let edge: FloatingPanelEdge
    let isExpanded: Bool
    var onSegmentHover: (Int?) -> Void

    var body: some View {
        SegmentHoverTrackingView(
            segmentCount: segments.count,
            edge: edge,
            isExpanded: isExpanded,
            onSegmentHover: onSegmentHover
        )
    }
}

private struct SegmentHoverTrackingView: NSViewRepresentable {
    let segmentCount: Int
    let edge: FloatingPanelEdge
    let isExpanded: Bool
    var onSegmentHover: (Int?) -> Void

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: HoverView, context: Context) {
        nsView.segmentCount = segmentCount
        nsView.edge = edge
        nsView.isExpanded = isExpanded
        nsView.onSegmentHover = onSegmentHover
    }

    @MainActor
    final class HoverView: NSView {
        var segmentCount = 0
        var edge: FloatingPanelEdge = .right
        var isExpanded = false
        var onSegmentHover: (Int?) -> Void = { _ in }

        private var trackingArea: NSTrackingArea?
        private var lastIndex: Int?

        override func hitTest(_ point: NSPoint) -> NSView? {
            SegmentHoverTrackerHitPolicy.acceptsMouseHits ? self : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            updateSegment(for: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateSegment(for: event)
        }

        override func mouseExited(with event: NSEvent) {
            lastIndex = nil
            onSegmentHover(nil)
        }

        private func updateSegment(for event: NSEvent) {
            guard !isExpanded else { return }
            let point = convert(event.locationInWindow, from: nil)
            let index = SegmentHoverTrackerGeometry.index(
                at: point,
                in: bounds.size,
                segmentCount: segmentCount,
                edge: edge
            )
            guard index != lastIndex else { return }
            lastIndex = index
            onSegmentHover(index)
        }
    }
}
