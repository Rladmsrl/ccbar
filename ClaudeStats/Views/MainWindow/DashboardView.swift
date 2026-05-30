import SwiftUI

/// Overview Dashboard: 8 all-provider stat cards (4×2) scoped by an
/// "All / 30d / 7d" range, then the 3-month AI activity heatmap, and a
/// humorous comparison footer. The "Models" tab swaps the stat grid for a
/// per-model breakdown table.
struct DashboardView: View {
    @Environment(AppEnvironment.self) private var env

    @SceneStorage("dashboard.section") private var sectionRaw: String = DashboardViewModel.Section.overview.rawValue
    @SceneStorage("dashboard.period") private var periodRaw: String = StatsPeriod.last30Days.rawValue

    private var vm: DashboardViewModel { env.dashboard }

    private struct DashboardReloadKey: Equatable {
        let period: StatsPeriod
        let lastRefresh: Date?
        let token: UInt64
    }

    var body: some View {
        let heatmapRange = vm.heatmapInterval()

        AppScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                Group {
                    switch vm.section {
                    case .overview: overviewBody(heatmapRange: heatmapRange)
                    case .models: modelsBody()
                    }
                }
                Spacer(minLength: 0)
            }
            // Horizontal padding trimmed (28 → 20) so the 4-column stat grid
            // fits inside the detail panel at the window's minimum width.
            .padding(.horizontal, 20)
            .padding(.top, 52)
            .padding(.bottom, 22)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { syncFromSceneStorage() }
        .onChange(of: vm.section) { _, new in sectionRaw = new.rawValue }
        .onChange(of: vm.period) { _, new in periodRaw = new.rawValue }
        .task(id: dashboardReloadKey) {
            await vm.reload(sessions: env.store.sessions)
        }
    }

    private var dashboardReloadKey: DashboardReloadKey {
        DashboardReloadKey(
            period: vm.period,
            lastRefresh: env.store.lastRefreshedAt,
            token: vm.reloadToken
        )
    }

    private func syncFromSceneStorage() {
        if let s = DashboardViewModel.Section(rawValue: sectionRaw) { vm.section = s }
        if let p = StatsPeriod(rawValue: periodRaw),
           RangeChips.supported.contains(p) {
            vm.period = p
        }
    }

    // MARK: - Header & controls

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DASHBOARD")
                .font(.sora(11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.stxMuted)
            Text("Coding activity")
                .font(.sora(24, weight: .semibold))
            Text("Your AI coding sessions, day by day.")
                .font(.sora(12))
                .foregroundStyle(Color.stxMuted)
        }
    }

    private var controls: some View {
        @Bindable var bvm = vm
        return HStack(alignment: .center, spacing: 12) {
            OverviewTabs(section: $bvm.section)
            Spacer()
            RangeChips(period: $bvm.period)
        }
    }

    // MARK: - Overview body

    private func overviewBody(heatmapRange: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            statsGrid
            statusCard
            aiHeatmapSection(range: heatmapRange)
            ComparisonFooter(totalTokens: vm.stats.totalTokens)
        }
    }

    /// Eight stat cards in a 4×2 manual `Grid`. Hard-coded to four columns so
    /// the value baselines line up across both rows — `LazyVGrid` would
    /// reflow them and lose that alignment.
    private var statsGrid: some View {
        let s = vm.stats
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                StatCard(label: L10n.string("dashboard.stat.sessions", defaultValue: "SESSIONS"), value: "\(s.sessions)")
                StatCard(label: L10n.string("dashboard.stat.messages", defaultValue: "MESSAGES"), value: Format.tokens(s.messages))
                StatCard(label: L10n.string("dashboard.stat.total_tokens", defaultValue: "TOTAL TOKENS"), value: Format.tokens(s.totalTokens))
                StatCard(label: L10n.string("dashboard.stat.active_days", defaultValue: "ACTIVE DAYS"), value: "\(s.activeDays)")
            }
            GridRow {
                StatCard(label: L10n.string("dashboard.stat.current_streak", defaultValue: "CURRENT STREAK"), value: "\(s.currentStreak)d")
                StatCard(label: L10n.string("dashboard.stat.longest_streak", defaultValue: "LONGEST STREAK"), value: "\(s.longestStreak)d")
                StatCard(label: L10n.string("dashboard.stat.peak_hour", defaultValue: "PEAK HOUR"), value: peakHourLabel(s.peakHour), animatesNumericValue: false)
                StatCard(label: L10n.string("dashboard.stat.favorite_model", defaultValue: "FAVORITE MODEL"), value: favoriteModelLabel(s.favoriteModel), animatesNumericValue: false)
            }
        }
    }

    private var statusCard: some View {
        ClaudeStatusCard(status: env.claudeStatus)
    }

    // MARK: - AI heatmap

    private func aiHeatmapSection(range: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heatmapHeader(
                title: L10n.string("dashboard.heatmap.ai_activity", defaultValue: "AI ACTIVITY"),
                subtitle: L10n.format("dashboard.heatmap.active_days_last_3_months",
                                      defaultValue: "%@ · last 3 months",
                                      L10n.activeDays(vm.heatmapActiveDays))
            )
            CompactHeatmap(
                cells: vm.heatmapCells,
                range: range,
                valueLabel: {
                    L10n.format("dashboard.heatmap.tokens_value",
                                defaultValue: "%@ tokens",
                                Format.tokens($0))
                }
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func heatmapHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.sora(9, weight: .medium)).tracking(0.4)
                .foregroundStyle(Color.stxMuted)
            Spacer()
            Text(subtitle)
                .font(.sora(9))
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
        }
    }

    // MARK: - Models body

    private func modelsBody() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelsTrendChart(
                series: vm.modelTrend,
                seriesID: vm.modelTrend.dataRevisionID,
                includeCacheInTotals: env.preferences.includeCacheInTokens,
                displayName: modelDisplayName
            )
            DashboardModelTable(
                models: vm.modelBreakdown,
                includeCacheInTotals: env.preferences.includeCacheInTokens,
                displayName: dashboardModelDisplayName
            )
        }
    }

    /// Pretty label for a provider-qualified Dashboard model id.
    private func modelDisplayName(_ id: String) -> String {
        guard let key = DashboardModelKey(id: id) else { return id }
        return dashboardModelDisplayName(key)
    }

    private func dashboardModelDisplayName(_ key: DashboardModelKey) -> String {
        "\(key.provider.shortName) - \(env.store.displayName(forModel: key.model, provider: key.provider))"
    }

    // MARK: - Stat-card formatting helpers

    /// `"5 PM"` for hour 17 in the current locale. Returns "—" when no
    /// activity has been recorded yet.
    private func peakHourLabel(_ hour: Int?) -> String {
        guard let hour,
              let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)
        else { return "—" }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    /// Pretty display name for the favorite-model stat card.
    private func favoriteModelLabel(_ model: DashboardModelKey?) -> String {
        guard let model, !model.model.isEmpty else { return "—" }
        return dashboardModelDisplayName(model)
    }
}

#if DEBUG
#Preview("Dashboard") {
    DashboardView()
        .environment(AppEnvironment.preview())
        .frame(width: 1040, height: 720)
        .background(Color.stxBackground)
}
#endif
