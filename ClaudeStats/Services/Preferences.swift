import Foundation
import Observation

enum APIProviderKeyStorageMode: String, CaseIterable, Sendable, Identifiable {
    case json
    case keychain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .json: "JSON"
        case .keychain: L10n.string("api_key_storage.keychain", defaultValue: "Keychain")
        }
    }
}

/// Thin, observable wrapper over the handful of `UserDefaults` keys the app
/// uses. Writing a property persists it immediately.
@MainActor
@Observable
final class Preferences {
    var appLanguagePreference: AppLanguagePreference {
        didSet {
            defaults.set(appLanguagePreference.rawValue, forKey: Keys.appLanguagePreference)
            appLanguagePreference.applyToAppleLanguages(defaults: defaults)
        }
    }
    var autoRefreshMinutes: Int {
        didSet { defaults.set(autoRefreshMinutes, forKey: Keys.autoRefreshMinutes) }
    }
    /// Ordered list of components the menu-bar status item renders. Only
    /// ``MenuBarItem/isEnabled`` items are shown; the order in this array
    /// is the visual order, left-to-right. Reconciled against
    /// ``MenuBarItem/defaultCatalog`` on every write so a stale or
    /// hand-edited UserDefaults value can never persist a malformed shape.
    var menuBarItems: [MenuBarItem] {
        didSet {
            let normalized = MenuBarItem.reconciled(stored: menuBarItems)
            if normalized != menuBarItems {
                // Re-fires didSet exactly once; the second pass writes below.
                menuBarItems = normalized
                return
            }
            if let data = try? JSONEncoder().encode(menuBarItems),
               let json = String(data: data, encoding: .utf8) {
                defaults.set(json, forKey: Keys.menuBarItems)
            }
        }
    }
    /// Whether token totals shown in the app (Usage stats, BY MODEL, sessions
    /// list) include `cache_read` tokens. On by default — `cache_read` is what
    /// Anthropic's API reports per turn, so excluding it disagrees with the
    /// Console. Off gives a "real flow-through" figure closer to billed
    /// (non-cached) traffic. ``cache_creation`` is always counted regardless;
    /// only the per-turn cache-read re-reporting is what this gates.
    var includeCacheInTokens: Bool {
        didSet { defaults.set(includeCacheInTokens, forKey: Keys.includeCacheInTokens) }
    }
    /// Which cost estimate the UI displays. The standard API mode is the
    /// stable baseline; detailed billing applies only billable details that
    /// transcripts expose explicitly.
    var costEstimationMode: CostEstimationMode {
        didSet { defaults.set(costEstimationMode.rawValue, forKey: Keys.costEstimationMode) }
    }
    /// Optional floating edge tab used as a backup entry point when the macOS
    /// menu bar is crowded.
    var floatingTabEnabled: Bool {
        didSet { defaults.set(floatingTabEnabled, forKey: Keys.floatingTabEnabled) }
    }
    /// Last snapped edge for the floating tab. Kept out of Settings to keep the
    /// UI simple; dragging the tab updates it silently.
    var floatingTabEdge: FloatingPanelEdge {
        didSet { defaults.set(floatingTabEdge.rawValue, forKey: Keys.floatingTabEdge) }
    }
    /// Normalized position along ``floatingTabEdge``. 0 is minX/minY, 1 is
    /// maxX/maxY; geometry helpers clamp it so the tab remains visible.
    var floatingTabAnchor: Double {
        didSet { defaults.set(floatingTabAnchor, forKey: Keys.floatingTabAnchor) }
    }
    /// `CGDirectDisplayID` of the screen the tab is docked on. 0 = unset
    /// (i.e. fall back to the screen that contains the panel's current
    /// frame). Persisted so that when the panel goes from collapsed → expanded
    /// on a multi-screen setup we always reuse the right display rather than
    /// re-inferring it from the panel's near-zero-width docked frame, which
    /// happens to straddle the boundary between two screens.
    var floatingTabDisplayID: UInt32 {
        didSet { defaults.set(Int(floatingTabDisplayID), forKey: Keys.floatingTabDisplayID) }
    }
    /// Max number of session segments the collapsed floating tab shows;
    /// the same value caps how many SESSIONS rows render in the expanded
    /// list. Anything beyond `cap` is grouped into a single trailing
    /// "N+" overflow segment / row. Clamped to 3...10 on write so a
    /// hand-edited UserDefaults value can never persist outside the
    /// supported range.
    var floatingTabSegmentCap: Int {
        didSet {
            let clamped = max(3, min(10, floatingTabSegmentCap))
            if clamped != floatingTabSegmentCap {
                floatingTabSegmentCap = clamped       // re-fires didSet, persists below
                return
            }
            defaults.set(floatingTabSegmentCap, forKey: Keys.floatingTabSegmentCap)
        }
    }
    var detailPanelBoundaryFalloffEnabled: Bool {
        didSet { defaults.set(detailPanelBoundaryFalloffEnabled, forKey: Keys.detailPanelBoundaryFalloffEnabled) }
    }
    var sessionsExpandedOnAppOpen: Bool {
        didSet { defaults.set(sessionsExpandedOnAppOpen, forKey: Keys.sessionsExpandedOnAppOpen) }
    }
    var apiProviderKeyStorageMode: APIProviderKeyStorageMode {
        didSet { defaults.set(apiProviderKeyStorageMode.rawValue, forKey: Keys.apiProviderKeyStorageMode) }
    }
    /// Which platforms the user has turned on. The switcher bar only appears
    /// when this has more than one entry; otherwise the panel shows the single
    /// enabled platform (and the original scanline strip). Always non-empty.
    var enabledProviders: Set<ProviderKind> {
        didSet {
            if enabledProviders.isEmpty { enabledProviders = [.claude] }   // re-fires didSet, persists below
            defaults.set(enabledProviders.map(\.rawValue).joined(separator: ","), forKey: Keys.enabledProviders)
            if !enabledProviders.contains(selectedProvider) {
                selectedProvider = orderedEnabledProviders.first ?? .claude
            }
        }
    }
    /// The platform currently being viewed. Always a member of ``enabledProviders``.
    var selectedProvider: ProviderKind {
        didSet { defaults.set(selectedProvider.rawValue, forKey: Keys.selectedProvider) }
    }

    /// ``enabledProviders`` in canonical (``ProviderKind/allCases``) order.
    var orderedEnabledProviders: [ProviderKind] {
        ProviderKind.allCases.filter(enabledProviders.contains)
    }

    /// Opt-in to the AI activity analysis (reads macOS Screen Time; needs Full
    /// Disk Access). Off by default — the Activity tab only appears when on.
    var aiActivityAnalysisEnabled: Bool {
        didSet { defaults.set(aiActivityAnalysisEnabled, forKey: Keys.aiActivityAnalysisEnabled) }
    }
    /// Opt-in to Claude Code permission approval bubbles. When on we install
    /// hook entries into `~/.claude/settings.json` and run a local HTTP server
    /// that fields `PermissionRequest` and state events.
    var permissionApprovalEnabled: Bool {
        didSet { defaults.set(permissionApprovalEnabled, forKey: Keys.permissionApprovalEnabled) }
    }
    /// TCP port the permission server binds to on 127.0.0.1. Mirrors clawd's
    /// default (23333). User-editable in case of conflict.
    var permissionServerPort: Int {
        didSet { defaults.set(permissionServerPort, forKey: Keys.permissionServerPort) }
    }
    /// macOS system sound played when a new permission request arrives.
    /// Empty string = muted. Matches `NSSound(named:)` values like "Glass",
    /// "Submarine", "Hero", etc.
    var permissionSoundName: String {
        didSet { defaults.set(permissionSoundName, forKey: Keys.permissionSoundName) }
    }
    /// Whether Allow/Deny shortcuts work as global hotkeys (any frontmost app)
    /// or only when CCBar / the permission bubble is in focus.
    var permissionGlobalShortcutsEnabled: Bool {
        didSet { defaults.set(permissionGlobalShortcutsEnabled, forKey: Keys.permissionGlobalShortcutsEnabled) }
    }
    /// Persisted as a `KeyboardShortcutSpec` string ("cmd+option+a" etc.).
    /// Parsing lives next to the shortcut handler so Preferences stays a thin
    /// UserDefaults wrapper.
    var permissionShortcutAllow: String {
        didSet { defaults.set(permissionShortcutAllow, forKey: Keys.permissionShortcutAllow) }
    }
    var permissionShortcutDeny: String {
        didSet { defaults.set(permissionShortcutDeny, forKey: Keys.permissionShortcutDeny) }
    }
    var permissionShortcutAlways: String {
        didSet { defaults.set(permissionShortcutAlways, forKey: Keys.permissionShortcutAlways) }
    }
    /// When on, every incoming `PermissionRequest` is silently dropped so
    /// Claude Code falls back to its built-in chat approval prompt.
    var permissionDoNotDisturb: Bool {
        didSet { defaults.set(permissionDoNotDisturb, forKey: Keys.permissionDoNotDisturb) }
    }
    /// Opt-in to git tracking — adds a view that correlates Claude usage with the
    /// commit activity of the repos you've used Claude in. Off by default.
    var gitTrackingEnabled: Bool {
        didSet { defaults.set(gitTrackingEnabled, forKey: Keys.gitTrackingEnabled) }
    }
    /// When git tracking is on: `true` opens the git view in its own window
    /// (button next to the panel title); `false` shows it as a pane in the panel.
    var gitOpensInWindow: Bool {
        didSet { defaults.set(gitOpensInWindow, forKey: Keys.gitOpensInWindow) }
    }
    /// Which tree the repo language/SLOC inspector uses.
    var gitStatsScope: GitStatsScope {
        didSet { defaults.set(gitStatsScope.rawValue, forKey: Keys.gitStatsScope) }
    }
    /// Claude Status components shown on the Dashboard and monitored for
    /// optional notifications. Defaults to `claude.ai` and `Claude Code`.
    var claudeStatusVisibleComponentIDs: Set<String> {
        didSet {
            if claudeStatusVisibleComponentIDs.isEmpty {
                claudeStatusVisibleComponentIDs = ClaudeStatusComponentCatalog.defaultVisibleComponentIDs
            }
            defaults.set(claudeStatusVisibleComponentIDs.sorted().joined(separator: ","), forKey: Keys.claudeStatusVisibleComponentIDs)
        }
    }
    /// Opt-in to macOS notifications when one of the visible Claude Status
    /// components is not operational.
    var claudeStatusNotificationsEnabled: Bool {
        didSet { defaults.set(claudeStatusNotificationsEnabled, forKey: Keys.claudeStatusNotificationsEnabled) }
    }
    /// Last abnormal visible-component status notification sent. Stored so the
    /// app does not repeat the same alert across polling cycles or relaunches.
    var claudeStatusLastNotificationFingerprint: String {
        didSet { defaults.set(claudeStatusLastNotificationFingerprint, forKey: Keys.claudeStatusLastNotificationFingerprint) }
    }
    /// Extra GUI coding-surface bundle ids the user added on top of
    /// ``ActivitySurfaceCatalog/codingSurfaceDefaults``.
    var codingSurfaceBundleIDsAdded: [String] {
        didSet { defaults.set(codingSurfaceBundleIDsAdded, forKey: Keys.codingSurfaceBundleIDsAdded) }
    }
    /// Default GUI coding-surface bundle ids the user turned off.
    var codingSurfaceBundleIDsRemoved: [String] {
        didSet { defaults.set(codingSurfaceBundleIDsRemoved, forKey: Keys.codingSurfaceBundleIDsRemoved) }
    }
    /// Extra terminal/CLI-host bundle ids the user added on top of
    /// ``ActivitySurfaceCatalog/cliHostDefaults``.
    var cliHostBundleIDsAdded: [String] {
        didSet { defaults.set(cliHostBundleIDsAdded, forKey: Keys.cliHostBundleIDsAdded) }
    }
    /// Default terminal/CLI-host bundle ids the user turned off.
    var cliHostBundleIDsRemoved: [String] {
        didSet { defaults.set(cliHostBundleIDsRemoved, forKey: Keys.cliHostBundleIDsRemoved) }
    }

    /// The GUI coding-surface bundle ids actually in effect for the analysis.
    var effectiveCodingSurfaceBundleIDs: Set<String> {
        ActivitySurfaceCatalog.effectiveCodingSurfaceBundleIDs(
            added: codingSurfaceBundleIDsAdded,
            removed: codingSurfaceBundleIDsRemoved
        )
    }

    /// The CLI-host bundle ids actually in effect for the analysis.
    var effectiveCLIHostBundleIDs: Set<String> {
        ActivitySurfaceCatalog.effectiveCLIHostBundleIDs(
            added: cliHostBundleIDsAdded,
            removed: cliHostBundleIDsRemoved
        )
    }

    /// All app-focus bundle ids needed for one Screen Time query.
    var effectiveActivityBundleIDs: Set<String> {
        effectiveCodingSurfaceBundleIDs.union(effectiveCLIHostBundleIDs)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appLanguagePreference = AppLanguagePreference(rawValue: defaults.string(forKey: Keys.appLanguagePreference) ?? "") ?? .system
        autoRefreshMinutes = (defaults.object(forKey: Keys.autoRefreshMinutes) as? Int) ?? 5
        includeCacheInTokens = (defaults.object(forKey: Keys.includeCacheInTokens) as? Bool) ?? true
        costEstimationMode = CostEstimationMode(rawValue: defaults.string(forKey: Keys.costEstimationMode) ?? "") ?? .standardAPI
        menuBarItems = Preferences.loadMenuBarItems(from: defaults)
        floatingTabEnabled = (defaults.object(forKey: Keys.floatingTabEnabled) as? Bool) ?? true
        floatingTabEdge = FloatingPanelEdge(rawValue: defaults.string(forKey: Keys.floatingTabEdge) ?? "") ?? .right
        floatingTabAnchor = (defaults.object(forKey: Keys.floatingTabAnchor) as? Double) ?? 0.5
        floatingTabDisplayID = UInt32((defaults.object(forKey: Keys.floatingTabDisplayID) as? Int) ?? 0)
        let storedSegmentCap = (defaults.object(forKey: Keys.floatingTabSegmentCap) as? Int) ?? 5
        floatingTabSegmentCap = max(3, min(10, storedSegmentCap))
        detailPanelBoundaryFalloffEnabled = (defaults.object(forKey: Keys.detailPanelBoundaryFalloffEnabled) as? Bool) ?? true
        sessionsExpandedOnAppOpen = (defaults.object(forKey: Keys.sessionsExpandedOnAppOpen) as? Bool) ?? false
        apiProviderKeyStorageMode = APIProviderKeyStorageMode(rawValue: defaults.string(forKey: Keys.apiProviderKeyStorageMode) ?? "") ?? .json
        aiActivityAnalysisEnabled = defaults.bool(forKey: Keys.aiActivityAnalysisEnabled)
        permissionApprovalEnabled = defaults.bool(forKey: Keys.permissionApprovalEnabled)
        permissionServerPort = (defaults.object(forKey: Keys.permissionServerPort) as? Int) ?? 23333
        permissionSoundName = (defaults.string(forKey: Keys.permissionSoundName)) ?? "Glass"
        permissionGlobalShortcutsEnabled = defaults.bool(forKey: Keys.permissionGlobalShortcutsEnabled)
        // Defaults mirror clawd: cmd+shift+y / cmd+shift+n (Yes/No mnemonic).
        // "Always" extends them with A (only we have it; clawd doesn't).
        permissionShortcutAllow = (defaults.string(forKey: Keys.permissionShortcutAllow)) ?? "cmd+shift+y"
        permissionShortcutDeny = (defaults.string(forKey: Keys.permissionShortcutDeny)) ?? "cmd+shift+n"
        permissionShortcutAlways = (defaults.string(forKey: Keys.permissionShortcutAlways)) ?? "cmd+shift+a"
        permissionDoNotDisturb = defaults.bool(forKey: Keys.permissionDoNotDisturb)
        gitTrackingEnabled = defaults.bool(forKey: Keys.gitTrackingEnabled)
        gitOpensInWindow = defaults.bool(forKey: Keys.gitOpensInWindow)
        gitStatsScope = GitStatsScope(rawValue: defaults.string(forKey: Keys.gitStatsScope) ?? "") ?? .head
        let storedClaudeStatusComponentIDs = (defaults.string(forKey: Keys.claudeStatusVisibleComponentIDs) ?? "")
            .split(separator: ",")
            .map { String($0) }
        claudeStatusVisibleComponentIDs = storedClaudeStatusComponentIDs.isEmpty
            ? ClaudeStatusComponentCatalog.defaultVisibleComponentIDs
            : Set(storedClaudeStatusComponentIDs)
        claudeStatusNotificationsEnabled = defaults.bool(forKey: Keys.claudeStatusNotificationsEnabled)
        claudeStatusLastNotificationFingerprint = defaults.string(forKey: Keys.claudeStatusLastNotificationFingerprint) ?? ""
        let hasNewCodingSurfaceAdditions = defaults.object(forKey: Keys.codingSurfaceBundleIDsAdded) != nil
        let hasNewCodingSurfaceRemovals = defaults.object(forKey: Keys.codingSurfaceBundleIDsRemoved) != nil
        let storedCodingSurfaceBundleIDsAdded = defaults.stringArray(forKey: Keys.codingSurfaceBundleIDsAdded)
            ?? defaults.stringArray(forKey: Keys.ideBundleIDsAdded)
            ?? []
        let storedCodingSurfaceBundleIDsRemoved = defaults.stringArray(forKey: Keys.codingSurfaceBundleIDsRemoved)
            ?? defaults.stringArray(forKey: Keys.ideBundleIDsRemoved)
            ?? []
        codingSurfaceBundleIDsAdded = storedCodingSurfaceBundleIDsAdded
        codingSurfaceBundleIDsRemoved = storedCodingSurfaceBundleIDsRemoved
        cliHostBundleIDsAdded = defaults.stringArray(forKey: Keys.cliHostBundleIDsAdded) ?? []
        cliHostBundleIDsRemoved = defaults.stringArray(forKey: Keys.cliHostBundleIDsRemoved) ?? []

        if !hasNewCodingSurfaceAdditions, defaults.object(forKey: Keys.ideBundleIDsAdded) != nil {
            defaults.set(storedCodingSurfaceBundleIDsAdded, forKey: Keys.codingSurfaceBundleIDsAdded)
        }
        if !hasNewCodingSurfaceRemovals, defaults.object(forKey: Keys.ideBundleIDsRemoved) != nil {
            defaults.set(storedCodingSurfaceBundleIDsRemoved, forKey: Keys.codingSurfaceBundleIDsRemoved)
        }

        let storedEnabled = (defaults.string(forKey: Keys.enabledProviders) ?? "")
            .split(separator: ",")
            .compactMap { ProviderKind(rawValue: String($0)) }
        let enabled = storedEnabled.isEmpty ? Set([ProviderKind.claude]) : Set(storedEnabled)
        let storedSelected = ProviderKind(rawValue: defaults.string(forKey: Keys.selectedProvider) ?? "")
        let firstEnabled = ProviderKind.allCases.first(where: enabled.contains) ?? .claude

        enabledProviders = enabled
        if let s = storedSelected, enabled.contains(s) {
            selectedProvider = s
        } else {
            selectedProvider = firstEnabled
        }
        appLanguagePreference.applyToAppleLanguages(defaults: defaults)
    }

    /// Decode the stored menu-bar item list. Order of precedence:
    /// 1. New JSON-encoded `menuBarItems` key, reconciled against the
    ///    current catalog (drops removed kinds, appends new kinds disabled).
    /// 2. Legacy single-metric keys (`menuBarMetric` / `menuBarPeriod` /
    ///    `menuBarIncludesCache`) — built into a one-row catalog so a
    ///    user who upgrades sees the same metric they had before, with
    ///    everything else off.
    /// 3. ``MenuBarItem/defaultCatalog`` — fresh install.
    fileprivate static func loadMenuBarItems(from defaults: UserDefaults) -> [MenuBarItem] {
        if let json = defaults.string(forKey: Keys.menuBarItems),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([MenuBarItem].self, from: data) {
            return MenuBarItem.reconciled(stored: decoded)
        }
        if defaults.object(forKey: Keys.menuBarMetric) != nil {
            let legacyMetricRaw = defaults.string(forKey: Keys.menuBarMetric) ?? ""
            let legacyKind: MenuBarItemKind = legacyMetricRaw == "cost" ? .cost : .tokens
            let legacyPeriod = StatsPeriod(rawValue: defaults.string(forKey: Keys.menuBarPeriod) ?? "") ?? .allTime
            let legacyIncludesCache = (defaults.object(forKey: Keys.menuBarIncludesCache) as? Bool) ?? true
            var catalog = MenuBarItem.defaultCatalog.map { item -> MenuBarItem in
                var copy = item
                copy.isEnabled = false
                return copy
            }
            if let idx = catalog.firstIndex(where: { $0.kind == legacyKind }) {
                catalog[idx].isEnabled = true
                catalog[idx].period = legacyPeriod
                catalog[idx].includesCache = legacyIncludesCache
                let migrated = catalog.remove(at: idx)
                catalog.insert(migrated, at: 0)
            }
            return MenuBarItem.reconciled(stored: catalog)
        }
        return MenuBarItem.defaultCatalog
    }

    private enum Keys {
        static let appLanguagePreference = "appLanguagePreference"
        static let autoRefreshMinutes = "autoRefreshMinutes"
        static let menuBarItems = "menuBarItems"
        /// Legacy single-metric keys, read once during migration in
        /// ``loadMenuBarItems(from:)`` and then never written again.
        static let menuBarMetric = "menuBarMetric"
        static let menuBarPeriod = "menuBarPeriod"
        static let menuBarIncludesCache = "menuBarIncludesCache"
        static let includeCacheInTokens = "includeCacheInTokens"
        static let costEstimationMode = "costEstimationMode"
        static let floatingTabEnabled = "floatingTabEnabled"
        static let floatingTabEdge = "floatingTabEdge"
        static let floatingTabAnchor = "floatingTabAnchor"
        static let floatingTabDisplayID = "floatingTabDisplayID"
        static let floatingTabSegmentCap = "floatingTabSegmentCap"
        static let detailPanelBoundaryFalloffEnabled = "detailPanelBoundaryFalloffEnabled"
        static let sessionsExpandedOnAppOpen = "sessionsExpandedOnAppOpen"
        static let apiProviderKeyStorageMode = "apiProviderKeyStorageMode"
        static let aiActivityAnalysisEnabled = "aiActivityAnalysisEnabled"
        static let permissionApprovalEnabled = "permissionApprovalEnabled"
        static let permissionServerPort = "permissionServerPort"
        static let permissionSoundName = "permissionSoundName"
        static let permissionGlobalShortcutsEnabled = "permissionGlobalShortcutsEnabled"
        static let permissionShortcutAllow = "permissionShortcutAllow"
        static let permissionShortcutDeny = "permissionShortcutDeny"
        static let permissionShortcutAlways = "permissionShortcutAlways"
        static let permissionDoNotDisturb = "permissionDoNotDisturb"
        static let gitTrackingEnabled = "gitTrackingEnabled"
        static let gitOpensInWindow = "gitOpensInWindow"
        static let gitStatsScope = "gitStatsScope"
        static let codingSurfaceBundleIDsAdded = "codingSurfaceBundleIDsAdded"
        static let codingSurfaceBundleIDsRemoved = "codingSurfaceBundleIDsRemoved"
        static let cliHostBundleIDsAdded = "cliHostBundleIDsAdded"
        static let cliHostBundleIDsRemoved = "cliHostBundleIDsRemoved"
        static let ideBundleIDsAdded = "ideBundleIDsAdded"
        static let ideBundleIDsRemoved = "ideBundleIDsRemoved"
        static let enabledProviders = "enabledProviders"
        static let selectedProvider = "selectedProvider"
        static let claudeStatusVisibleComponentIDs = "claudeStatusVisibleComponentIDs"
        static let claudeStatusNotificationsEnabled = "claudeStatusNotificationsEnabled"
        static let claudeStatusLastNotificationFingerprint = "claudeStatusLastNotificationFingerprint"
    }
}
