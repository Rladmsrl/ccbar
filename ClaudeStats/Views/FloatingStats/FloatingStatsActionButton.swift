import SwiftUI

struct FloatingStatsActionButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let symbol: String
    let label: String
    let action: () -> Void

    private var isHighlighted: Bool {
        isEnabled && isHovering
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 28)
                .background(backgroundShape)
                .overlay(strokeShape)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHighlighted)
        .help(label)
        .accessibilityLabel(label)
    }

    private var iconColor: Color {
        if !isEnabled {
            return Color.stxMuted.opacity(0.55)
        }
        return isHighlighted ? Color.primary : Color.primary.opacity(0.78)
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(isHighlighted ? 0.12 : 0.06))
    }

    private var strokeShape: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(isHighlighted ? Color.primary.opacity(0.22) : Color.stxStroke, lineWidth: 1)
    }
}
