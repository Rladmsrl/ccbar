import AppKit

/// Reference-counted switch for the app's activation policy. CCBar runs
/// as a menu-bar (`LSUIElement`) app and normally stays in `.accessory` (no
/// Dock icon, windows don't take focus); while *any* full-window experience is
/// up — the main window or a Sparkle update dialog — it promotes to `.regular`
/// so the window can come forward like a normal app, then drops back when the
/// last consumer releases.
///
/// Each `acquire()` must be balanced by exactly one `release()`. The clamp in
/// `release()` makes a stray unmatched call a no-op rather than corrupting the
/// count.
@MainActor
final class DockVisibilityCoordinator {
    static let shared = DockVisibilityCoordinator()

    private var count = 0

    func acquire() {
        count += 1
        if count == 1, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func release() {
        count = max(0, count - 1)
        if count == 0, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
