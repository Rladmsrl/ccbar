import SwiftUI

/// Two-up "radio cards" picker — the `适用于编程 / 适用于日常工作` motif
/// from the Codex screenshot. Renders each option as a card with an icon,
/// title, and subtitle; the selected card gets an accent ring + a filled
/// dot in the trailing corner.
///
/// Generic over a `Hashable` selection so the same component drives the
/// menu-bar metric picker, the menu-bar period picker, etc.
struct SettingSegmentCard<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Option]

    struct Option: Identifiable {
        let value: Value
        let title: String
        var subtitle: String? = nil
        var symbol: String? = nil
        var id: Value { value }
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(options) { option in
                cell(option)
            }
        }
    }

    private func cell(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isSelected ? Color.stxAccent : Color.stxMuted)
                        .frame(width: 22, height: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(option.title))
                        .font(.sora(13, weight: .medium))
                        .foregroundStyle(.primary)
                    if let subtitle = option.subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.sora(11))
                            .foregroundStyle(Color.stxMuted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.stxAccent : Color.stxStroke, lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle().fill(Color.stxAccent).frame(width: 8, height: 8)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(.compactCard(radius: 10, cornerStyle: .circular, maxWidth: nil), padding: nil)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}
