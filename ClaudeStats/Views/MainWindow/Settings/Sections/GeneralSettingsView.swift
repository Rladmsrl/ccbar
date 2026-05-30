import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var languageRestartNoticeVisible = false

    private static let refreshOptions = [1, 2, 5, 10, 15, 30, 60]

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 28) {
            SettingGroup(title: "Startup") {
                VStack(spacing: 0) {
                    SettingRow(title: "Launch at login",
                               description: "Open CCBar automatically when you log in to your Mac.") {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .onChange(of: launchAtLogin) { _, newValue in LaunchAtLogin.setEnabled(newValue) }
                }
                .settingCard()
            }

            SettingGroup(title: "Language") {
                VStack(spacing: 0) {
                    SettingRow(title: "App language",
                               description: "Choose the language CCBar uses after the next restart.") {
                        Picker("", selection: $prefs.appLanguagePreference) {
                            ForEach(AppLanguagePreference.allCases) { language in
                                Text(language.displayName()).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                    }
                    .onChange(of: prefs.appLanguagePreference) { _, _ in
                        languageRestartNoticeVisible = true
                    }
                    if languageRestartNoticeVisible {
                        SettingRowDivider()
                        Text(L10n.restartLanguageNotice())
                            .font(.sora(11))
                            .foregroundStyle(Color.stxAccent)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
                .settingCard()
            }

            SettingGroup(title: "Refresh") {
                VStack(spacing: 0) {
                    SettingRow(title: "Refresh every",
                               description: "How often CCBar re-scans your session logs in the background.") {
                        Picker("", selection: $prefs.autoRefreshMinutes) {
                            ForEach(Self.refreshOptions, id: \.self) { minutes in
                                Text(L10n.refreshInterval(minutes: minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    .onChange(of: prefs.autoRefreshMinutes) { _, _ in env.applyAutoRefreshSetting() }
                }
                .settingCard()
            }

            SettingGroup(title: "Behavior") {
                VStack(spacing: 0) {
                    SettingRow(title: "Detail edge fade",
                               description: "Blend the main detail pane into the sidebar with a soft boundary fade.") {
                        Toggle("", isOn: $prefs.detailPanelBoundaryFalloffEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingRowDivider()
                    SettingRow(title: "Include cache reads in token counts",
                               description: "Anthropic's API re-reports the cached context on every assistant turn, so the same tokens get counted many times. Turn off to show only \u{201C}new\u{201D} traffic (input + output + cache writes). Estimated cost is unaffected.") {
                        Toggle("", isOn: $prefs.includeCacheInTokens)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingRowDivider()
                    SettingRow(title: "Cost mode",
                               description: "API estimate uses standard first-party token prices. Detailed billing also applies fast mode and web search charges when Claude logs expose them.") {
                        Picker("", selection: $prefs.costEstimationMode) {
                            ForEach(CostEstimationMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 170)
                    }
                    SettingRowDivider()
                    SettingRow(title: "API key storage",
                               description: "Where API Provider Switcher saves provider keys. JSON keeps them with provider data; Keychain stores references in the library.") {
                        Picker("", selection: $prefs.apiProviderKeyStorageMode) {
                            ForEach(APIProviderKeyStorageMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 150)
                    }
                }
                .settingCard()
            }
        }
    }
}

#if DEBUG
#Preview {
    GeneralSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
}
#endif
