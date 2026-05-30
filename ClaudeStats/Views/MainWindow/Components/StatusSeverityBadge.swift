import SwiftUI

struct StatusSeverityBadge: View {
    let label: String
    let indicatorTint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(indicatorTint)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.sora(9, weight: .semibold))
                .foregroundStyle(AppSurface.pillForeground)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(AppSurface.pillFill, in: Capsule())
    }
}
