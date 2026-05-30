import AppKit
import SwiftUI

/// Top-level page shown in the main window's detail column. Settings live in
/// their own main-window mode, not as a `MainPage`.
enum MainPage: String, CaseIterable, Identifiable, Sendable {
    case dashboard, configurations, usage, activity, git, skills
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: L10n.string("main_page.dashboard", defaultValue: "Dashboard")
        case .configurations: L10n.string("main_page.switcher", defaultValue: "Switcher")
        case .usage: L10n.string("main_page.usage", defaultValue: "Usage")
        case .activity: L10n.string("main_page.activity", defaultValue: "Activity")
        case .git: L10n.string("main_page.git", defaultValue: "Git")
        case .skills: "Skills"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .configurations: "slider.horizontal.3"
        case .usage: "chart.bar.xaxis"
        case .activity: "waveform"
        case .git: "arrow.triangle.branch"
        case .skills: "sparkles"
        }
    }

    var assetName: String? { nil }
}

extension Notification.Name {
    /// Posted by the menu-bar Settings button to ask the main window to enter
    /// settings mode (opening the window first if needed).
    static let openSettingsInMainWindow = Notification.Name("ClaudeStats.openSettingsInMainWindow")
}

/// The main app window: a vibrancy-backed sidebar with a floating rounded
/// detail "card" sitting visually above it (Codex-style shell). The window
/// holds an activation-policy reference for its lifetime so the app shows a
/// Dock icon while it's open (see ``DockVisibilityCoordinator``).
struct MainWindowView: View {
    static let windowID = "main-window"

    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SceneStorage("mainWindow.selectedPage") private var pageRaw: String = MainPage.dashboard.rawValue
    @SceneStorage("mainWindow.sidebarVisible") private var sidebarVisible: Bool = true
    @SceneStorage("mainWindow.mode") private var modeRaw: String = MainWindowMode.app.rawValue
    @SceneStorage("mainWindow.settingsSection") private var settingsSectionRaw: String = SettingsSection.general.rawValue
    @SceneStorage("mainWindow.configsSection") private var configsSectionRaw: String = AIConfigsSection.overview.rawValue
    @SceneStorage("mainWindow.configsSearch") private var configsSearchText: String = ""
    @SceneStorage("mainWindow.configsProjectID") private var configsProjectIDRaw: String = ""
    @SceneStorage("mainWindow.configsDocumentID") private var configsDocumentIDRaw: String = ""
    @State private var page: MainPage = .dashboard
    /// Held at the window level so the Sessions mode can preserve selection
    /// while the user moves in and out of the secondary sidebar.
    @State private var selectedSessionID: String?
    @State private var toggleHovering = false
    @State private var trafficLights = TrafficLightPositioner()

    private var availablePages: [MainPage] {
        var pages: [MainPage] = [.dashboard, .configurations, .usage]
        if env.preferences.aiActivityAnalysisEnabled { pages.append(.activity) }
        if env.preferences.gitTrackingEnabled { pages.append(.git) }
        pages.append(.skills)
        return pages
    }

    /// Resolves the currently selected session against the store. Returns nil
    /// if the id was set but the session has since been removed.
    private var selectedSession: Session? {
        guard let id = selectedSessionID else { return nil }
        return env.store.sessions(for: env.preferences.selectedProvider).first { $0.id == id }
    }

    private var mode: MainWindowMode {
        MainWindowMode(rawValue: modeRaw) ?? .app
    }

    private var settingsSection: SettingsSection {
        SettingsSection(rawValue: settingsSectionRaw) ?? .general
    }

    private var configsSection: AIConfigsSection {
        AIConfigsSection(rawValue: configsSectionRaw) ?? .overview
    }

private var settingsSectionBinding: Binding<SettingsSection> {
        Binding(
            get: { settingsSection },
            set: { settingsSectionRaw = $0.rawValue }
        )
    }

    private var configsSectionBinding: Binding<AIConfigsSection> {
        Binding(
            get: { configsSection },
            set: { configsSectionRaw = $0.rawValue }
        )
    }

    private var configsSearchBinding: Binding<String> {
        Binding(
            get: { configsSearchText },
            set: { configsSearchText = $0 }
        )
    }

    private var configsProjectIDBinding: Binding<String> {
        Binding(
            get: { configsProjectIDRaw },
            set: { configsProjectIDRaw = $0 }
        )
    }

    private var configsDocumentIDBinding: Binding<String> {
        Binding(
            get: { configsDocumentIDRaw },
            set: { configsDocumentIDRaw = $0 }
        )
    }

var body: some View {
        ZStack(alignment: .topLeading) {
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)

            MainWindowModeShell(
                mode: mode,
                sidebarVisible: sidebarVisible,
                boundaryFalloffEnabled: env.preferences.detailPanelBoundaryFalloffEnabled
            ) {
                SidebarColumn(
                    page: $page,
                    availablePages: availablePages,
                    onOpenSettings: openSettings,
                    onOpenSessions: openSessions,
                    onOpenConfigs: openConfigs
                )
            } sessionsSidebar: {
                SessionSidebarColumn(
                    selectedSessionID: $selectedSessionID,
                    onExit: closeSessions
                )
            } configsSidebar: {
                AIConfigsSidebarColumn(
                    section: configsSectionBinding,
                    searchText: configsSearchBinding,
                    onExit: closeConfigs
                )
            } settingsSidebar: {
                SettingsSidebarColumn(section: settingsSectionBinding, onExit: closeSettings)
            } appDetail: {
                detail
            } sessionsDetail: {
                sessionsDetail
            } configsDetail: {
                AIConfigsDetailView(
                    section: configsSection,
                    searchText: configsSearchText,
                    selectedProjectID: configsProjectIDBinding,
                    selectedDocumentID: configsDocumentIDBinding
                )
            } settingsDetail: {
                SettingsDetailView(section: settingsSection, onSelectSection: selectSettingsSection)
            }
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { clearTextFocus() }
            }

            if mode == .app || mode == .sessions || mode == .configs {
                sidebarToggle
                    .padding(.leading, 81)
                    .padding(.top, 11)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .background(WindowAccessor { window in
            trafficLights.attach(to: window)
        })
        .onAppear {
            normalizeNavigationState()
            if mode == .sessions { clearInvalidSessionSelection() }
            DockVisibilityCoordinator.shared.acquire()
            Log.app.info("Main window opened on page \(page.rawValue, privacy: .public)")
        }
        .onDisappear {
            DockVisibilityCoordinator.shared.release()
            Log.app.info("Main window closed")
        }
        .onChange(of: page) { _, new in
            guard availablePages.contains(new) else {
                page = .dashboard
                pageRaw = MainPage.dashboard.rawValue
                return
            }
            pageRaw = new.rawValue
        }
        .onChange(of: env.store.lastRefreshedAt) { _, _ in
            if mode == .sessions { clearInvalidSessionSelection() }
        }
        .onChange(of: env.preferences.selectedProvider) { _, _ in
            if mode == .sessions { selectedSessionID = nil }
        }
        .onChange(of: env.preferences.aiActivityAnalysisEnabled) { _, on in
            if !on && page == .activity { page = .dashboard }
        }
        .onChange(of: env.preferences.gitTrackingEnabled) { _, on in
            if !on && page == .git { page = .dashboard }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsInMainWindow)) { notification in
            openSettings(section: notification.object as? SettingsSection)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMainWindowDestinationFromFloatingStats)) { notification in
            guard let destination = notification.object as? FloatingStatsMainWindowDestination else { return }
            openFloatingStatsDestination(destination)
        }
    }

    // MARK: - Sidebar toggle

    private var sidebarToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { sidebarVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(toggleHovering ? .primary : Color.stxMuted)
                .frame(width: 24, height: 22)
                .background {
                    if toggleHovering {
                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { toggleHovering = $0 }
        .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .dashboard:
            DashboardView()
        case .configurations:
            ConfigurationsView()
        case .usage:
            MainUsageView()
        case .activity:
            MainActivityView()
        case .git:
            MainGitActivityView()
        case .skills:
            SkillsWorkspaceView(store: env.skills)
        }
    }

    @ViewBuilder
    private var sessionsDetail: some View {
        if let session = selectedSession {
            CenteredPaneContainer { SessionDetailView(session: session) }
        } else {
            SessionsOverviewDetailView()
        }
    }

    private func clearTextFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func openSettings() {
        openSettings(section: nil)
    }

    private func openSettings(section: SettingsSection?) {
        if let section {
            settingsSectionRaw = section.rawValue
        }
        transition(to: .settings)
    }

    private func selectSettingsSection(_ section: SettingsSection) {
        settingsSectionRaw = section.rawValue
    }

    private func openSessions() {
        selectedSessionID = nil
        transition(to: .sessions)
    }

    private func openConfigs() {
        transition(to: .configs)
    }

    private func closeSettings() {
        transition(to: .app)
    }

    private func closeSessions() {
        transition(to: .app)
    }

    private func closeConfigs() {
        transition(to: .app)
    }

    private func openFloatingStatsDestination(_ destination: FloatingStatsMainWindowDestination) {
        switch destination {
        case .page(let nextPage):
            page = availablePages.contains(nextPage) ? nextPage : .dashboard
            transition(to: .app)
        }
    }

    private func clearInvalidSessionSelection() {
        guard let id = selectedSessionID else { return }
        let sessions = env.store.sessions(for: env.preferences.selectedProvider)
        if !sessions.contains(where: { $0.id == id }) {
            selectedSessionID = nil
        }
    }

    private func transition(to nextMode: MainWindowMode) {
        clearTextFocus()
        guard mode != nextMode else { return }

        if reduceMotion {
            modeRaw = nextMode.rawValue
        } else {
            withAnimation(MainWindowMotion.modeSwitchAnimation) {
                modeRaw = nextMode.rawValue
            }
        }
    }

    private func normalizeNavigationState() {
        if MainWindowMode(rawValue: modeRaw) == nil {
            modeRaw = MainWindowMode.app.rawValue
        }

        let storedPage = MainPage(rawValue: pageRaw) ?? .dashboard
        if availablePages.contains(storedPage) {
            page = storedPage
            pageRaw = storedPage.rawValue
        } else {
            page = .dashboard
            pageRaw = MainPage.dashboard.rawValue
        }
    }
}

#if DEBUG
#Preview("Main window") {
    MainWindowView()
        .environment(AppEnvironment.preview())
        .frame(width: 1040, height: 720)
}
#endif
