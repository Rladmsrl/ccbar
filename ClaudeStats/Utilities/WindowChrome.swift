import AppKit
import SwiftUI

/// Utilities for tweaking the host `NSWindow`'s chrome from SwiftUI — currently
/// just the traffic-light button positions. Re-applies on resize / fullscreen
/// transitions because AppKit re-lays out the buttons during those events.

extension NSWindow {
    /// Move the close/miniaturize/zoom buttons so each button's top edge sits
    /// `top` away from the window's top, and the leftmost button's left edge
    /// sits `leading` away from the window's left.
    fileprivate func positionTrafficLights(topInset: CGFloat, leadingInset: CGFloat) {
        let buttons = [
            standardWindowButton(.closeButton),
            standardWindowButton(.miniaturizeButton),
            standardWindowButton(.zoomButton)
        ].compactMap { $0 }
        guard let parent = buttons.first?.superview else { return }

        // Standard center-to-center spacing between traffic lights is 20pt.
        let spacing: CGFloat = 20
        let parentHeight = parent.bounds.height
        let isFlipped = parent.isFlipped

        for (i, btn) in buttons.enumerated() {
            // Each button can have a slightly different frame height (the
            // green/zoom button in particular), so compute y from each button's
            // own size to keep their tops aligned. NSThemeFrame is not flipped
            // on current macOS, but branch defensively in case Apple changes
            // the internal hierarchy.
            let y = isFlipped ? topInset : parentHeight - btn.frame.height - topInset
            let target = NSPoint(x: leadingInset + CGFloat(i) * spacing, y: y)
            // Skip when already correct — avoids the synthetic frameDidChange
            // notification our own write would otherwise post.
            if abs(btn.frame.origin.x - target.x) < 0.5,
               abs(btn.frame.origin.y - target.y) < 0.5 {
                continue
            }
            btn.setFrameOrigin(target)
        }
    }
}

/// Owns the notification observers that keep the traffic lights pinned to the
/// requested inset, even after AppKit re-lays them out on resize / fullscreen.
///
/// The flicker fix has two halves:
///
/// 1. Observers are registered with `queue: nil` so the block runs
///    synchronously on the posting thread inside `NotificationCenter.post(...)`.
///    `queue: .main` would enqueue on the main `OperationQueue` and run on a
///    later runloop tick — by then AppKit has already finalized the default
///    button positions and a display pass may have rendered them, leaving the
///    (slightly taller) green button visibly higher than the others until the
///    next event (e.g. hover) jostles things.
/// 2. We listen to both view-level frame/bounds changes (catches AppKit's
///    per-button re-layout) and window-level resize/fullscreen events
///    (catches the post-live-resize layout pass that doesn't always re-emit
///    per-button frame changes).
///
/// `isApplying` breaks the recursion that our own `setFrameOrigin` calls would
/// otherwise feed back in via `frameDidChangeNotification`.
@MainActor
final class TrafficLightPositioner {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var isApplying = false
    var inset: CGSize = .init(width: 15, height: 15)

    func attach(to window: NSWindow) {
        if self.window === window {
            apply()
            return
        }
        detach()
        self.window = window

        // Window-level events that change overall geometry. `didResize` and
        // `didEndLiveResize` catch AppKit's post-live-resize layout pass,
        // which doesn't always re-fire `frameDidChange` on every button.
        let windowNames: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeMainNotification
        ]
        for name in windowNames {
            observers.append(addSyncObserver(name: name, object: window))
        }

        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }

        if let parent = buttons.first?.superview {
            parent.postsFrameChangedNotifications = true
            parent.postsBoundsChangedNotifications = true
            observers.append(addSyncObserver(
                name: NSView.frameDidChangeNotification, object: parent
            ))
            // Some AppKit paths post bounds (not frame) during live resize.
            observers.append(addSyncObserver(
                name: NSView.boundsDidChangeNotification, object: parent
            ))
        }
        for btn in buttons {
            btn.postsFrameChangedNotifications = true
            observers.append(addSyncObserver(
                name: NSView.frameDidChangeNotification, object: btn
            ))
        }

        apply()
    }

    func detach() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        window = nil
    }

    private func addSyncObserver(name: Notification.Name, object: AnyObject) -> NSObjectProtocol {
        // `queue: nil` runs the block synchronously on the posting thread inside
        // `NotificationCenter.post(...)`. AppKit posts view/window notifications
        // on the main thread, so `MainActor.assumeIsolated` is safe.
        NotificationCenter.default.addObserver(
            forName: name, object: object, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    private func apply() {
        guard !isApplying, let window else { return }
        isApplying = true
        defer { isApplying = false }
        window.positionTrafficLights(topInset: inset.height, leadingInset: inset.width)
    }
}

/// SwiftUI helper: fires a callback with the host `NSWindow` once the view is
/// inserted in a window. Use as `.background(WindowAccessor { window in … })`.
struct WindowAccessor: NSViewRepresentable {
    let onAttach: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            onAttach(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            onAttach(window)
        }
    }
}
