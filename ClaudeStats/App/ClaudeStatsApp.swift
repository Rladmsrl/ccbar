import SwiftUI

@main
struct ClaudeStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .appEnvironment(appDelegate.env)
        } label: {
            MenuBarLabel()
                .appEnvironment(appDelegate.env)
                .background(FloatingStatsCommandBridge())
        }
        .menuBarExtraStyle(.window)

        Window("Share Stats", id: ShareExportView.windowID) {
            ShareExportView()
                .appEnvironment(appDelegate.env)
        }
        .windowResizability(.contentSize)

        Window("Git Activity", id: GitActivityView.windowID) {
            GitActivityView()
                .appEnvironment(appDelegate.env)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 640)
                .stxFont(13)
                .tint(.stxAccent)
        }

        Window("CCBar", id: MainWindowView.windowID) {
            MainWindowView()
                .appEnvironment(appDelegate.env)
                .frame(minWidth: 900, idealWidth: 1040, minHeight: 600, idealHeight: 720)
                .stxFont(13)
                .tint(.stxAccent)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

private extension View {
    func appEnvironment(_ env: AppEnvironment) -> some View {
        self
            .environment(env)
            .environment(\.locale, env.preferences.appLanguagePreference.locale)
    }
}
