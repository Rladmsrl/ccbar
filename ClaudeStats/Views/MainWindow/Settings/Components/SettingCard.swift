import SwiftUI

/// Codex-style rounded card that wraps one or more `SettingRow`s. Adds a
/// hairline border + opaque fill so it sits cleanly on the detail panel
/// background.
extension View {
    func settingCard() -> some View {
        modifier(SettingCardModifier())
    }
}

private struct SettingCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.appSurface(.settingCard)
    }
}
