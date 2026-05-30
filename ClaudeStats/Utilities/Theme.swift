import SwiftUI
import AppKit
import CoreText

// MARK: - Font registration

/// Registers the bundled Sora variable font and namespaces a couple of
/// font-family constants. Design *tokens* live in the `Color`/`Font` extensions
/// below; reusable chrome (`BracketBox`, `TickBar`, the `stxPanel` modifier)
/// lives further down.
///
/// The colour tokens are appearance-aware — they resolve light or dark from the
/// SwiftUI `colorScheme` environment, so the popover follows the system (light
/// by default). The one exception is the chart "screen" panel, which forces a
/// dark environment locally so it always reads like an instrument display.
enum Theme {
    /// Family name of the bundled Sora variable font (`name` table id 1).
    static let fontFamily = "Sora"

    enum AppFontKind: Equatable {
        case sora
        case system
    }

    /// Register the bundled Sora font with the process. Safe to call repeatedly
    /// — a redundant registration just returns an error we ignore — and safe
    /// from SwiftUI previews, where the resource may be absent (we log and skip,
    /// and `Font.sora` falls back to the system font).
    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "Sora-VariableFont_wght", withExtension: "ttf") else {
            Log.app.error("Sora font not found in bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            Log.app.debug("Sora font registration skipped: \(String(describing: error?.takeRetainedValue()))")
        }
    }

    static func appFontKind(for locale: Locale) -> AppFontKind {
        appFontKind(forLanguageIdentifier: locale.identifier)
    }

    static func appFontKindForCurrentAppLanguage(defaults: UserDefaults = .standard) -> AppFontKind {
        if let override = defaults.array(forKey: AppLanguagePreference.appleLanguagesDefaultsKey) as? [String],
           let first = override.first {
            return appFontKind(forLanguageIdentifier: first)
        }
        return appFontKind(forLanguageIdentifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    static func appFont(_ size: CGFloat,
                        weight: Font.Weight = .regular,
                        monospacedDigit: Bool = false,
                        locale: Locale? = nil) -> Font {
        let kind = locale.map(appFontKind(for:)) ?? appFontKindForCurrentAppLanguage()
        var font: Font = switch kind {
        case .sora:
            .custom(fontFamily, size: size).weight(weight)
        case .system:
            .system(size: size, weight: weight)
        }
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }

    static func appFontKind(forLanguageIdentifier identifier: String) -> AppFontKind {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        return normalized.hasPrefix("zh") ? .system : .sora
    }
}

// MARK: - Colors

extension Color {
    /// An appearance-aware colour from sRGB components for the light and dark
    /// variants. (No asset catalog needed — wraps a dynamic `NSColor`.)
    static func stxDynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// Compact menu-bar popover backdrop.
    static let stxBackground = MenuBarSurface.backgroundFill
    /// Compact menu-bar panel fill.
    static let stxPanel = MenuBarSurface.panelFill
    /// Hairline for panel borders, dividers, chart grid lines.
    static let stxStroke = AppSurface.stroke
    /// Bracket glyphs (`[ ]`, scanline ends) — a touch brighter than `stxStroke`.
    static let stxBracket = Color.primary.opacity(0.30)
    /// Muted secondary text (labels, captions).
    static let stxMuted = Color.primary.opacity(0.62)
    /// Primary warm accent (same in light and dark).
    static let stxAccent = Color(red: 0.94, green: 0.42, blue: 0.12)

    /// Warm series ramp — deep red → gold, most-prominent first. Wider than the
    /// four hues in the design mock so >4 models still land on distinct stops.
    /// Always vivid; it lives on the dark chart "screen" in both appearances.
    static let stxRamp: [Color] = [
        Color(red: 0.91, green: 0.21, blue: 0.13),  // deep red
        Color(red: 0.96, green: 0.44, blue: 0.13),  // orange
        Color(red: 0.93, green: 0.66, blue: 0.12),  // amber
        Color(red: 0.97, green: 0.84, blue: 0.22),  // gold
        Color(red: 1.00, green: 0.57, blue: 0.30),  // light orange
        Color(red: 0.99, green: 0.76, blue: 0.24),  // light amber
        Color(red: 0.78, green: 0.26, blue: 0.08),  // burnt
        Color(red: 1.00, green: 0.90, blue: 0.46),  // pale yellow
    ]
}

// MARK: - Fonts

extension Font {
    /// The bundled Sora font at `size`/`weight`. Registered at launch via
    /// ``Theme/registerFonts()``; falls back to the system font if unavailable.
    static func sora(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Theme.appFont(size, weight: weight)
    }
}

private struct StxFontModifier: ViewModifier {
    @Environment(\.locale) private var locale
    let size: CGFloat
    let weight: Font.Weight
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        content.font(Theme.appFont(size, weight: weight, monospacedDigit: monospacedDigit, locale: locale))
    }
}

extension View {
    func stxFont(_ size: CGFloat,
                 weight: Font.Weight = .regular,
                 monospacedDigit: Bool = false) -> some View {
        modifier(StxFontModifier(size: size, weight: weight, monospacedDigit: monospacedDigit))
    }
}

// MARK: - Bracket readout

/// `[ ⟨content⟩ ]` — content flanked by muted square brackets, the recurring
/// readout motif from the dashboard mock.
struct BracketBox<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) {
            Text("[").foregroundStyle(Color.stxBracket)
            content
            Text("]").foregroundStyle(Color.stxBracket)
        }
    }
}

// MARK: - Panel container

extension View {
    /// Wraps the view as a compact menu-bar instrument panel: opaque fill, a
    /// 1px hairline border, square corners, and inset padding.
    func stxPanel(_ padding: CGFloat = 12) -> some View {
        menuBarSurface(.instrumentPanel, padding: padding)
    }
}

/// A standalone 1px horizontal rule in the theme's stroke colour.
struct StxRule: View {
    var body: some View { Rectangle().fill(Color.stxStroke).frame(height: 1) }
}

// MARK: - Top scanline decoration

/// The thin "scanline" strip along the popover's top edge — evenly spaced ticks
/// bracketed at both ends, a few lit in the accent colour while `active`.
struct TickBar: View {
    var active = false
    private let count = 26

    var body: some View {
        HStack(spacing: 5) {
            Text("[").foregroundStyle(Color.stxBracket)
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(tickColor(i))
                        .frame(maxWidth: .infinity)
                        .frame(height: 5)
                }
            }
            Text("]").foregroundStyle(Color.stxBracket)
        }
        .font(.sora(11))
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 5)
    }

    private func tickColor(_ i: Int) -> Color {
        if active && i.isMultiple(of: 4) { return .stxAccent }
        return Color.primary.opacity(i.isMultiple(of: 3) ? 0.28 : 0.13)
    }
}

#if DEBUG
private struct ThemeChromePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TickBar(active: true)
            BracketBox { Text("TOKENS: 1.2M").font(.sora(12)) }
            HStack {
                ForEach(Array(Color.stxRamp.enumerated()), id: \.offset) { _, c in
                    Rectangle().fill(c).frame(width: 22, height: 22)
                }
            }
            VStack(alignment: .leading) {
                Text("BREAKDOWN").font(.sora(13, weight: .semibold))
                Text("body text in sora").font(.sora(12)).foregroundStyle(Color.stxMuted)
            }
            .stxPanel()
            .environment(\.colorScheme, .dark)
        }
        .padding()
        .frame(width: 380)
        .background(Color.stxBackground)
    }
}

#Preview("Theme chrome — light") { ThemeChromePreview().preferredColorScheme(.light) }
#Preview("Theme chrome — dark") { ThemeChromePreview().preferredColorScheme(.dark) }
#endif
