import Foundation

/// Kinds of metrics the menu-bar status item can show. The set is fixed —
/// each kind is opinionated about what data source feeds it and how it
/// renders, so adding one means adding a case here and teaching
/// ``MenuBarLabel`` and ``MenuBarSettingsView`` about it.
enum MenuBarItemKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Compact total tokens across ``MenuBarItem/period``.
    case tokens
    /// Compact total cost across ``MenuBarItem/period``, in the user's
    /// configured ``CostEstimationMode``.
    case cost
    /// `used_percent` from the live 5h Anthropic quota window.
    case fiveHourUsage
    /// `used_percent` from the live 7d Anthropic quota window.
    case sevenDayUsage
    /// Extrapolated "time until 5h window hits 100%" — surfaced as a
    /// compact duration. Renders as nothing until the trend store has
    /// gathered enough samples to produce an estimate.
    case fiveHourPrediction

    var id: String { rawValue }

    /// True when a ``MenuBarItem`` of this kind also carries a
    /// ``StatsPeriod``. The usage-limit kinds are pinned to their own
    /// Anthropic window and ignore the period entirely.
    var supportsPeriod: Bool {
        switch self {
        case .tokens, .cost: return true
        case .fiveHourUsage, .sevenDayUsage, .fiveHourPrediction: return false
        }
    }

    /// True when the cache-read toggle is meaningful. Only `.tokens` cares
    /// — cost is mode-driven and the usage-limit kinds are percentages.
    var supportsCacheToggle: Bool {
        self == .tokens
    }

    /// True when this kind has a meaningful choice between
    /// percent-used and reset-countdown rendering. Only the two
    /// live-quota kinds qualify; `.fiveHourPrediction` is already a
    /// duration, and `.tokens` / `.cost` have no reset concept.
    var supportsUsageDisplayMode: Bool {
        switch self {
        case .fiveHourUsage, .sevenDayUsage: return true
        case .tokens, .cost, .fiveHourPrediction: return false
        }
    }

    var displayName: String {
        switch self {
        case .tokens: L10n.string("menu_bar.kind.tokens", defaultValue: "Tokens")
        case .cost: L10n.string("menu_bar.kind.cost", defaultValue: "Cost")
        case .fiveHourUsage: L10n.string("menu_bar.kind.five_hour_usage", defaultValue: "5h usage")
        case .sevenDayUsage: L10n.string("menu_bar.kind.seven_day_usage", defaultValue: "7d usage")
        case .fiveHourPrediction: L10n.string("menu_bar.kind.five_hour_prediction", defaultValue: "5h prediction")
        }
    }

    var caption: String {
        switch self {
        case .tokens:
            L10n.string("menu_bar.kind.tokens.caption", defaultValue: "Total tokens across the chosen period.")
        case .cost:
            L10n.string("menu_bar.kind.cost.caption", defaultValue: "Estimated USD across the chosen period.")
        case .fiveHourUsage:
            L10n.string("menu_bar.kind.five_hour_usage.caption", defaultValue: "How much of the 5-hour Anthropic quota is used.")
        case .sevenDayUsage:
            L10n.string("menu_bar.kind.seven_day_usage.caption", defaultValue: "How much of the 7-day Anthropic quota is used.")
        case .fiveHourPrediction:
            L10n.string("menu_bar.kind.five_hour_prediction.caption", defaultValue: "Extrapolated time until the 5-hour window exhausts.")
        }
    }

    /// SF Symbol shown next to each menu-bar segment and in the settings
    /// row. Picked so the kinds remain visually distinct at status-item
    /// size.
    var symbol: String {
        switch self {
        case .tokens: "number"
        case .cost: "dollarsign.circle"
        case .fiveHourUsage: "gauge.with.dots.needle.50percent"
        case .sevenDayUsage: "calendar"
        case .fiveHourPrediction: "hourglass"
        }
    }
}

/// Picks the prefix shown before the percent on a usage-window menu-bar
/// item. The percent itself is always rendered. Only applies to kinds
/// that report ``MenuBarItemKind/supportsUsageDisplayMode`` = true —
/// currently `.fiveHourUsage` and `.sevenDayUsage`.
enum UsageDisplayMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Static window-length prefix from `window.label` — e.g. `5h 42%`.
    /// Default; preserves the rendering shipped before this enum existed.
    /// (Raw value retained as "percent" for prefs backward-compat.)
    case percent
    /// Countdown until `window.resetAt` as the prefix — e.g. `3h 0m 42%`.
    /// Falls back to the windowLength prefix when no snapshot or no
    /// `resetAt` is available.
    case remainingTime
    /// Wall-clock time of the next reset as the prefix — e.g. `15:30 42%`
    /// for today, `05/27 09:00 42%` for any future day. Falls back to the
    /// windowLength prefix when no snapshot or no `resetAt` is available.
    case resetTime
}

/// One row of the menu-bar status item — a metric kind plus the per-row
/// options that only matter for some kinds. The order of items in
/// ``Preferences/menuBarItems`` is the order they render in.
///
/// `id == kind` because the menu bar shows at most one of each kind; this
/// keeps the array a simple `[MenuBarItem]` rather than needing an
/// `Identifiable` wrapper, and lets the catalog reconcile against a stored
/// list by kind (e.g. a future kind shows up disabled-by-default without
/// touching the user's existing ordering).
struct MenuBarItem: Sendable, Hashable, Identifiable {
    var kind: MenuBarItemKind
    var isEnabled: Bool
    /// Only consulted when ``kind/supportsPeriod`` is true.
    var period: StatsPeriod
    /// Only consulted when ``kind/supportsCacheToggle`` is true.
    var includesCache: Bool
    /// Only consulted when ``kind/supportsUsageDisplayMode`` is true.
    var displayMode: UsageDisplayMode

    var id: MenuBarItemKind { kind }

    init(kind: MenuBarItemKind,
         isEnabled: Bool,
         period: StatsPeriod = .today,
         includesCache: Bool = true,
         displayMode: UsageDisplayMode = .percent) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.period = period
        self.includesCache = includesCache
        self.displayMode = displayMode
    }

    /// Default catalog — every kind, ordered for what we think most users
    /// want first. Cost is the headline glance; 5h usage matters once
    /// quotas tighten; the rest are off by default to keep the menu bar
    /// compact on first launch.
    static var defaultCatalog: [MenuBarItem] {
        [
            MenuBarItem(kind: .cost, isEnabled: true, period: .today),
            MenuBarItem(kind: .tokens, isEnabled: true, period: .today, includesCache: true),
            MenuBarItem(kind: .fiveHourUsage, isEnabled: false),
            MenuBarItem(kind: .fiveHourPrediction, isEnabled: false),
            MenuBarItem(kind: .sevenDayUsage, isEnabled: false),
        ]
    }

    /// Reconcile a stored list against the current catalog: keep the
    /// user's order and per-row settings; drop kinds the app no longer
    /// knows about; append any newly-introduced kinds at the bottom,
    /// disabled. Used both at load time and as a safety net before any
    /// write so the array can never persist a stale shape.
    static func reconciled(stored: [MenuBarItem]) -> [MenuBarItem] {
        let known = Set(MenuBarItemKind.allCases)
        var seen = Set<MenuBarItemKind>()
        var result: [MenuBarItem] = []
        result.reserveCapacity(MenuBarItemKind.allCases.count)
        for item in stored where known.contains(item.kind) && !seen.contains(item.kind) {
            seen.insert(item.kind)
            result.append(item)
        }
        for fallback in defaultCatalog where !seen.contains(fallback.kind) {
            var disabled = fallback
            disabled.isEnabled = false
            result.append(disabled)
        }
        return result
    }
}

// MARK: - Codable

/// Hand-written Codable so the introduction of `displayMode` does not
/// invalidate the menu-bar prefs JSON written by older builds. Synthesized
/// `Decodable` would throw `keyNotFound("displayMode")` on those payloads.
extension MenuBarItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, isEnabled, period, includesCache, displayMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try container.decode(MenuBarItemKind.self, forKey: .kind)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        // `period` and `includesCache` were both required in the
        // synthesized Codable shipped before this commit — preserve the
        // strict behavior so we don't silently swallow shape regressions
        // in stored prefs. Only `displayMode` is intentionally lenient
        // (decodeIfPresent + default) because the field is brand-new.
        self.period = try container.decode(StatsPeriod.self, forKey: .period)
        self.includesCache = try container.decode(Bool.self, forKey: .includesCache)
        self.displayMode = try container.decodeIfPresent(UsageDisplayMode.self, forKey: .displayMode) ?? .percent
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(period, forKey: .period)
        try container.encode(includesCache, forKey: .includesCache)
        try container.encode(displayMode, forKey: .displayMode)
    }
}
