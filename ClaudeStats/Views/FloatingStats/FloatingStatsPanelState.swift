import CoreGraphics
import Observation

@MainActor
@Observable
final class FloatingStatsPanelState {
    var edge: FloatingPanelEdge = .right
    var isExpanded = false
    var expandedContentPhase: FloatingStatsExpandedContentPhase = .hidden
    var showsCollapsedContent = true
    var isDocked = true
    var edgeReleaseProgress: CGFloat = FloatingPanelDragMotion.dockedEdgeReleaseProgress
    /// When non-nil, the cursor is over a collapsed tab segment. The
    /// expanded panel now renders a stable action list, so this is kept as
    /// an expansion trigger and reset when the panel collapses.
    var hoveredSegmentIndex: Int?
}
