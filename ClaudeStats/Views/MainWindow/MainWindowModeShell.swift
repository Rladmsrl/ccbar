import SwiftUI

enum MainWindowMode: String, Sendable {
    case app
    case sessions
    case configs
    case settings
}

enum MainWindowMotion {
    static let appSidebarWidth: CGFloat = 240
    static let sessionsSidebarWidth: CGFloat = 240
    static let configsSidebarWidth: CGFloat = 240
    static let settingsSidebarWidth: CGFloat = 220

    private static let detailOffset: CGFloat = 10

    static var modeSwitchAnimation: Animation {
        .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.28)
    }

    static var appDetailTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: -detailOffset).combined(with: .opacity),
            removal: .offset(x: -detailOffset).combined(with: .opacity)
        )
    }

    static var appSidebarTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    static var secondarySidebarTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    static var settingsDetailTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: detailOffset).combined(with: .opacity),
            removal: .offset(x: detailOffset).combined(with: .opacity)
        )
    }

    static var sessionsDetailTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: detailOffset).combined(with: .opacity),
            removal: .offset(x: detailOffset).combined(with: .opacity)
        )
    }

    static var configsDetailTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: detailOffset).combined(with: .opacity),
            removal: .offset(x: detailOffset).combined(with: .opacity)
        )
    }

}

/// Stable two-column shell for the main window. The sidebar column transitions
/// directly between app, sessions, configs, and settings navigation while the
/// detail panel stays mounted so its leading boundary can move with the
/// sidebar width.
struct MainWindowModeShell<AppSidebar: View, SessionsSidebar: View, ConfigsSidebar: View, SettingsSidebar: View, AppDetail: View, SessionsDetail: View, ConfigsDetail: View, SettingsDetail: View>: View {
    let mode: MainWindowMode
    let sidebarVisible: Bool
    let boundaryFalloffEnabled: Bool

    private let appSidebar: AppSidebar
    private let sessionsSidebar: SessionsSidebar
    private let configsSidebar: ConfigsSidebar
    private let settingsSidebar: SettingsSidebar
    private let appDetail: AppDetail
    private let sessionsDetail: SessionsDetail
    private let configsDetail: ConfigsDetail
    private let settingsDetail: SettingsDetail

    init(
        mode: MainWindowMode,
        sidebarVisible: Bool,
        boundaryFalloffEnabled: Bool,
        @ViewBuilder appSidebar: () -> AppSidebar,
        @ViewBuilder sessionsSidebar: () -> SessionsSidebar,
        @ViewBuilder configsSidebar: () -> ConfigsSidebar,
        @ViewBuilder settingsSidebar: () -> SettingsSidebar,
        @ViewBuilder appDetail: () -> AppDetail,
        @ViewBuilder sessionsDetail: () -> SessionsDetail,
        @ViewBuilder configsDetail: () -> ConfigsDetail,
        @ViewBuilder settingsDetail: () -> SettingsDetail
    ) {
        self.mode = mode
        self.sidebarVisible = sidebarVisible
        self.boundaryFalloffEnabled = boundaryFalloffEnabled
        self.appSidebar = appSidebar()
        self.sessionsSidebar = sessionsSidebar()
        self.configsSidebar = configsSidebar()
        self.settingsSidebar = settingsSidebar()
        self.appDetail = appDetail()
        self.sessionsDetail = sessionsDetail()
        self.configsDetail = configsDetail()
        self.settingsDetail = settingsDetail()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarDeck
                .frame(width: sidebarWidth, alignment: .leading)
                .clipped()

            DetailPanel(
                roundedLeading: detailRoundedLeading,
                boundaryFalloffEnabled: boundaryFalloffEnabled
            ) {
                detailContent
            }
        }
    }

    private var sidebarWidth: CGFloat {
        switch mode {
        case .app:
            sidebarVisible ? MainWindowMotion.appSidebarWidth : 0
        case .sessions:
            sidebarVisible ? MainWindowMotion.sessionsSidebarWidth : 0
        case .configs:
            sidebarVisible ? MainWindowMotion.configsSidebarWidth : 0
        case .settings:
            MainWindowMotion.settingsSidebarWidth
        }
    }

    private var detailRoundedLeading: Bool {
        switch mode {
        case .app:
            return sidebarVisible
        case .sessions:
            return sidebarVisible
        case .configs:
            return sidebarVisible
        case .settings:
            return true
        }
    }

    private var appSidebarIsActive: Bool {
        mode == .app && sidebarVisible
    }

    private var sessionsSidebarIsActive: Bool {
        mode == .sessions && sidebarVisible
    }

private var configsSidebarIsActive: Bool {
        mode == .configs && sidebarVisible
    }

    private var settingsSidebarIsActive: Bool {
        mode == .settings
    }

private var sidebarDeck: some View {
        ZStack(alignment: .leading) {
            switch mode {
            case .app:
                appSidebar
                    .frame(width: MainWindowMotion.appSidebarWidth)
                    .opacity(sidebarVisible ? 1 : 0)
                    .allowsHitTesting(appSidebarIsActive)
                    .accessibilityHidden(!appSidebarIsActive)
                    .transition(MainWindowMotion.appSidebarTransition)
            case .sessions:
                sessionsSidebar
                    .frame(width: MainWindowMotion.sessionsSidebarWidth)
                    .opacity(sidebarVisible ? 1 : 0)
                    .allowsHitTesting(sessionsSidebarIsActive)
                    .accessibilityHidden(!sessionsSidebarIsActive)
                    .transition(MainWindowMotion.secondarySidebarTransition)
            case .configs:
                configsSidebar
                    .frame(width: MainWindowMotion.configsSidebarWidth)
                    .opacity(sidebarVisible ? 1 : 0)
                    .allowsHitTesting(configsSidebarIsActive)
                    .accessibilityHidden(!configsSidebarIsActive)
                    .transition(MainWindowMotion.secondarySidebarTransition)
            case .settings:
                settingsSidebar
                    .frame(width: MainWindowMotion.settingsSidebarWidth)
                    .allowsHitTesting(settingsSidebarIsActive)
                    .accessibilityHidden(!settingsSidebarIsActive)
                    .transition(MainWindowMotion.secondarySidebarTransition)
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        ZStack {
            switch mode {
            case .app:
                appDetail
                    .transition(MainWindowMotion.appDetailTransition)
                    .zIndex(1)
            case .sessions:
                sessionsDetail
                    .transition(MainWindowMotion.sessionsDetailTransition)
                    .zIndex(1)
            case .configs:
                configsDetail
                    .transition(MainWindowMotion.configsDetailTransition)
                    .zIndex(1)
            case .settings:
                settingsDetail
                    .transition(MainWindowMotion.settingsDetailTransition)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Main window shell") {
    MainWindowModeShell(mode: .settings, sidebarVisible: true, boundaryFalloffEnabled: true) {
        VStack(alignment: .leading) {
            Text("App")
            Spacer()
            Text("Settings")
        }
        .padding()
    } sessionsSidebar: {
        VStack(alignment: .leading) {
            Text("Back")
            Text("Sessions")
            Spacer()
        }
        .padding()
    } configsSidebar: {
        VStack(alignment: .leading) {
            Text("Back")
            Text("Overview")
            Spacer()
        }
        .padding()
    } settingsSidebar: {
        VStack(alignment: .leading) {
            Text("Back")
            Text("General")
            Spacer()
        }
        .padding()
    } appDetail: {
        Color.stxBackground.overlay(Text("App Detail"))
    } sessionsDetail: {
        Color.stxBackground.overlay(Text("Sessions Detail"))
    } configsDetail: {
        Color.stxBackground.overlay(Text("Configs Detail"))
    } settingsDetail: {
        Color.stxBackground.overlay(Text("Settings Detail"))
    }
    .frame(width: 900, height: 600)
    .background(VisualEffectBackground())
}
#endif
