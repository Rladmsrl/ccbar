import SwiftUI

extension View {
    /// Shared main-window panel chrome: the same rounded card treatment used by
    /// wide Dashboard/Usage-style pages.
    func mainWindowPanel(padding: CGFloat = 14) -> some View {
        appSurface(.mainWindowCard, padding: padding)
    }
}
