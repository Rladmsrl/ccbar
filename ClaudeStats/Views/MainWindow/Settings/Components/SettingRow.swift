import SwiftUI

/// A single horizontal row inside a `SettingCard`: title (+ optional
/// description) on the leading edge, an arbitrary trailing accessory
/// (toggle / picker / button / etc.) on the trailing edge.
struct SettingRow<Accessory: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.sora(13, weight: .medium))
                    .foregroundStyle(.primary)
                if let description {
                    Text(LocalizedStringKey(description))
                        .font(.sora(11))
                        .foregroundStyle(Color.stxMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

/// A 1px divider used between rows inside the same card.
struct SettingRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.stxStroke)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}
