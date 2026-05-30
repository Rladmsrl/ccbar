import AppKit
import SwiftUI

enum FloatingDragHandleHitPolicy {
    static func isEnabled(isExpanded: Bool) -> Bool {
        !isExpanded
    }
}

struct FloatingDragHandle: NSViewRepresentable {
    var isExpanded: Bool
    var onDragBegan: (CGPoint) -> Void
    var onDragMoved: (CGPoint) -> Void
    var onDragEnded: (CGPoint) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.isExpanded = isExpanded
        nsView.onDragBegan = onDragBegan
        nsView.onDragMoved = onDragMoved
        nsView.onDragEnded = onDragEnded
    }

    @MainActor
    final class HandleView: NSView {
        var onDragBegan: (CGPoint) -> Void = { _ in }
        var onDragMoved: (CGPoint) -> Void = { _ in }
        var onDragEnded: (CGPoint) -> Void = { _ in }
        var isExpanded = false

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            FloatingDragHandleHitPolicy.isEnabled(isExpanded: isExpanded) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            onDragBegan(NSEvent.mouseLocation)
        }

        override func mouseDragged(with event: NSEvent) {
            onDragMoved(NSEvent.mouseLocation)
        }

        override func mouseUp(with event: NSEvent) {
            onDragEnded(NSEvent.mouseLocation)
        }
    }
}
