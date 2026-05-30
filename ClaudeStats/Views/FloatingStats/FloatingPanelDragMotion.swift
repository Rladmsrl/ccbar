import CoreGraphics
import Foundation

/// Pure drag math for the floating panel. AppKit screen coordinates use the
/// same bottom-left origin as global `NSWindow` frames, so y deltas are not
/// inverted.
enum FloatingPanelDragMotion {
    enum DragStep: Equatable {
        case pending
        case active(frame: CGRect, edgeReleaseProgress: CGFloat)
    }

    enum ReleasePlacement: Equatable {
        case docked(edge: FloatingPanelEdge, anchor: Double)
        case detached(frame: CGRect)
    }

    static let dockedEdgeReleaseProgress: CGFloat = 0
    static let detachedEdgeReleaseProgress: CGFloat = 1
    static let defaultActivationDistance: CGFloat = 64
    static let defaultMagneticDistance: CGFloat = 96
    static let defaultSnapDistance: CGFloat = 72

    static func delta(from startMouse: CGPoint, to currentMouse: CGPoint) -> CGSize {
        CGSize(width: currentMouse.x - startMouse.x, height: currentMouse.y - startMouse.y)
    }

    static func frame(startFrame: CGRect, startMouse: CGPoint, currentMouse: CGPoint) -> CGRect {
        let movement = delta(from: startMouse, to: currentMouse)
        return startFrame.offsetBy(dx: movement.width, dy: movement.height)
    }

    static func activatedFrame(
        startFrame: CGRect,
        startMouse: CGPoint,
        currentMouse: CGPoint,
        activationDistance: CGFloat = defaultActivationDistance
    ) -> CGRect? {
        let movement = delta(from: startMouse, to: currentMouse)
        guard movement.distance >= activationDistance else { return nil }
        return startFrame.offsetBy(dx: movement.width, dy: movement.height)
    }

    static func dragStep(
        startFrame: CGRect,
        startMouse: CGPoint,
        currentMouse: CGPoint,
        isDocked: Bool,
        activationDistance: CGFloat = defaultActivationDistance
    ) -> DragStep {
        if isDocked {
            guard let frame = activatedFrame(
                startFrame: startFrame,
                startMouse: startMouse,
                currentMouse: currentMouse,
                activationDistance: activationDistance
            ) else {
                return .pending
            }
            return .active(frame: frame, edgeReleaseProgress: detachedEdgeReleaseProgress)
        }

        return .active(
            frame: frame(startFrame: startFrame, startMouse: startMouse, currentMouse: currentMouse),
            edgeReleaseProgress: detachedEdgeReleaseProgress
        )
    }

    static func magneticFrame(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        magneticDistance: CGFloat = defaultMagneticDistance
    ) -> CGRect {
        let nearest = nearestEdgeDistance(for: frame, in: visibleFrame)
        guard nearest.distance <= magneticDistance else { return frame }

        let pull = pow(1 - nearest.distance / magneticDistance, 2)
        var nextFrame = frame
        switch nearest.edge {
        case .left:
            nextFrame.origin.x = interpolated(frame.minX, toward: visibleFrame.minX, progress: pull)
        case .right:
            nextFrame.origin.x = interpolated(frame.minX, toward: visibleFrame.maxX - frame.width, progress: pull)
        case .bottom:
            nextFrame.origin.y = interpolated(frame.minY, toward: visibleFrame.minY, progress: pull)
        case .top:
            nextFrame.origin.y = interpolated(frame.minY, toward: visibleFrame.maxY - frame.height, progress: pull)
        }
        return nextFrame
    }

    static func releasePlacement(
        for frame: CGRect,
        in visibleFrame: CGRect,
        snapDistance: CGFloat = defaultSnapDistance
    ) -> ReleasePlacement {
        let nearest = nearestEdgeDistance(for: frame, in: visibleFrame)
        guard nearest.distance <= snapDistance else {
            return .detached(frame: clampedFrame(frame, in: visibleFrame))
        }

        let size = FloatingPanelGeometry.size(edge: nearest.edge, expanded: true)
        let anchor = FloatingPanelGeometry.anchor(
            for: frame.center,
            edge: nearest.edge,
            in: visibleFrame,
            size: size
        )
        return .docked(edge: nearest.edge, anchor: anchor)
    }

    static func clampedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - frame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        let x = min(max(frame.minX, visibleFrame.minX), maxX)
        let y = min(max(frame.minY, visibleFrame.minY), maxY)
        return CGRect(origin: CGPoint(x: x, y: y), size: frame.size)
    }

    private static func nearestEdgeDistance(for frame: CGRect, in visibleFrame: CGRect) -> (edge: FloatingPanelEdge, distance: CGFloat) {
        let distances: [(FloatingPanelEdge, CGFloat)] = [
            (.left, abs(frame.minX - visibleFrame.minX)),
            (.right, abs(visibleFrame.maxX - frame.maxX)),
            (.bottom, abs(frame.minY - visibleFrame.minY)),
            (.top, abs(visibleFrame.maxY - frame.maxY)),
        ]
        return distances.min { $0.1 < $1.1 } ?? (.right, .greatestFiniteMagnitude)
    }

    private static func interpolated(_ value: CGFloat, toward target: CGFloat, progress: CGFloat) -> CGFloat {
        value + (target - value) * min(max(progress, 0), 1)
    }
}

private extension CGSize {
    var distance: CGFloat {
        hypot(width, height)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
