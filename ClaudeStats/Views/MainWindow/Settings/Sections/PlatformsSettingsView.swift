import AppKit
import SwiftUI

struct PlatformsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var shouldEnableClaudeStatusAlertsAfterSettings = false

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 28) {
            claudeStatusGroup(prefs: prefs)
        }
        .task {
            await loadStatusSettings()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { @MainActor in
                await refreshNotificationAuthorizationAfterActivation()
            }
        }
    }

    private func claudeStatusGroup(prefs: Preferences) -> some View {
        SettingGroup(
            title: "Claude Status",
            caption: "Shows selected Claude service health on the Dashboard. Alerts only monitor the components shown here."
        ) {
            VStack(spacing: 0) {
                SettingRow(
                    title: "Status alerts",
                    description: claudeStatusAlertsDescription
                ) {
                    claudeStatusAlertsControl(prefs: prefs)
                }
                SettingRowDivider()
                let components = Array(env.claudeStatus.availableComponents.enumerated())
                ForEach(components, id: \.element.id) { index, component in
                    if index > 0 { SettingRowDivider() }
                    claudeStatusComponentRow(component)
                }
            }
            .settingCard()
        }
    }

    private func claudeStatusAlertsControl(prefs: Preferences) -> some View {
        HStack(spacing: 8) {
            if env.claudeStatus.notificationPermissionDenied {
                Button("Open Settings...") {
                    shouldEnableClaudeStatusAlertsAfterSettings = true
                    openNotificationSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Toggle("", isOn: Binding(
                get: { prefs.claudeStatusNotificationsEnabled },
                set: { enabled in setClaudeStatusAlertsEnabled(enabled) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(env.claudeStatus.isRequestingNotificationAuthorization)
            .help(env.claudeStatus.notificationPermissionDenied
                ? L10n.string("platforms.notifications.help.open_settings",
                              defaultValue: "Open macOS Notifications settings to allow alerts.")
                : L10n.string("platforms.claude_status.help.enable_alerts",
                              defaultValue: "Enable Claude Status alerts."))
        }
    }

    private var claudeStatusAlertsDescription: String {
        if env.claudeStatus.isRequestingNotificationAuthorization {
            return L10n.string("platforms.notifications.waiting_permission",
                               defaultValue: "Waiting for macOS notification permission.")
        }
        if env.claudeStatus.notificationPermissionDenied {
            return L10n.string("platforms.notifications.permission_denied",
                               defaultValue: "Notification permission is denied in macOS Settings. Open Settings to allow alerts.")
        }
        return L10n.string("platforms.claude_status.alerts_description",
                           defaultValue: "Send a macOS notification when any shown Claude component is not operational.")
    }

    private func claudeStatusComponentRow(_ component: ClaudeStatusComponent) -> some View {
        let isVisible = env.claudeStatus.isComponentVisible(component)
        let canHide = env.claudeStatus.canHideComponent(component)
        return HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(component.status.settingsTint)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                    .font(.sora(13, weight: .medium))
                Text(component.status.displayName)
                    .font(.sora(11))
                    .foregroundStyle(Color.stxMuted)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { env.claudeStatus.isComponentVisible(component) },
                set: { env.claudeStatus.setComponentVisibility(component, isVisible: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isVisible && !canHide)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func loadStatusSettings() async {
        await env.claudeStatus.refreshNotificationAuthorizationStatus()
        await env.claudeStatus.refreshIfNeeded()
    }

    private func setClaudeStatusAlertsEnabled(_ enabled: Bool) {
        if !enabled {
            shouldEnableClaudeStatusAlertsAfterSettings = false
            Task { @MainActor in
                await env.claudeStatus.setNotificationsEnabled(false)
            }
            return
        }

        shouldEnableClaudeStatusAlertsAfterSettings = true
        Task { @MainActor in
            await env.claudeStatus.refreshNotificationAuthorizationStatus()

            if env.claudeStatus.notificationPermissionDenied {
                openNotificationSettings()
                return
            }

            await env.claudeStatus.setNotificationsEnabled(true)
            if env.claudeStatus.notificationAuthorization.canSendNotifications {
                shouldEnableClaudeStatusAlertsAfterSettings = false
            }
        }
    }

    private func refreshNotificationAuthorizationAfterActivation() async {
        await env.claudeStatus.refreshNotificationAuthorizationStatus()

        if shouldEnableClaudeStatusAlertsAfterSettings,
           env.claudeStatus.notificationAuthorization.canSendNotifications {
            await env.claudeStatus.setNotificationsEnabled(true)
            shouldEnableClaudeStatusAlertsAfterSettings = false
        }
    }

    private func openNotificationSettings() {
        var candidateStrings: [String] = []
        if let bundleID = Bundle.main.bundleIdentifier {
            candidateStrings.append("x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)")
        }
        candidateStrings.append("x-apple.systempreferences:com.apple.preference.notifications")
        candidateStrings.append("x-apple.systempreferences:com.apple.Notifications-Settings.extension")

        for candidate in candidateStrings {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}

#if DEBUG
#Preview {
    PlatformsSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
}
#endif

private extension ClaudeStatusSeverity {
    var settingsTint: Color {
        switch self {
        case .operational: Color.green
        case .underMaintenance: Color.blue
        case .degradedPerformance: Color.orange
        case .partialOutage, .majorOutage: Color.red
        case .unknown: Color.stxMuted
        }
    }
}
