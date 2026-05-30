import AppKit
import SwiftUI

/// Standard content scroll container for the app.
///
/// Use this for full content regions such as sidebars, detail panes, lists,
/// settings, and inspectors. It intentionally delegates indicator rendering and
/// hiding behavior to the native macOS scroll view instead of drawing custom
/// scrollbar chrome.
struct AppScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let content: () -> Content

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes
        self.content = content
    }

    var body: some View {
        ScrollView(axes) {
            content()
                .background(AppScrollViewNativeConfigurator(axes: axes))
        }
        .scrollIndicators(.automatic)
    }
}

private struct AppScrollViewNativeConfigurator: NSViewRepresentable {
    let axes: Axis.Set

    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView(axes: axes)
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.axes = axes
        nsView.configure()
    }

    final class ConfiguratorView: NSView {
        var axes: Axis.Set

        init(axes: Axis.Set) {
            self.axes = axes
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configure()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        override func layout() {
            super.layout()
            configure()
        }

        func configure() {
            guard let scrollView = enclosingNativeScrollView else { return }
            AppScrollbars.configure(scrollView, axes: axes)
        }

        private var enclosingNativeScrollView: NSScrollView? {
            if let scrollView = enclosingScrollView {
                return scrollView
            }

            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                candidate = view.superview
            }
            return nil
        }
    }
}

enum AppScrollbars {
    @MainActor
    static func configure(_ scrollView: NSScrollView, axes: Axis.Set = .vertical) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = axes.contains(.vertical)
        scrollView.hasHorizontalScroller = axes.contains(.horizontal)
    }
}
