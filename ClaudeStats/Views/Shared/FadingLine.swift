import SwiftUI

/// Keeps a single horizontal run visually inside its available width by fading
/// the trailing edge instead of letting content paint outside the container.
struct FadingLine<Content: View>: View {
    private let fadeWidth: CGFloat
    private let alignment: Alignment
    private let content: Content

    init(
        fadeWidth: CGFloat = 34,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.fadeWidth = fadeWidth
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: alignment) {
            content
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
        .clipped()
        .mask(TrailingFadeMask(width: fadeWidth))
    }
}

struct FadingLineText: View {
    private let text: String
    private let font: Font
    private let foregroundStyle: Color
    private let tracking: CGFloat
    private let fadeWidth: CGFloat

    init(
        _ text: String,
        font: Font,
        foregroundStyle: Color,
        tracking: CGFloat = 0,
        fadeWidth: CGFloat = 34
    ) {
        self.text = text
        self.font = font
        self.foregroundStyle = foregroundStyle
        self.tracking = tracking
        self.fadeWidth = fadeWidth
    }

    var body: some View {
        FadingLine(fadeWidth: fadeWidth) {
            Text(text)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
        }
        .accessibilityLabel(Text(text))
    }
}

struct TrailingFadeMask: View {
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width)
        }
    }
}
