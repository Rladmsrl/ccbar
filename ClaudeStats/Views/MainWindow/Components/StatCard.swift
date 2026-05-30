import SwiftUI

/// Claude-style summary metric: muted uppercase label above a large bold value.
/// Pure value-driven view (no internal state) so SwiftUI can diff it cheaply
/// when the underlying stats change.
struct StatCard: View {
    let label: String
    let value: String
    var animatesNumericValue = true

    private static let valueLineHeight: CGFloat = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.sora(9, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(Color.stxMuted)
            Text(value)
                .font(.sora(20, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .modifier(NumericValueTransitionIfEnabled(enabled: animatesNumericValue, value: value))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: Self.valueLineHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

#if DEBUG
#Preview {
    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
        GridRow {
            StatCard(label: "Sessions", value: "476")
            StatCard(label: "Messages", value: "128,723")
            StatCard(label: "Total tokens", value: "119.0M")
            StatCard(label: "Active days", value: "48")
        }
        GridRow {
            StatCard(label: "Current streak", value: "38d")
            StatCard(label: "Longest streak", value: "38d")
            StatCard(label: "Peak hour", value: "5 PM")
            StatCard(label: "Favorite model", value: "Opus 4.7")
        }
    }
    .padding(24)
    .frame(width: 760)
    .background(Color.stxBackground)
}
#endif
