import SwiftUI
import AppKit

struct AboutSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingGroup(title: "Data") {
                VStack(spacing: 0) {
                    SettingRow(title: "Claude config directory",
                               description: ClaudePaths.default.configDirectory.path) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([ClaudePaths.default.configDirectory])
                        }
                    }
                }
                .settingCard()
            }

            SettingGroup(title: "About") {
                VStack(spacing: 0) {
                    SettingRow(title: "Version",
                               description: appVersionString) {
                        Button("Check for Updates…") { env.updater.checkForUpdates() }
                    }
                }
                .settingCard()
            }
        }
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

#if DEBUG
#Preview {
    AboutSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
}
#endif
