import Foundation
import Testing
@testable import ClaudeStats

@Suite("Preferences")
@MainActor
struct PreferencesTests {
    @Test("Floating tab defaults are enabled and right-docked")
    func floatingTabDefaults() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        #expect(prefs.floatingTabEnabled == true)
        #expect(prefs.floatingTabEdge == .right)
        #expect(prefs.floatingTabAnchor == 0.5)
    }

    @Test("Floating tab preferences persist")
    func floatingTabPersists() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.floatingTabEnabled = false
        prefs.floatingTabEdge = .top
        prefs.floatingTabAnchor = 0.25

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.floatingTabEnabled == false)
        #expect(reloaded.floatingTabEdge == .top)
        #expect(reloaded.floatingTabAnchor == 0.25)
    }

    @Test("Invalid stored floating edge falls back safely")
    func invalidFloatingEdgeFallsBack() {
        let defaults = makeDefaults()
        defaults.set("sideways", forKey: "floatingTabEdge")

        let prefs = Preferences(defaults: defaults)
        #expect(prefs.floatingTabEdge == .right)
    }

    @Test("Floating tab segment cap defaults to 5")
    func floatingTabSegmentCapDefault() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        #expect(prefs.floatingTabSegmentCap == 5)
    }

    @Test("Floating tab segment cap persists across reloads")
    func floatingTabSegmentCapPersists() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.floatingTabSegmentCap = 7

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.floatingTabSegmentCap == 7)
    }

    @Test("Floating tab segment cap clamps to 3...10")
    func floatingTabSegmentCapClamps() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        prefs.floatingTabSegmentCap = 1
        #expect(prefs.floatingTabSegmentCap == 3)

        prefs.floatingTabSegmentCap = 99
        #expect(prefs.floatingTabSegmentCap == 10)

        // Stored value also reflects the clamp.
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.floatingTabSegmentCap == 10)
    }

    @Test("Detail panel boundary falloff defaults to enabled")
    func detailPanelBoundaryFalloffDefault() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        #expect(prefs.detailPanelBoundaryFalloffEnabled == true)
    }

    @Test("Detail panel boundary falloff preference persists")
    func detailPanelBoundaryFalloffPersists() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.detailPanelBoundaryFalloffEnabled = false

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.detailPanelBoundaryFalloffEnabled == false)
    }

    @Test("Git language stats scope defaults to HEAD")
    func gitStatsScopeDefault() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        #expect(prefs.gitStatsScope == .head)
    }

    @Test("Git language stats scope preference persists")
    func gitStatsScopePersists() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.gitStatsScope = .workingTree

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.gitStatsScope == .workingTree)
    }

    @Test("Invalid git language stats scope falls back safely")
    func invalidGitStatsScopeFallsBack() {
        let defaults = makeDefaults()
        defaults.set("index", forKey: "gitStatsScope")

        let prefs = Preferences(defaults: defaults)
        #expect(prefs.gitStatsScope == .head)
    }

    @Test("Cost estimation mode defaults to API estimate")
    func costEstimationModeDefault() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        #expect(prefs.costEstimationMode == .standardAPI)
    }

    @Test("Cost estimation mode persists and invalid values fall back")
    func costEstimationModePersists() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.costEstimationMode = .detailedBilling

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.costEstimationMode == .detailedBilling)

        defaults.set("invoice", forKey: "costEstimationMode")
        let invalid = Preferences(defaults: defaults)
        #expect(invalid.costEstimationMode == .standardAPI)
    }

    @Test("Claude Status preferences default to visible claude.ai and Claude Code without alerts")
    func claudeStatusDefaults() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        #expect(prefs.claudeStatusVisibleComponentIDs == ClaudeStatusComponentCatalog.defaultVisibleComponentIDs)
        #expect(prefs.claudeStatusNotificationsEnabled == false)
        #expect(prefs.claudeStatusLastNotificationFingerprint == "")
    }

    @Test("Claude Status preferences persist and empty visible components fall back")
    func claudeStatusPersists() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.claudeStatusVisibleComponentIDs = [ClaudeStatusComponentCatalog.claudeAPIID]
        prefs.claudeStatusNotificationsEnabled = true
        prefs.claudeStatusLastNotificationFingerprint = "component:degraded"

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.claudeStatusVisibleComponentIDs == [ClaudeStatusComponentCatalog.claudeAPIID])
        #expect(reloaded.claudeStatusNotificationsEnabled == true)
        #expect(reloaded.claudeStatusLastNotificationFingerprint == "component:degraded")

        reloaded.claudeStatusVisibleComponentIDs = []
        #expect(reloaded.claudeStatusVisibleComponentIDs == ClaudeStatusComponentCatalog.defaultVisibleComponentIDs)
    }

    @Test("Menu-bar items default to cost + tokens enabled, in that order")
    func menuBarItemsDefault() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)

        let enabledKinds = prefs.menuBarItems.filter(\.isEnabled).map(\.kind)
        #expect(enabledKinds == [.cost, .tokens])
        #expect(prefs.menuBarItems.map(\.kind) == MenuBarItem.defaultCatalog.map(\.kind))
    }

    @Test("Menu-bar items persist as JSON")
    func menuBarItemsPersist() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.menuBarItems = [
            MenuBarItem(kind: .fiveHourPrediction, isEnabled: true),
            MenuBarItem(kind: .cost, isEnabled: true, period: .last7Days),
            MenuBarItem(kind: .tokens, isEnabled: false, period: .today, includesCache: false),
            MenuBarItem(kind: .fiveHourUsage, isEnabled: false),
            MenuBarItem(kind: .sevenDayUsage, isEnabled: false),
        ]

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.menuBarItems.map(\.kind) == [.fiveHourPrediction, .cost, .tokens, .fiveHourUsage, .sevenDayUsage])
        #expect(reloaded.menuBarItems[1].period == .last7Days)
        #expect(reloaded.menuBarItems[2].includesCache == false)
        #expect(reloaded.menuBarItems[0].isEnabled == true)
    }

    @Test("Legacy single-metric menu-bar keys migrate to a one-row catalog")
    func menuBarItemsMigrateFromLegacy() {
        let defaults = makeDefaults()
        defaults.set("cost", forKey: "menuBarMetric")
        defaults.set("last7Days", forKey: "menuBarPeriod")
        defaults.set(false, forKey: "menuBarIncludesCache")

        let prefs = Preferences(defaults: defaults)
        let enabled = prefs.menuBarItems.filter(\.isEnabled)
        #expect(enabled.count == 1)
        #expect(enabled.first?.kind == .cost)
        #expect(enabled.first?.period == .last7Days)
        // The legacy cache flag rides along, even though `.cost` doesn't read it.
        #expect(enabled.first?.includesCache == false)
        // Migrated row is first; every other kind is present but disabled.
        #expect(prefs.menuBarItems.first?.kind == .cost)
        #expect(Set(prefs.menuBarItems.map(\.kind)) == Set(MenuBarItemKind.allCases))
    }

    @Test("Reconcile drops unknown kinds and appends missing kinds disabled")
    func menuBarItemsReconcileShape() {
        let defaults = makeDefaults()
        // A stored list missing one kind and with a duplicate — reconciliation
        // should converge to one entry per kind and append the missing one.
        let stored: [MenuBarItem] = [
            MenuBarItem(kind: .cost, isEnabled: true),
            MenuBarItem(kind: .cost, isEnabled: false),
            MenuBarItem(kind: .fiveHourUsage, isEnabled: true),
            MenuBarItem(kind: .tokens, isEnabled: false),
        ]
        let json = String(data: try! JSONEncoder().encode(stored), encoding: .utf8)!
        defaults.set(json, forKey: "menuBarItems")

        let prefs = Preferences(defaults: defaults)
        let kinds = prefs.menuBarItems.map(\.kind)
        #expect(kinds.count == MenuBarItemKind.allCases.count)
        #expect(Set(kinds).count == kinds.count, "no duplicates after reconcile")
        #expect(prefs.menuBarItems.first(where: { $0.kind == .sevenDayUsage })?.isEnabled == false)
        #expect(prefs.menuBarItems.first(where: { $0.kind == .fiveHourPrediction })?.isEnabled == false)
    }

    @Test
    func menuBarItemDisplayModeDecodesAsPercentForLegacyPrefs() {
        // Legacy JSON shape stored before `displayMode` existed. Encoded
        // by hand (single MenuBarItem) — must decode to the new struct
        // with `.percent` as the default for the missing key.
        let legacyJSON = #"""
        [{"kind":"fiveHourUsage","isEnabled":true,"period":"today","includesCache":true}]
        """#.data(using: .utf8)!

        let decoded = try! JSONDecoder().decode([MenuBarItem].self, from: legacyJSON)

        #expect(decoded.count == 1)
        #expect(decoded[0].kind == .fiveHourUsage)
        #expect(decoded[0].displayMode == .percent)
    }

    @Test
    func menuBarItemDisplayModeRoundTrips() {
        let item = MenuBarItem(
            kind: .sevenDayUsage,
            isEnabled: true,
            displayMode: .remainingTime
        )
        let data = try! JSONEncoder().encode([item])
        let reloaded = try! JSONDecoder().decode([MenuBarItem].self, from: data)

        #expect(reloaded[0].displayMode == .remainingTime)
    }

    @Test("Legacy IDE bundle preferences migrate to coding surfaces")
    func legacyIDEBundlePreferencesMigrate() {
        let defaults = makeDefaults()
        defaults.set(["com.example.LegacyEditor"], forKey: "ideBundleIDsAdded")
        defaults.set(["com.apple.dt.Xcode"], forKey: "ideBundleIDsRemoved")

        let prefs = Preferences(defaults: defaults)

        #expect(prefs.codingSurfaceBundleIDsAdded == ["com.example.LegacyEditor"])
        #expect(prefs.codingSurfaceBundleIDsRemoved == ["com.apple.dt.Xcode"])
        #expect(prefs.effectiveCodingSurfaceBundleIDs.contains("com.example.LegacyEditor"))
        #expect(!prefs.effectiveCodingSurfaceBundleIDs.contains("com.apple.dt.Xcode"))
        #expect(defaults.stringArray(forKey: "codingSurfaceBundleIDsAdded") == ["com.example.LegacyEditor"])
        #expect(defaults.stringArray(forKey: "codingSurfaceBundleIDsRemoved") == ["com.apple.dt.Xcode"])
    }

    @Test("CLI host bundle preferences persist")
    func cliHostBundlePreferencesPersist() {
        let defaults = makeDefaults()
        let prefs = Preferences(defaults: defaults)
        prefs.cliHostBundleIDsAdded = ["com.example.Terminal"]
        prefs.cliHostBundleIDsRemoved = ["com.apple.Terminal"]

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.cliHostBundleIDsAdded == ["com.example.Terminal"])
        #expect(reloaded.cliHostBundleIDsRemoved == ["com.apple.Terminal"])
        #expect(reloaded.effectiveCLIHostBundleIDs.contains("com.example.Terminal"))
        #expect(!reloaded.effectiveCLIHostBundleIDs.contains("com.apple.Terminal"))
        #expect(reloaded.effectiveCLIHostBundleIDs.contains("com.mitchellh.ghostty"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.claudestats.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
