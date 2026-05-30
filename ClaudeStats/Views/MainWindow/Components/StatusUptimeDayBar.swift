import SwiftUI

struct StatusUptimeBar: Identifiable {
    let id: Date
    let color: Color
    let tooltip: String
}

struct StatusUptimeStrip: View {
    let bars: [StatusUptimeBar]

    @State private var hoveredIndex: Int?

    private static let height: CGFloat = 34
    private static let spacing: CGFloat = 2
    private static let hoverScale: CGFloat = 1.18
    private static let tooltipGap: CGFloat = 34
    private static let hoverAnimation = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.18)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBars(in: size, context: &context)
                }
                .frame(height: Self.height)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        updateHover(at: location, in: proxy.size)
                    case .ended:
                        setHoveredIndex(nil)
                    }
                }

                if let hoveredIndex,
                   bars.indices.contains(hoveredIndex) {
                    StatusUptimeTooltip(text: bars[hoveredIndex].tooltip)
                        .position(
                            x: tooltipX(for: hoveredIndex, width: proxy.size.width),
                            y: -Self.tooltipGap
                        )
                        .transition(
                            .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .bottom))
                        )
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    private func drawBars(in size: CGSize, context: inout GraphicsContext) {
        guard !bars.isEmpty else { return }
        let metrics = barMetrics(width: size.width)
        for index in bars.indices {
            let isHovered = index == hoveredIndex
            let barHeight = Self.height * (isHovered ? Self.hoverScale : 1)
            let rect = CGRect(
                x: CGFloat(index) * metrics.stride,
                y: (Self.height - barHeight) / 2,
                width: metrics.width,
                height: barHeight
            )
            context.fill(Path(rect), with: .color(bars[index].color))
        }
    }

    private func updateHover(at location: CGPoint, in size: CGSize) {
        guard !bars.isEmpty,
              location.x >= 0,
              location.x <= size.width,
              location.y >= 0,
              location.y <= Self.height
        else {
            setHoveredIndex(nil)
            return
        }

        let metrics = barMetrics(width: size.width)
        guard metrics.stride > 0 else {
            setHoveredIndex(nil)
            return
        }

        let index = Int(location.x / metrics.stride)
        guard bars.indices.contains(index) else {
            setHoveredIndex(nil)
            return
        }

        let xInColumn = location.x - CGFloat(index) * metrics.stride
        setHoveredIndex(xInColumn <= metrics.width ? index : nil)
    }

    private func setHoveredIndex(_ index: Int?) {
        guard hoveredIndex != index else { return }
        withAnimation(Self.hoverAnimation) {
            hoveredIndex = index
        }
    }

    private func tooltipX(for index: Int, width: CGFloat) -> CGFloat {
        let metrics = barMetrics(width: width)
        let center = CGFloat(index) * metrics.stride + metrics.width / 2
        return min(max(center, 42), max(42, width - 42))
    }

    private func barMetrics(width: CGFloat) -> (width: CGFloat, stride: CGFloat) {
        guard !bars.isEmpty else { return (0, 0) }
        let count = CGFloat(bars.count)
        let totalSpacing = Self.spacing * max(0, count - 1)
        let barWidth = max(1, (width - totalSpacing) / count)
        return (barWidth, barWidth + Self.spacing)
    }
}

private struct StatusUptimeTooltip: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.sora(10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: 260)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            TooltipArrow()
                .fill(Color.black)
                .frame(width: 10, height: 5)
        }
        .fixedSize()
        .shadow(color: Color.black.opacity(0.18), radius: 5, x: 0, y: 2)
    }
}

private struct TooltipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
