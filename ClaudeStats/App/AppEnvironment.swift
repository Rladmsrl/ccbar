import Foundation
import Observation

/// Composition root. Constructs the pricing table, preferences, provider
/// registry, and the shared ``SessionStore``, then hands itself to the view
/// tree via `.environment(_:)`. Views read it with
/// `@Environment(AppEnvironment.self)`.
@MainActor
@Observable
final class AppEnvironment {
    let pricing: ModelPricing
    let preferences: Preferences
    let providerRegistry: ProviderRegistry
    let store: SessionStore
    let updater = UpdaterController()
    let floatingStatsPanel = FloatingStatsPanelController()
    /// View models live in the environment so the Settings window and the
    /// individual pages can share state — and so the VMs persist across
    /// main-window open/close cycles (reopening doesn't refire a fetch).
    let dashboard: DashboardViewModel
    let gitActivity: GitActivityViewModel
    let claudeStatus: ClaudeStatusViewModel
    let usageLimits: UsageLimitStore
    let configurationProfiles: ConfigurationProfilesViewModel
    let apiProviders: APIProviderSwitcherViewModel
    let cliEnvironment: CLIEnvironmentViewModel
    let aiConfigs: AIConfigsViewModel
    let skills: SkillsStore
    let claudeAgents = ClaudeAgentsService()
    let sessionRegistry = SessionRegistry()
    let sessionFocus = SessionFocusService()
    let permissionStore = PermissionStore()
    let permissionServer = PermissionHTTPServer()
    let permissionHookInstaller: ClaudePermissionHookInstaller
    let permissionAllowRuleWriter: ClaudeAllowRuleWriter
    let permissionGlobalShortcuts = PermissionGlobalShortcutMonitor()

    init(
        pricing: ModelPricing,
        preferences: Preferences,
        providerRegistry: ProviderRegistry,
        store: SessionStore,
        usageLimits: UsageLimitStore? = nil,
        cliEnvironment: CLIEnvironmentViewModel = CLIEnvironmentViewModel()
    ) {
        self.pricing = pricing
        self.preferences = preferences
        self.providerRegistry = providerRegistry
        self.store = store
        self.cliEnvironment = cliEnvironment
        self.dashboard = DashboardViewModel(pricing: pricing)
        self.gitActivity = GitActivityViewModel()
        self.claudeStatus = ClaudeStatusViewModel(preferences: preferences)
        self.usageLimits = usageLimits ?? UsageLimitStore(registry: providerRegistry)
        self.configurationProfiles = ConfigurationProfilesViewModel(registry: providerRegistry)
        self.apiProviders = APIProviderSwitcherViewModel()
        self.aiConfigs = AIConfigsViewModel(scanner: AIConfigScanner(registry: providerRegistry))
        self.skills = SkillsStore()
        self.permissionHookInstaller = ClaudePermissionHookInstaller()
        self.permissionAllowRuleWriter = ClaudeAllowRuleWriter()
    }

    convenience init() {
        let pricing = ModelPricing.loadDefault()
        let registry = ProviderRegistry(pricing: pricing)
        self.init(
            pricing: pricing,
            preferences: Preferences(),
            providerRegistry: registry,
            store: SessionStore(registry: registry, pricing: pricing)
        )
    }

    /// Kick off the first scan and the periodic refresh. Call once at launch.
    func start() {
        LegacyFeatureDataCleaner().cleanRemovedFeatureData()
        LaunchAtLogin.enableByDefaultIfNeeded()
        Task {
            await apiProviders.loadIfNeeded(keyStorageMode: preferences.apiProviderKeyStorageMode)
            await configurationProfiles.loadIfNeeded()
            await store.refresh()
        }
        claudeStatus.start()
        applyAutoRefreshSetting()
        usageLimits.startAutoRefresh()
        claudeAgents.sessionRegistry = sessionRegistry
        updater.start()
        floatingStatsPanel.start(environment: self)
        permissionServer.attach(store: permissionStore)
        permissionServer.attach(sessionRegistry: sessionRegistry)
        permissionStore.doNotDisturb = preferences.permissionDoNotDisturb
        permissionStore.onArrived = { [weak self] _ in
            guard let self else { return }
            PermissionSoundPlayer.play(preferences.permissionSoundName)
        }
        permissionStore.onSessionPendingChange = { [weak self] sessionId, needsInput in
            self?.sessionRegistry.markNeedsInput(sessionId, needsInput)
        }
        startPermissionServerAndStateHooks()
        applyPermissionApprovalSetting()
        applyPermissionGlobalShortcutsSetting()
    }

    /// Always-on: start the HTTP server and install only state hooks. State
    /// hooks coexist with foreign hooks (ensoai etc.) via append-merge, so
    /// this is safe to do unconditionally and gives the floating tab a way
    /// to observe session activity even when the Permission approval feature
    /// is disabled. See spec §Amendment 2026-05-26 #2.
    private func startPermissionServerAndStateHooks() {
        let port = preferences.permissionServerPort
        guard PermissionHTTPServer.isValidPort(port) else {
            Log.permission.error("Invalid permission server port: \(port)")
            return
        }
        do {
            if permissionHookInstaller.scriptNeedsUpgrade() {
                try permissionHookInstaller.upgradeScriptInPlace()
            }
            _ = try permissionHookInstaller.install(port: port, options: .stateHooks)
            try permissionServer.start(port: port)
            Log.permission.notice("State hooks installed + permission server running on port \(port)")
        } catch {
            Log.permission.error("Failed to start permission server / install state hooks: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Toggle the PermissionRequest HTTP hook (in-app bubble) on/off.
    /// Also re-syncs server + state hooks to the current port — Preferences
    /// can change either the toggle OR the port; both paths re-enter here
    /// via the Preferences observable. master 上旧版的 server.start(port:)
    /// 同步换端口的行为, 拆分后必须在此显式恢复, 否则改端口后 hook URL
    /// 指向新端口但 server 仍监听旧端口 (final code review regression)。
    /// See spec §Amendment 2026-05-26 #2.
    func applyPermissionApprovalSetting() {
        let enabled = preferences.permissionApprovalEnabled
        let port = preferences.permissionServerPort

        // Re-sync server + state hooks to current port. server.start(port:)
        // is idempotent (stop() then bind new port).
        startPermissionServerAndStateHooks()

        do {
            if enabled {
                _ = try permissionHookInstaller.install(port: port, options: .permissionHook)
                Log.permission.notice("Permission approval bubble enabled (PermissionRequest hook installed)")
            } else {
                _ = try permissionHookInstaller.uninstall(options: .permissionHook)
                Log.permission.notice("Permission approval bubble disabled (PermissionRequest hook uninstalled)")
            }
        } catch {
            Log.permission.error("Failed to apply permission approval setting: \(error.localizedDescription, privacy: .public)")
        }
    }

    func applyPermissionGlobalShortcutsSetting() {
        guard preferences.permissionApprovalEnabled, preferences.permissionGlobalShortcutsEnabled else {
            permissionGlobalShortcuts.stop()
            return
        }
        let allow = PermissionShortcutSpec.parse(preferences.permissionShortcutAllow)
        let deny = PermissionShortcutSpec.parse(preferences.permissionShortcutDeny)
        let always = PermissionShortcutSpec.parse(preferences.permissionShortcutAlways)
        permissionGlobalShortcuts.update(allow: allow, deny: deny, always: always) { [weak self] action in
            self?.handlePermissionShortcut(action)
        }
    }

    private func handlePermissionShortcut(_ action: PermissionGlobalShortcutMonitor.Action) {
        guard let request = permissionStore.pending.first else { return }
        switch action {
        case .allow:
            permissionStore.resolve(request.id, decision: .allow(message: nil))
            PermissionSoundPlayer.play(preferences.permissionSoundName)
        case .deny:
            permissionStore.resolve(request.id, decision: .deny(message: nil))
        case .always:
            if let suggestion = request.suggestions.first(where: { $0.kind == .addRules }) {
                do {
                    _ = try permissionAllowRuleWriter.apply(suggestions: [suggestion])
                    permissionStore.noteAddedAllowRule(suggestion.displayLabel)
                } catch {
                    Log.permission.error("failed to write allow rule: \(error.localizedDescription, privacy: .public)")
                    permissionStore.noteError(error.localizedDescription)
                    return
                }
            }
            permissionStore.resolve(request.id, decision: .allow(message: nil))
        }
    }

    func applyAutoRefreshSetting() {
        store.startAutoRefresh(every: TimeInterval(preferences.autoRefreshMinutes) * 60)
    }

    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        false
    }

}
