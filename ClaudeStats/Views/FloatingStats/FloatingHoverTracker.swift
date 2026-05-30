import AppKit
import SwiftUI

struct FloatingHoverTracker: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverView {
        let view = HoverView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: HoverView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }

    @MainActor
    final class HoverView: NSView {
        var onHoverChanged: (Bool) -> Void = { _ in }

        private var trackingArea: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged(false)
        }
    }
}
