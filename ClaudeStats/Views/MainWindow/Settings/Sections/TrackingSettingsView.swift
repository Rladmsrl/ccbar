import SwiftUI
import AppKit

struct TrackingSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var fullDiskAccessOK = ScreenTimeService.canRead()
    @State private var newCodingSurfaceBundleID = ""
    @State private var newCLIHostBundleID = ""
    var onSelectSection: (SettingsSection) -> Void = { _ in }

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 28) {
            aiActivityGroup(prefs: prefs)
            gitTrackingGroup(prefs: prefs)
        }
    }

    // MARK: - AI activity

    @ViewBuilder
    private func aiActivityGroup(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        SettingGroup(
            title: "AI Activity Analysis",
            caption: "Adds an Activity tab that compares coding surfaces, CLI hosts, and AI activity. Reading Screen Time requires Full Disk Access."
        ) {
            if !prefs.aiActivityAnalysisEnabled {
                FeatureDisabledNotice(
                    featureName: "AI Activity Analysis",
                    message: "Turn it on in Features to edit Screen Time access and coding surface settings."
                ) {
                    onSelectSection(.features)
                }
            }

            VStack(spacing: 0) {
                fullDiskAccessRow
            }
            .settingCard()
            .disabledSettingsBlock(!prefs.aiActivityAnalysisEnabled)

            activitySurfaceListCard(prefs: prefs)
                .disabledSettingsBlock(!prefs.aiActivityAnalysisEnabled)
        }
    }

    private var fullDiskAccessRow: some View {
        SettingRow(title: "Full Disk Access",
                   description: "Required so CCBar can read the local Screen Time database.") {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(fullDiskAccessOK ? "Granted" : "Not granted"))
                    .font(.sora(12))
                    .foregroundStyle(fullDiskAccessOK ? Color.stxMuted : Color.stxAccent)
                if !fullDiskAccessOK {
                    Button("Open Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Re-check") { fullDiskAccessOK = ScreenTimeService.canRead() }
            }
        }
    }

    private func activitySurfaceListCard(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Coding surfaces")
                    .font(.sora(13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            SettingRowDivider()

            surfaceSection(
                title: "GUI coding surfaces",
                caption: "GUI coding apps plus Claude Desktop.",
                defaults: ActivitySurfaceCatalog.codingSurfaceDefaults,
                removedIDs: $prefs.codingSurfaceBundleIDsRemoved,
                addedIDs: $prefs.codingSurfaceBundleIDsAdded,
                newBundleID: $newCodingSurfaceBundleID,
                placeholder: "Add GUI bundle id"
            )

            SettingRowDivider()

            surfaceSection(
                title: "CLI hosts",
                caption: "Terminal apps shown separately from AI-assisted coding.",
                defaults: ActivitySurfaceCatalog.cliHostDefaults,
                removedIDs: $prefs.cliHostBundleIDsRemoved,
                addedIDs: $prefs.cliHostBundleIDsAdded,
                newBundleID: $newCLIHostBundleID,
                placeholder: "Add terminal bundle id"
            )
        }
        .settingCard()
    }

    private func surfaceSection(
        title: String,
        caption: String,
        defaults: [ActivitySurfaceCatalog.App],
        removedIDs: Binding<[String]>,
        addedIDs: Binding<[String]>,
        newBundleID: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.sora(12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(caption))
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ForEach(defaults) { app in
                let binding = Binding(
                    get: { !removedIDs.wrappedValue.contains(app.bundleID) },
                    set: { included in
                        if included {
                            removedIDs.wrappedValue.removeAll { $0 == app.bundleID }
                        } else if !removedIDs.wrappedValue.contains(app.bundleID) {
                            removedIDs.wrappedValue.append(app.bundleID)
                        }
                    }
                )
                surfaceRow(name: app.name, subtitle: app.bundleID, isOn: binding)
                SettingRowDivider()
            }

            ForEach(addedIDs.wrappedValue, id: \.self) { id in
                customSurfaceRow(bundleID: id) {
                    addedIDs.wrappedValue.removeAll { $0 == id }
                }
                SettingRowDivider()
            }

            HStack(spacing: 8) {
                TextField(placeholder, text: newBundleID)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let id = newBundleID.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty,
                          !addedIDs.wrappedValue.contains(id),
                          !defaults.contains(where: { $0.bundleID == id }) else { return }
                    addedIDs.wrappedValue.append(id)
                    newBundleID.wrappedValue = ""
                }
                .disabled(newBundleID.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func surfaceRow(name: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.sora(13, weight: .medium))
                Text(subtitle).font(.sora(11)).foregroundStyle(Color.stxMuted)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func customSurfaceRow(bundleID: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: bundleID).font(.sora(13, weight: .medium))
                Text("Custom").font(.sora(11)).foregroundStyle(Color.stxMuted)
            }
            Spacer()
            Button("Remove", action: remove)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Git tracking

    @ViewBuilder
    private func gitTrackingGroup(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        SettingGroup(
            title: "Git Tracking",
            caption: "Reads commit history of repos you've used Claude Code in (via the `git` command) and compares it with your Claude activity — churn, recent commits, and a usage-vs-commits timeline."
        ) {
            if !prefs.gitTrackingEnabled {
                FeatureDisabledNotice(
                    featureName: "Git Tracking",
                    message: "Turn it on in Features to edit git workspace behavior."
                ) {
                    onSelectSection(.features)
                }
            }

            VStack(spacing: 0) {
                SettingRow(title: "Open git view in") {
                    Picker("", selection: $prefs.gitOpensInWindow) {
                        Text("Panel tab").tag(false)
                        Text("Separate window").tag(true)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                SettingRowDivider()
                SettingRow(
                    title: "Language engine",
                    description: "Language detection uses GitHub Linguist; scc supplies line counts."
                ) {
                    Text("GitHub Linguist + scc")
                        .font(.sora(12, weight: .semibold))
                        .foregroundStyle(Color.stxMuted)
                }
                SettingRowDivider()
                SettingRow(
                    title: "Statistics scope",
                    description: "HEAD counts committed code; Working Tree includes local uncommitted files."
                ) {
                    Picker("", selection: $prefs.gitStatsScope) {
                        ForEach(GitStatsScope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                }
            }
            .settingCard()
            .disabledSettingsBlock(!prefs.gitTrackingEnabled)
        }
    }
}

#if DEBUG
#Preview {
    TrackingSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
}
#endif
