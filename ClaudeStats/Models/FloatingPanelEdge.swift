import Foundation

/// Screen edge used by the optional floating stats tab.
enum FloatingPanelEdge: String, CaseIterable, Sendable, Identifiable {
    case left
    case right
    case top
    case bottom

    var id: String { rawValue }

    var isVertical: Bool {
        switch self {
        case .left, .right: true
        case .top, .bottom: false
        }
    }
}
