import SwiftUI
import Darwin

/// The main window's detail area. Sits flush with the window's top, right,
/// and bottom edges; only its left side (where it meets the vibrancy sidebar)
/// is rounded. The opaque `AppSurface.detailFill` fill against the translucent
/// sidebar gives it the "above the sidebar in z-index" reading — the sidebar
/// vibrancy peeks through the rounded corner cutouts on the left.
struct DetailPanel<Content: View>: View {
    var roundedLeading: Bool = true
    var boundaryFalloffEnabled: Bool = true
    @ViewBuilder var content: () -> Content

    private let leadingCornerRadius: CGFloat = 12
    private let leadingFalloffWidth: CGFloat = 10

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: roundedLeading ? leadingCornerRadius : 0,
            bottomLeadingRadius: roundedLeading ? leadingCornerRadius : 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0
        )
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if roundedLeading && boundaryFalloffEnabled {
                DetailPanelBoundaryFalloff(
                    width: leadingFalloffWidth,
                    cornerRadius: leadingCornerRadius
                )
            }

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppSurface.detailFill, in: shape)
                .clipShape(shape)
                .overlay {
                    if roundedLeading && boundaryFalloffEnabled {
                        shape
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                            .mask {
                                GeometryReader { proxy in
                                    Rectangle()
                                        .frame(width: leadingCornerRadius + 1, height: proxy.size.height)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                    }
                }
        }
    }
}

private struct DetailPanelBoundaryFalloff: View {
    @Environment(\.colorScheme) private var colorScheme

    let width: CGFloat
    let cornerRadius: CGFloat

    private var peakOpacity: Double {
        colorScheme == .dark ? 0.16 : 0.10
    }

    private var falloffColor: Color {
        colorScheme == .dark
            ? Color(red: 0.58, green: 0.58, blue: 0.58)
            : Color(red: 0.42, green: 0.42, blue: 0.42)
    }

    private var logarithmicStops: [Gradient.Stop] {
        let curveStrength = 12.0
        let steps = 10

        return (0...steps).map { index in
            let t = Double(index) / Double(steps)
            let falloff = 1 - (log1p(curveStrength * t) / log1p(curveStrength))

            return Gradient.Stop(
                color: falloffColor.opacity(peakOpacity * max(0, falloff)),
                location: CGFloat(t)
            )
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                LinearGradient(stops: logarithmicStops, startPoint: .trailing, endPoint: .leading)
                    .frame(width: width, height: max(0, proxy.size.height - cornerRadius * 2))
                    .offset(x: -width, y: cornerRadius)

                RadialGradient(
                    stops: logarithmicStops,
                    center: .bottomTrailing,
                    startRadius: cornerRadius,
                    endRadius: cornerRadius + width
                )
                .frame(width: width + cornerRadius, height: cornerRadius)
                .offset(x: -width)

                RadialGradient(
                    stops: logarithmicStops,
                    center: .topTrailing,
                    startRadius: cornerRadius,
                    endRadius: cornerRadius + width
                )
                .frame(width: width + cornerRadius, height: cornerRadius)
                .offset(x: -width, y: max(0, proxy.size.height - cornerRadius))
            }
        }
        .allowsHitTesting(false)
    }
}
