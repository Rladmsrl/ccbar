import SwiftUI

enum AppSurface {
    static let backgroundFill = Color.stxDynamic(
        light: (0.93, 0.93, 0.94),
        dark: (0.05, 0.05, 0.055)
    )

    static let detailFill = Color.stxDynamic(
        light: (253.0 / 255.0, 253.0 / 255.0, 254.0 / 255.0),
        dark: (0.05, 0.05, 0.055)
    )

    static let panelFill = Color.stxDynamic(
        light: (242.0 / 255.0, 243.0 / 255.0, 244.0 / 255.0),
        dark: (0.085, 0.085, 0.092)
    )

    static let stroke = Color.primary.opacity(0.14)

    static let pillFill = Color.stxDynamic(
        light: (225.0 / 255.0, 225.0 / 255.0, 227.0 / 255.0),
        dark: (0.17, 0.17, 0.185)
    )

    static let pillSelectedFill = Color.stxDynamic(
        light: (1, 1, 1),
        dark: (0.085, 0.085, 0.092)
    )

    static let pillSelectedStroke = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isDark {
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
        }
        return .clear
    })

    static let pillForeground = Color.stxDynamic(
        light: (0.40, 0.40, 0.42),
        dark: (0.78, 0.78, 0.82)
    )
}

struct AppSurfaceChrome {
    let fill: Color
    let stroke: Color?
    let cornerRadius: CGFloat
    let cornerStyle: RoundedCornerStyle
    let strokeWidth: CGFloat
    let defaultPadding: CGFloat?
    let maxWidth: CGFloat?
    let alignment: Alignment

    init(
        fill: Color = AppSurface.panelFill,
        stroke: Color? = nil,
        cornerRadius: CGFloat,
        cornerStyle: RoundedCornerStyle = .continuous,
        strokeWidth: CGFloat = 1,
        defaultPadding: CGFloat? = nil,
        maxWidth: CGFloat? = .infinity,
        alignment: Alignment = .leading
    ) {
        self.fill = fill
        self.stroke = stroke
        self.cornerRadius = cornerRadius
        self.cornerStyle = cornerStyle
        self.strokeWidth = strokeWidth
        self.defaultPadding = defaultPadding
        self.maxWidth = maxWidth
        self.alignment = alignment
    }

    static let mainWindowCard = AppSurfaceChrome(
        cornerRadius: 10,
        defaultPadding: 14
    )

    static let settingCard = AppSurfaceChrome(
        cornerRadius: 10,
        cornerStyle: .circular,
        defaultPadding: nil
    )

    static let instrumentPanel = AppSurfaceChrome(
        cornerRadius: 3,
        cornerStyle: .circular,
        defaultPadding: 12
    )

    static let plainFill = AppSurfaceChrome(
        stroke: nil,
        cornerRadius: 0,
        cornerStyle: .circular,
        defaultPadding: nil,
        maxWidth: nil
    )

    static func compactCard(
        radius: CGFloat,
        fillOpacity: Double = 1,
        cornerStyle: RoundedCornerStyle = .continuous,
        maxWidth: CGFloat? = .infinity
    ) -> AppSurfaceChrome {
        AppSurfaceChrome(
            fill: AppSurface.panelFill.opacity(fillOpacity),
            cornerRadius: radius,
            cornerStyle: cornerStyle,
            defaultPadding: nil,
            maxWidth: maxWidth
        )
    }
}

extension View {
    func appSurface(_ chrome: AppSurfaceChrome, padding: CGFloat? = nil) -> some View {
        modifier(AppSurfaceModifier(chrome: chrome, padding: padding))
    }
}

private struct AppSurfaceModifier: ViewModifier {
    let chrome: AppSurfaceChrome
    let padding: CGFloat?

    private var resolvedPadding: CGFloat? {
        padding ?? chrome.defaultPadding
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: chrome.cornerRadius, style: chrome.cornerStyle)

        content
            .appSurfacePadding(resolvedPadding)
            .frame(maxWidth: chrome.maxWidth, alignment: chrome.alignment)
            .background(chrome.fill, in: shape)
            .overlay {
                if let stroke = chrome.stroke {
                    shape.strokeBorder(stroke, lineWidth: chrome.strokeWidth)
                }
            }
    }
}

private extension View {
    @ViewBuilder
    func appSurfacePadding(_ padding: CGFloat?) -> some View {
        if let padding {
            self.padding(padding)
        } else {
            self
        }
    }
}
