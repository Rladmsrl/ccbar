import SwiftUI

/// Wraps a view that was designed for the 380pt-wide menu panel so it looks
/// intentional inside the wide main window: a centered column at `maxWidth`,
/// padded and vertically scrollable. Avoids redesigning each pane in Phase A.
struct CenteredPaneContainer<Content: View>: View {
    var maxWidth: CGFloat = 980
    var topPadding: CGFloat = 52
    var bottomPadding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        AppScrollView {
            content()
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
        }
    }
}
