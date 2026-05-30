import SwiftUI

enum MenuBarSurface {
    static let backgroundFill = Color.stxDynamic(
        light: (0.93, 0.93, 0.94),
        dark: (0.05, 0.05, 0.055)
    )

    static let panelFill = Color.stxDynamic(
        light: (0.965, 0.949, 0.910),
        dark: (0.085, 0.085, 0.092)
    )

    static let stroke = Color.primary.opacity(0.14)
}

struct MenuBarSurfaceChrome {
    let fill: Color
    let stroke: Color?
    let cornerRadius: CGFloat
    let cornerStyle: RoundedCornerStyle
    let strokeWidth: CGFloat
    let defaultPadding: CGFloat?
    let maxWidth: CGFloat?
    let alignment: Alignment

    init(
        fill: Color = MenuBarSurface.panelFill,
        stroke: Color? = MenuBarSurface.stroke,
        cornerRadius: CGFloat = 0,
        cornerStyle: RoundedCornerStyle = .circular,
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

    static let instrumentPanel = MenuBarSurfaceChrome(
        defaultPadding: 12
    )

    static let plainFill = MenuBarSurfaceChrome(
        stroke: nil,
        defaultPadding: nil,
        maxWidth: nil
    )

    static func compactCard(
        fillOpacity: Double = 1,
        cornerRadius: CGFloat = 0,
        cornerStyle: RoundedCornerStyle = .circular,
        maxWidth: CGFloat? = .infinity
    ) -> MenuBarSurfaceChrome {
        MenuBarSurfaceChrome(
            fill: MenuBarSurface.panelFill.opacity(fillOpacity),
            cornerRadius: cornerRadius,
            cornerStyle: cornerStyle,
            defaultPadding: nil,
            maxWidth: maxWidth
        )
    }
}

extension View {
    func menuBarSurface(_ chrome: MenuBarSurfaceChrome, padding: CGFloat? = nil) -> some View {
        modifier(MenuBarSurfaceModifier(chrome: chrome, padding: padding))
    }
}

private struct MenuBarSurfaceModifier: ViewModifier {
    let chrome: MenuBarSurfaceChrome
    let padding: CGFloat?

    private var resolvedPadding: CGFloat? {
        padding ?? chrome.defaultPadding
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: chrome.cornerRadius, style: chrome.cornerStyle)

        content
            .menuBarSurfacePadding(resolvedPadding)
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
    func menuBarSurfacePadding(_ padding: CGFloat?) -> some View {
        if let padding {
            self.padding(padding)
        } else {
            self
        }
    }
}
