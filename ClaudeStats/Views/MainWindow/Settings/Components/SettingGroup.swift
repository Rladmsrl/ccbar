import SwiftUI

/// A labeled group of one or more `SettingCard`s. Renders an uppercase title
/// + optional caption above its content, mirroring the section bands in the
/// Codex settings reference.
struct SettingGroup<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.sora(15, weight: .semibold))
                    .foregroundStyle(.primary)
                if let caption {
                    Text(LocalizedStringKey(caption))
                        .font(.sora(11))
                        .foregroundStyle(Color.stxMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
    }
}
