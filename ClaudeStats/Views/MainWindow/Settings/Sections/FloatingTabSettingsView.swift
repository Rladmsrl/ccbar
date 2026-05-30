import SwiftUI

/// Settings page for the optional screen-edge floating tab. Owns the
/// on/off toggle (mirror of the Features card) and density controls.
/// Position/edge/screen are intentionally absent — those are direct-drag
/// affordances on the tab itself, see spec §Non-Goals.
struct FloatingTabSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 28) {
            SettingGroup(title: "General") {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "Show floating edge tab",
                        description: "Drag the tab itself to change edge, position, or screen."
                    ) {
                        Toggle("", isOn: $prefs.floatingTabEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .settingCard()
            }

            SettingGroup(title: "Density") {
                VStack(spacing: 0) {
                    SettingRow(
                        title: "Background grouping",
                        description: "Foreground sessions are always shown. This controls how many additional non-foreground signals stay split before extras are grouped."
                    ) {
                        // macOS 上 .labelsHidden() 会同时隐藏 Stepper 的 label
                        // 闭包内容, 所以数字得放在 Stepper 外面单独排版。
                        HStack(spacing: 8) {
                            Text("\(prefs.floatingTabSegmentCap)")
                                .font(.sora(13).monospacedDigit())
                                .frame(minWidth: 24, alignment: .trailing)
                            Stepper("Background grouping",
                                    value: $prefs.floatingTabSegmentCap,
                                    in: 3...10)
                                .labelsHidden()
                        }
                    }
                }
                .settingCard()
            }
        }
    }
}

#if DEBUG
#Preview {
    FloatingTabSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
        .background(Color.stxBackground)
}
#endif
