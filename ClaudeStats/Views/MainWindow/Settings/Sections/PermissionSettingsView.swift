import SwiftUI

struct PermissionSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var portText: String = ""
    @State private var portError: String?

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 28) {
            if !prefs.permissionApprovalEnabled {
                FeatureDisabledNotice(
                    featureName: L10n.string("features.permission.title", defaultValue: "Permission Approval"),
                    message: L10n.string(
                        "permission.settings.disabled_notice",
                        defaultValue: "Turn on Permission Approval in Features to install the hook and enable the server."
                    ),
                    onOpenFeatures: { /* navigation handled by sidebar */ }
                )
            }

            serverGroup(prefs: prefs)
            soundGroup(prefs: prefs)
            shortcutGroup(prefs: prefs)
            advancedGroup(prefs: prefs)
        }
        .onAppear {
            portText = String(prefs.permissionServerPort)
        }
    }

    // MARK: - Server

    private func serverGroup(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return SettingGroup(title: L10n.string("permission.settings.server.title", defaultValue: "Server")) {
            VStack(spacing: 0) {
                SettingRow(
                    title: L10n.string("permission.settings.server.port", defaultValue: "Port"),
                    description: L10n.string(
                        "permission.settings.server.port.description",
                        defaultValue: "Localhost TCP port the hook script POSTs to. Default 23333 matches clawd."
                    )
                ) {
                    HStack(spacing: 6) {
                        TextField("", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                            .onSubmit { applyPort(prefs: prefs) }
                        Button(L10n.string("permission.settings.server.apply", defaultValue: "Apply")) {
                            applyPort(prefs: prefs)
                        }
                        .controlSize(.small)
                    }
                }
                SettingRowDivider()
                SettingRow(
                    title: L10n.string("permission.settings.server.status", defaultValue: "Status"),
                    description: serverStatusDescription()
                ) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 8, height: 8)
                }
                if let portError {
                    SettingRowDivider()
                    Text(portError)
                        .font(.sora(11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                SettingRowDivider()
                SettingRow(
                    title: L10n.string("permission.settings.server.events", defaultValue: "State events received"),
                    description: L10n.format(
                        "permission.settings.server.events.detail",
                        defaultValue: "%d state · %d permission",
                        env.permissionServer.stateEventsReceived,
                        env.permissionServer.permissionRequestsHandled
                    )
                ) {
                    EmptyView()
                }
            }
            .settingCard()
        }
    }

    private var statusTint: Color {
        switch env.permissionServer.status {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return Color.stxMuted
        case .failed: return .red
        }
    }

    private func serverStatusDescription() -> String {
        switch env.permissionServer.status {
        case .stopped:
            return L10n.string("permission.settings.server.status.stopped", defaultValue: "Stopped")
        case .starting(let port):
            return L10n.format(
                "permission.settings.server.status.starting",
                defaultValue: "Starting on port %d…",
                locale: Locale(identifier: "en_US_POSIX"),
                port
            )
        case .running(let port):
            return L10n.format(
                "permission.settings.server.status.running",
                defaultValue: "Listening on 127.0.0.1:%d",
                locale: Locale(identifier: "en_US_POSIX"),
                port
            )
        case .failed(let reason):
            return reason
        }
    }

    private func applyPort(prefs: Preferences) {
        guard let value = Int(portText), value >= 1024, value <= 65535 else {
            portError = L10n.string(
                "permission.settings.server.port.invalid",
                defaultValue: "Port must be between 1024 and 65535."
            )
            return
        }
        portError = nil
        prefs.permissionServerPort = value
        if prefs.permissionApprovalEnabled {
            env.applyPermissionApprovalSetting()
        }
    }

    // MARK: - Sound

    private func soundGroup(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return SettingGroup(title: L10n.string("permission.settings.sound.title", defaultValue: "Sound")) {
            VStack(spacing: 0) {
                SettingRow(
                    title: L10n.string("permission.settings.sound.alert", defaultValue: "Alert sound"),
                    description: L10n.string(
                        "permission.settings.sound.alert.description",
                        defaultValue: "Plays each time a new permission request arrives."
                    )
                ) {
                    HStack(spacing: 6) {
                        Picker("", selection: $prefs.permissionSoundName) {
                            Text(L10n.string("permission.settings.sound.none", defaultValue: "None"))
                                .tag("")
                            ForEach(PermissionSoundPlayer.availableSoundNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 140)
                        Button(L10n.string("permission.settings.sound.preview", defaultValue: "Try")) {
                            PermissionSoundPlayer.play(prefs.permissionSoundName)
                        }
                        .controlSize(.small)
                        .disabled(prefs.permissionSoundName.isEmpty)
                    }
                }
            }
            .settingCard()
        }
    }

    // MARK: - Shortcuts

    private func shortcutGroup(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return SettingGroup(title: L10n.string("permission.settings.shortcuts.title", defaultValue: "Keyboard shortcuts")) {
            VStack(spacing: 0) {
                shortcutRow(
                    title: L10n.string("permission.settings.shortcuts.allow", defaultValue: "Allow"),
                    binding: $prefs.permissionShortcutAllow
                )
                SettingRowDivider()
                shortcutRow(
                    title: L10n.string("permission.settings.shortcuts.deny", defaultValue: "Deny"),
                    binding: $prefs.permissionShortcutDeny
                )
                SettingRowDivider()
                shortcutRow(
                    title: L10n.string("permission.settings.shortcuts.always", defaultValue: "Always allow"),
                    binding: $prefs.permissionShortcutAlways
                )
                SettingRowDivider()
                SettingRow(
                    title: L10n.string("permission.settings.shortcuts.global", defaultValue: "Global hotkeys"),
                    description: L10n.string(
                        "permission.settings.shortcuts.global.description",
                        defaultValue: "Respond from any frontmost app. Off = shortcuts only work when CCBar is in focus."
                    )
                ) {
                    Toggle("", isOn: Binding(
                        get: { prefs.permissionGlobalShortcutsEnabled },
                        set: { newValue in
                            prefs.permissionGlobalShortcutsEnabled = newValue
                            env.applyPermissionGlobalShortcutsSetting()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingRowDivider()
                HStack {
                    Spacer()
                    Button(L10n.string(
                        "permission.settings.shortcuts.reset",
                        defaultValue: "Reset to clawd defaults"
                    )) {
                        prefs.permissionShortcutAllow = "cmd+shift+y"
                        prefs.permissionShortcutDeny = "cmd+shift+n"
                        prefs.permissionShortcutAlways = "cmd+shift+a"
                        env.applyPermissionGlobalShortcutsSetting()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .settingCard()
        }
    }

    @ViewBuilder
    private func shortcutRow(title: String, binding: Binding<String>) -> some View {
        SettingRow(title: title, description: shortcutPreview(binding.wrappedValue)) {
            ShortcutRecorderField(spec: Binding(
                get: { binding.wrappedValue },
                set: { newValue in
                    binding.wrappedValue = newValue
                    env.applyPermissionGlobalShortcutsSetting()
                }
            ))
        }
    }

    private func shortcutPreview(_ value: String) -> String {
        if value.isEmpty {
            return L10n.string(
                "permission.settings.shortcuts.empty",
                defaultValue: "Click the button on the right and press the keys you want."
            )
        }
        if PermissionShortcutSpec.parse(value) != nil {
            return L10n.string(
                "permission.settings.shortcuts.set_hint",
                defaultValue: "Click to re-record, or press the × to clear."
            )
        }
        return L10n.string(
            "permission.settings.shortcuts.invalid",
            defaultValue: "Unrecognized — click the button and press a new combo."
        )
    }

    // MARK: - Advanced

    private func advancedGroup(prefs: Preferences) -> some View {
        @Bindable var prefs = prefs
        return SettingGroup(title: L10n.string("permission.settings.advanced.title", defaultValue: "Advanced")) {
            VStack(spacing: 0) {
                SettingRow(
                    title: L10n.string("permission.settings.advanced.dnd", defaultValue: "Do Not Disturb"),
                    description: L10n.string(
                        "permission.settings.advanced.dnd.description",
                        defaultValue: "Drop every incoming PermissionRequest so Claude Code falls back to its built-in in-chat prompt."
                    )
                ) {
                    Toggle("", isOn: Binding(
                        get: { prefs.permissionDoNotDisturb },
                        set: { newValue in
                            prefs.permissionDoNotDisturb = newValue
                            env.permissionStore.doNotDisturb = newValue
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingRowDivider()
                SettingRow(
                    title: L10n.string("permission.settings.advanced.passthrough", defaultValue: "Auto-allowed tools"),
                    description: env.permissionStore.passthroughTools.sorted().joined(separator: ", ")
                ) {
                    EmptyView()
                }
            }
            .settingCard()
        }
    }
}

#if DEBUG
#Preview {
    PermissionSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720, height: 700)
        .background(Color.stxBackground)
}
#endif
