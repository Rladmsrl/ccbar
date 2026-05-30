import Foundation

/// Small localization helpers for dynamic strings that cannot be represented by
/// a bare SwiftUI `Text("key")` literal.
enum L10n {
    static func string(_ key: String, defaultValue: String, locale: Locale? = nil) -> String {
        let bundle = locale.flatMap { Bundle.localizedBundle(for: $0) } ?? .main
        let localized = bundle.localizedString(forKey: key, value: defaultValue, table: nil)
        return localized == key ? defaultValue : localized
    }

    static func format(_ key: String, defaultValue: String, locale: Locale? = nil, _ arguments: CVarArg...) -> String {
        let format = string(key, defaultValue: defaultValue, locale: locale)
        return String(format: format, locale: locale ?? .current, arguments: arguments)
    }

    static func refreshInterval(minutes: Int, locale: Locale? = nil) -> String {
        let key = minutes == 1 ? "refresh.interval.one" : "refresh.interval.other"
        let fallback = minutes == 1 ? "%d minute" : "%d minutes"
        return format(key, defaultValue: fallback, locale: locale, minutes)
    }

    static func count(_ value: Int, singularKey: String, pluralKey: String, singularDefault: String, pluralDefault: String, locale: Locale? = nil) -> String {
        format(value == 1 ? singularKey : pluralKey,
               defaultValue: value == 1 ? singularDefault : pluralDefault,
               locale: locale,
               value)
    }

    static func activeDays(_ value: Int, locale: Locale? = nil) -> String {
        count(value,
              singularKey: "count.active_day.one",
              pluralKey: "count.active_day.other",
              singularDefault: "%d active day",
              pluralDefault: "%d active days",
              locale: locale)
    }

    static func contributionCount(_ value: Int, locale: Locale? = nil) -> String {
        count(value,
              singularKey: "count.contribution.one",
              pluralKey: "count.contribution.other",
              singularDefault: "%d contribution",
              pluralDefault: "%d contributions",
              locale: locale)
    }

    static func sessionCount(_ value: Int, locale: Locale? = nil) -> String {
        count(value,
              singularKey: "count.session.one",
              pluralKey: "count.session.other",
              singularDefault: "%d session",
              pluralDefault: "%d sessions",
              locale: locale)
    }

    static func messageCount(_ value: Int, locale: Locale? = nil) -> String {
        count(value,
              singularKey: "count.message.one",
              pluralKey: "count.message.other",
              singularDefault: "%d message",
              pluralDefault: "%d messages",
              locale: locale)
    }

    static func tokenCount(_ value: Int, locale: Locale? = nil) -> String {
        count(value,
              singularKey: "count.token.one",
              pluralKey: "count.token.other",
              singularDefault: "%d token",
              pluralDefault: "%d tokens",
              locale: locale)
    }

    static func restartLanguageNotice(locale: Locale? = nil) -> String {
        string("settings.language.restart_required",
               defaultValue: "Restart CCBar to apply this language.",
               locale: locale)
    }
}

private extension Bundle {
    static func localizedBundle(for locale: Locale) -> Bundle? {
        for identifier in localizationCandidates(for: locale) {
            if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    static func localizationCandidates(for locale: Locale) -> [String] {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if identifier.hasPrefix("zh-Hans") || identifier == "zh-CN" || identifier == "zh-SG" {
            return ["zh-Hans", "zh"]
        }
        if identifier.hasPrefix("en") {
            return ["en"]
        }
        return [identifier]
    }
}
