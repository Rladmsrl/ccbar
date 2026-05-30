import Foundation
import Observation

@MainActor
@Observable
final class UsageLimitStore {
    private(set) var reports: [ProviderKind: UsageLimitReport] = [:]
    private(set) var loadingProviders: Set<ProviderKind> = []
    private(set) var actionMessages: [ProviderKind: String] = [:]
    private(set) var claudeBridgeStatus: ClaudeUsageLimitBridgeStatus = .notInstalled
    private(set) var trendEstimates: [ProviderKind: [String: UsageLimitTrendEstimate]] = [:]
    /// Bumped on every refresh that produces a usable snapshot — gives views
    /// a stable trigger to redraw clock-relative labels without re-reading
    /// the full report.
    private(set) var lastTickAt: Date = .now

    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private let claudeBridgeInstaller: any ClaudeUsageLimitBridgeInstalling
    @ObservationIgnored private let trendStore: UsageLimitTrendStore
    @ObservationIgnored private let refreshController: UsageLimitRefreshController
    /// Rolling per-window `(timestamp, used_percent)` history used to
    /// stabilize the displayed value. Multiple concurrent Claude Code
    /// sessions each write the cache with their own session's view of
    /// `rate_limits.five_hour.used_percentage` — values can be far apart
    /// (one session may have lagging reporting). Taking the max over the
    /// last 60s gives the conservative "globally at least this much used"
    /// reading and stops the panel from flickering between session values.
    @ObservationIgnored private var stabilizationSamples: [ProviderKind: [String: [(Date, Double)]]] = [:]
    private static let stabilizationWindow: TimeInterval = 60

    init(
        registry: ProviderRegistry,
        claudeBridgeInstaller: any ClaudeUsageLimitBridgeInstalling = ClaudeUsageLimitBridgeInstaller(),
        trendStore: UsageLimitTrendStore = UsageLimitTrendStore(),
        refreshController: UsageLimitRefreshController = UsageLimitRefreshController()
    ) {
        self.registry = registry
        self.claudeBridgeInstaller = claudeBridgeInstaller
        self.trendStore = trendStore
        self.refreshController = refreshController
        self.claudeBridgeStatus = claudeBridgeInstaller.currentStatus()
    }

    func startAutoRefresh() {
        // Self-heal: if the bridge is installed with an older script that
        // doesn't max-stabilize multi-session values, silently rewrite it.
        // Settings.json isn't touched — only the script file.
        if claudeBridgeInstaller.scriptNeedsUpgrade() {
            do {
                try claudeBridgeInstaller.upgradeScriptInPlace()
                Log.usageLimit.notice("Upgraded bridge script in place")
            } catch {
                Log.usageLimit.error("Bridge script upgrade failed: \(error.localizedDescription)")
            }
        }
        refreshController.start(
            onFileChange: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshSupportedProviders(force: true)
                }
            },
            onHeartbeat: { [weak self] in
                guard let self else { return }
                self.lastTickAt = .now
                Task { @MainActor in
                    await self.refreshSupportedProviders(force: true)
                }
            }
        )
    }

    func stopAutoRefresh() {
        refreshController.stop()
    }

    func trendEstimate(for provider: ProviderKind, windowID: String) -> UsageLimitTrendEstimate? {
        trendEstimates[provider]?[windowID]
    }

    func report(for provider: ProviderKind) -> UsageLimitReport? {
        reports[provider]
    }

    func isLoading(_ provider: ProviderKind) -> Bool {
        loadingProviders.contains(provider)
    }

    func actionMessage(for provider: ProviderKind) -> String? {
        actionMessages[provider]
    }

    func refresh(provider: ProviderKind, force: Bool = false, now: Date = .now) async {
        guard provider.supportsUsageLimits else { return }
        guard force || reports[provider] == nil else { return }
        guard !loadingProviders.contains(provider) else { return }
        loadingProviders.insert(provider)
        defer { loadingProviders.remove(provider) }

        guard let source = registry.provider(for: provider) else {
            reports[provider] = .unsupported(provider: provider)
            return
        }
        let rawReport = await source.usageLimitReport(now: now)
        let stableReport = stabilize(report: rawReport, provider: provider, now: now)
        // Equatable guard — @Observable's setter fires observers unconditionally,
        // so re-assigning the same value still re-renders the whole panel and
        // makes the auto-refresh feel like a per-second flicker. Skip the write
        // when nothing actually changed.
        if reports[provider] != stableReport {
            reports[provider] = stableReport
        }
        await recordTrendIfNeeded(provider: provider, sampleReport: rawReport, displayReport: stableReport, now: now)
    }

    /// Replace each window's `usedPercent` with the maximum of the last
    /// 60 seconds of samples. Different Claude Code sessions hand the bridge
    /// different snapshots of `rate_limits.five_hour.used_percentage` (likely
    /// because each session's view of the account-wide quota lags differently
    /// after its most recent request), so the raw cache value flickers between
    /// e.g. 26% / 27% / 45% / 48% within a single second. The largest recent
    /// value is the closest the panel can get to "what the account is actually
    /// at right now" without polling the API directly.
    ///
    /// Samples are keyed by (window.id, resetAt) — `window.id` ("five_hour"
    /// 等) stays the same across resets, so without the resetAt qualifier
    /// the old window's near-100% samples would dominate the new window's
    /// fresh-0% for up to a full 60s after reset, leaving the display
    /// "stuck" at the old percentage.
    private func stabilize(report: UsageLimitReport, provider: ProviderKind, now: Date) -> UsageLimitReport {
        guard let snapshot = report.snapshot else { return report }
        var byWindow = stabilizationSamples[provider] ?? [:]
        let cutoff = now.addingTimeInterval(-Self.stabilizationWindow)
        let stabilizedWindows: [UsageLimitWindow] = snapshot.windows.map { window in
            let key = Self.stabilizationKey(for: window)
            var samples = byWindow[key] ?? []
            samples.append((now, window.usedPercent))
            samples.removeAll { $0.0 < cutoff }
            byWindow[key] = samples
            let stabilized = samples.map(\.1).max() ?? window.usedPercent
            return UsageLimitWindow(
                id: window.id,
                label: window.label,
                usedPercent: stabilized,
                resetAt: window.resetAt,
                windowMinutes: window.windowMinutes
            )
        }
        // GC stale buckets (old window's samples all expired past cutoff,
        // leaving the dict key with an empty array — without this, the
        // dict grows once per window reset forever).
        byWindow = byWindow.filter { !$0.value.isEmpty }
        stabilizationSamples[provider] = byWindow
        let stabilizedSnapshot = UsageLimitSnapshot(
            provider: snapshot.provider,
            windows: stabilizedWindows,
            capturedAt: snapshot.capturedAt,
            sourceLabel: snapshot.sourceLabel,
            sourcePath: snapshot.sourcePath,
            planType: snapshot.planType,
            limitID: snapshot.limitID
        )
        return UsageLimitReport(
            provider: report.provider,
            status: report.status,
            snapshot: stabilizedSnapshot,
            message: report.message
        )
    }

    /// Composite key keeping per-(window, resetAt) sample buckets so that
    /// a window reset (resetAt changes) doesn't carry old-window high
    /// samples into the new window's max.
    private static func stabilizationKey(for window: UsageLimitWindow) -> String {
        if let resetAt = window.resetAt {
            return "\(window.id)|\(resetAt.timeIntervalSince1970)"
        }
        return "\(window.id)|nil"
    }

    private func recordTrendIfNeeded(
        provider: ProviderKind,
        sampleReport: UsageLimitReport,
        displayReport: UsageLimitReport,
        now: Date
    ) async {
        guard let sampleSnapshot = sampleReport.snapshot,
              sampleReport.status == .fresh || sampleReport.status == .waitingForNextResponse
        else {
            if trendEstimates[provider]?.isEmpty == false {
                trendEstimates[provider] = [:]
            }
            return
        }
        // We only predict for the 5h window — the 7d window's burn rate is
        // dominated by long idle stretches and a least-squares slope over a
        // 30-minute history wouldn't tell you anything useful about whether
        // you'll exhaust 7d quota days from now. Skip recording for non-5h
        // windows entirely.
        let sampleWindows = sampleSnapshot.windows.filter { Self.predictsExhaust(windowID: $0.id) }
        if !sampleWindows.isEmpty {
            let predictionOnlySnapshot = UsageLimitSnapshot(
                provider: sampleSnapshot.provider,
                windows: sampleWindows,
                capturedAt: sampleSnapshot.capturedAt,
                sourceLabel: sampleSnapshot.sourceLabel,
                sourcePath: sampleSnapshot.sourcePath,
                planType: sampleSnapshot.planType,
                limitID: sampleSnapshot.limitID
            )
            await trendStore.record(snapshot: predictionOnlySnapshot, at: now)
        }
        var perWindow: [String: UsageLimitTrendEstimate] = [:]
        let displayWindows = displayReport.snapshot?.windows.filter { Self.predictsExhaust(windowID: $0.id) } ?? sampleWindows
        for window in displayWindows {
            if let estimate = await trendStore.estimate(provider: provider, window: window, now: now) {
                perWindow[window.id] = estimate
            }
        }
        if trendEstimates[provider] != perWindow {
            trendEstimates[provider] = perWindow
        }
    }

    /// Windows we extrapolate burn rate for. Anything not in this set never
    /// gets a "Sampling…" placeholder either — it just doesn't show a hint.
    static func predictsExhaust(windowID: String) -> Bool {
        windowID == "five_hour"
    }

    func refreshSupportedProviders(force: Bool = false, now: Date = .now) async {
        for provider in ProviderKind.allCases where provider.supportsUsageLimits {
            await refresh(provider: provider, force: force, now: now)
        }
    }

    func installClaudeBridge() {
        do {
            let configuration = try claudeBridgeInstaller.install()
            actionMessages[.claude] = L10n.format(
                "usage.limit.bridge.action.manual_installed",
                defaultValue: "Bridge installed. Paste the settings snippet into %@.",
                configuration.settingsURL.path
            )
        } catch {
            actionMessages[.claude] = L10n.format(
                "usage.limit.bridge.action.install_failed",
                defaultValue: "Could not install bridge: %@",
                error.localizedDescription
            )
        }
    }

    /// One-click install: writes the bridge script (chaining any existing
    /// statusLine downstream) and merges the statusLine block into the
    /// user's settings.json. Backs up the file first; safely reversible
    /// via ``uninstallClaudeBridgeAuto()``.
    func installClaudeBridgeAuto() {
        do {
            let result = try claudeBridgeInstaller.installAuto()
            claudeBridgeStatus = claudeBridgeInstaller.currentStatus()
            if let downstream = result.preservedDownstreamCommand, !downstream.isEmpty {
                actionMessages[.claude] = L10n.format(
                    "usage.limit.bridge.action.auto_installed_chained",
                    defaultValue: "Usage limit tracking enabled. Your existing status line (%@) is preserved as downstream.",
                    downstream
                )
            } else {
                actionMessages[.claude] = L10n.string(
                    "usage.limit.bridge.action.auto_installed",
                    defaultValue: "Usage limit tracking enabled."
                )
            }
        } catch {
            actionMessages[.claude] = L10n.format(
                "usage.limit.bridge.action.install_failed",
                defaultValue: "Could not install bridge: %@",
                error.localizedDescription
            )
        }
    }

    func uninstallClaudeBridgeAuto() {
        do {
            _ = try claudeBridgeInstaller.uninstall()
            claudeBridgeStatus = claudeBridgeInstaller.currentStatus()
            actionMessages[.claude] = L10n.string(
                "usage.limit.bridge.action.uninstalled",
                defaultValue: "Usage limit tracking removed. Your previous status line was restored."
            )
        } catch {
            actionMessages[.claude] = L10n.format(
                "usage.limit.bridge.action.uninstall_failed",
                defaultValue: "Could not uninstall bridge: %@",
                error.localizedDescription
            )
        }
    }

    func refreshClaudeBridgeStatus() {
        claudeBridgeStatus = claudeBridgeInstaller.currentStatus()
    }

    func claudeSettingsSnippet() -> String {
        claudeBridgeInstaller.settingsSnippet()
    }

    func claudeSettingsURL() -> URL {
        claudeBridgeInstaller.settingsURL
    }

    func recordActionMessage(_ message: String, for provider: ProviderKind) {
        actionMessages[provider] = message
    }
}
