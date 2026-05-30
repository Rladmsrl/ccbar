import SwiftUI

/// Right-side content for main-window settings mode. The surrounding
/// `MainWindowModeShell` owns the sidebar and `DetailPanel` chrome.
struct SettingsDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let section: SettingsSection
    var onSelectSection: (SettingsSection) -> Void = { _ in }

    var body: some View {
        AppScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text(section.title)
                    .font(.sora(28, weight: .semibold))
                    .padding(.bottom, 4)
                sectionContent
            }
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 52)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .general: GeneralSettingsView()
        case .features: FeaturesSettingsView(onSelectSection: onSelectSection)
        case .menuBar: MenuBarSettingsView()
        case .floatingTab: FloatingTabSettingsView()
        case .platforms: PlatformsSettingsView()
        case .tracking: TrackingSettingsView(onSelectSection: onSelectSection)
        case .approvals: PermissionSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

#if DEBUG
#Preview("Settings detail") {
    SettingsDetailView(section: .general)
        .environment(AppEnvironment.preview())
        .frame(width: 820, height: 600)
        .background(Color.stxBackground)
}
#endif
