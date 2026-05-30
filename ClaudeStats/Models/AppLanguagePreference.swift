import Foundation

/// User-facing language override for the app. `.system` removes the app-level
/// override and lets macOS choose the best available localization.
enum AppLanguagePreference: String, CaseIterable, Sendable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }

    var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    func displayName(locale: Locale? = nil) -> String {
        switch self {
        case .system:
            L10n.string("app.language.system", defaultValue: "Follow System", locale: locale)
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        }
    }

    func applyToAppleLanguages(defaults: UserDefaults = .standard) {
        if let localeIdentifier {
            defaults.set([localeIdentifier], forKey: Self.appleLanguagesDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.appleLanguagesDefaultsKey)
        }
    }

    static let appleLanguagesDefaultsKey = "AppleLanguages"
}
