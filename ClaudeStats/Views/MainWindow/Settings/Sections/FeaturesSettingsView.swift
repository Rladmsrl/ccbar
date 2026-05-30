import SwiftUI

struct FeaturesSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var fullDiskAccessOK = ScreenTimeService.canRead()

    var onSelectSection: (SettingsSection) -> Void = { _ in }

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 12) {
            aiActivityCard(prefs: prefs)
            gitTrackingCard(prefs: prefs)
            floatingTabCard(prefs: prefs)
            permissionApprovalCard(prefs: prefs)
        }
    }

    private func permissionApprovalCard(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return FeatureControlCard(
            title: L10n.string("features.permission.title", defaultValue: "Permission Approval"),
            symbol: "shield.lefthalf.filled",
            description: L10n.string(
                "features.permission.description",
                defaultValue: "Capture Claude Code's PermissionRequest hook and answer it from a floating bubble — keyboard shortcut, optional sound, optional Telegram approval later."
            ),
            status: permissionStatusText(prefs: prefs),
            isOn: Binding(
                get: { prefs.permissionApprovalEnabled },
                set: { newValue in
                    prefs.permissionApprovalEnabled = newValue
                    env.applyPermissionApprovalSetting()
                    env.applyPermissionGlobalShortcutsSetting()
                }
            ),
            onConfigure: { onSelectSection(.approvals) }
        )
    }

    private func permissionStatusText(prefs: Preferences) -> String {
        if !prefs.permissionApprovalEnabled {
            return L10n.string("features.permission.status.off", defaultValue: "Off")
        }
        switch env.permissionServer.status {
        case .running(let port):
            return L10n.format(
                "features.permission.status.running",
                defaultValue: "Listening on 127.0.0.1:%d",
                locale: Locale(identifier: "en_US_POSIX"),
                port
            )
        case .starting:
            return L10n.string("features.permission.status.starting", defaultValue: "Starting…")
        case .failed(let reason):
            return reason
        case .stopped:
            return L10n.string("features.permission.status.stopped", defaultValue: "Server stopped")
        }
    }

    private func aiActivityCard(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return FeatureControlCard(
            title: "AI Activity Analysis",
            symbol: "waveform.path.ecg",
            description: "Compares coding apps, terminal hosts, and AI-assisted overlap using local Screen Time data.",
            status: prefs.aiActivityAnalysisEnabled ? fullDiskAccessStatus : "Hidden from Stats",
            isOn: $prefs.aiActivityAnalysisEnabled,
            onConfigure: { onSelectSection(.tracking) }
        )
    }

    private func gitTrackingCard(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return FeatureControlCard(
            title: "Git Tracking",
            symbol: "arrow.triangle.branch",
            description: "Reads local commit history for repos used with Claude and correlates code churn with sessions.",
            status: prefs.gitTrackingEnabled ? gitTrackingStatus(prefs: prefs) : "Hidden from Tools",
            isOn: $prefs.gitTrackingEnabled,
            onConfigure: { onSelectSection(.tracking) }
        )
    }

    private func floatingTabCard(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return FeatureControlCard(
            title: "Floating Edge Tab",
            symbol: "rectangle.on.rectangle",
            description: "Keeps CCBar reachable from a small screen-edge tab when the menu bar is crowded.",
            status: prefs.floatingTabEnabled ? "Docked on \(prefs.floatingTabEdge.rawValue.capitalized)" : "Off",
            isOn: $prefs.floatingTabEnabled,
            onConfigure: { onSelectSection(.floatingTab) }
        )
    }

    private var fullDiskAccessStatus: String {
        fullDiskAccessOK ? "Full Disk Access granted" : "Needs Full Disk Access"
    }

    private func gitTrackingStatus(prefs: Preferences) -> String {
        prefs.gitOpensInWindow ? "Separate window" : "Panel tab"
    }
}

#if DEBUG
#Preview {
    FeaturesSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
        .background(Color.stxBackground)
}
#endif
