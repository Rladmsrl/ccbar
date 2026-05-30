import SwiftUI

struct MenuBarSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    /// `nil` while no drag is in flight. When a row is hovered as a drop
    /// target we use this to draw an insertion indicator above it.
    @State private var dropTargetID: MenuBarItemKind?

    var body: some View {
        @Bindable var prefs = env.preferences

        VStack(alignment: .leading, spacing: 28) {
            SettingGroup(
                title: "Preview",
                caption: "How the status item will look. Updates live as you toggle and rearrange below."
            ) {
                MenuBarPreviewStrip()
                    .settingCard()
            }

            SettingGroup(
                title: "Components",
                caption: "Drag rows to reorder. Enabled rows show left-to-right in the menu bar."
            ) {
                VStack(spacing: 0) {
                    ForEach($prefs.menuBarItems) { $item in
                        MenuBarItemRow(item: $item, dropTargetID: dropTargetID)
                            .draggable(MenuBarItemDragPayload(kind: item.kind)) {
                                MenuBarItemDragPreview(item: item)
                            }
                            .dropDestination(for: MenuBarItemDragPayload.self) { payloads, _ in
                                handleDrop(payloads, before: item.kind, in: &prefs.menuBarItems)
                            } isTargeted: { isTargeted in
                                dropTargetID = isTargeted ? item.kind : (dropTargetID == item.kind ? nil : dropTargetID)
                            }
                        if item.kind != prefs.menuBarItems.last?.kind {
                            SettingRowDivider()
                        }
                    }
                }
                .settingCard()
            }
        }
    }

    private func handleDrop(_ payloads: [MenuBarItemDragPayload],
                            before targetKind: MenuBarItemKind,
                            in items: inout [MenuBarItem]) -> Bool {
        defer { dropTargetID = nil }
        guard let source = payloads.first?.kind,
              source != targetKind,
              let sourceIdx = items.firstIndex(where: { $0.kind == source }),
              let targetIdx = items.firstIndex(where: { $0.kind == targetKind })
        else { return false }
        // `move(fromOffsets:toOffset:)` treats `toOffset` as the index in the
        // pre-move array — moving down requires adding 1, moving up uses the
        // target index as-is.
        let destination = sourceIdx < targetIdx ? targetIdx + 1 : targetIdx
        items.move(fromOffsets: IndexSet(integer: sourceIdx), toOffset: destination)
        return true
    }
}

// MARK: - Row

private struct MenuBarItemRow: View {
    @Binding var item: MenuBarItem
    let dropTargetID: MenuBarItemKind?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.stxMuted)
                .frame(width: 16, height: 16)
                .help("Drag to reorder")

            Image(systemName: item.kind.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(item.isEnabled ? Color.stxAccent : Color.stxMuted)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(item.kind.displayName))
                    .font(.sora(13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(item.kind.caption))
                    .font(.sora(11))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if item.kind.supportsPeriod {
                Picker("", selection: $item.period) {
                    ForEach(StatsPeriod.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.4)
            }

            if item.kind.supportsUsageDisplayMode {
                Picker("", selection: $item.displayMode) {
                    // First option's label is the window-length itself
                    // (e.g. "5H" / "7D"), making it obvious that picking
                    // this mode yields a `5h 42%` style prefix.
                    Text(item.kind == .sevenDayUsage ? "7D" : "5H")
                        .tag(UsageDisplayMode.percent)
                    Text(L10n.string("menu_bar.row.display_mode.remaining_time",
                                     defaultValue: "Remaining time"))
                        .tag(UsageDisplayMode.remainingTime)
                    Text(L10n.string("menu_bar.row.display_mode.reset_time",
                                     defaultValue: "Reset time"))
                        .tag(UsageDisplayMode.resetTime)
                }
                .labelsHidden()
                .frame(width: 130)
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.4)
            }

            if item.kind.supportsCacheToggle {
                Toggle(isOn: $item.includesCache) {
                    Text(L10n.string("menu_bar.row.include_cache", defaultValue: "Cache"))
                        .font(.sora(11))
                        .foregroundStyle(Color.stxMuted)
                }
                .toggleStyle(.checkbox)
                .help(L10n.string(
                    "menu_bar.row.include_cache.help",
                    defaultValue: "Include cache-read tokens in the total."
                ))
                .disabled(!item.isEnabled)
                .opacity(item.isEnabled ? 1 : 0.4)
            }

            Toggle("", isOn: $item.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            // Insertion indicator: a 2px accent line above the hovered row.
            if dropTargetID == item.kind {
                Rectangle()
                    .fill(Color.stxAccent)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Drag payload

/// Wraps the kind being dragged. Carried as JSON inside the standard
/// `.json` UTI — works for in-app drags without needing an Info.plist
/// declaration. The drop destination decodes the payload and matches the
/// kind back to a row in ``Preferences/menuBarItems``.
private struct MenuBarItemDragPayload: Codable, Hashable, Transferable {
    let kind: MenuBarItemKind

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Drag preview

private struct MenuBarItemDragPreview: View {
    let item: MenuBarItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(Color.stxAccent)
            Text(LocalizedStringKey(item.kind.displayName))
                .font(.sora(12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.stxAccent.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Live preview strip

private struct MenuBarPreviewStrip: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 10) {
            BracketBox(spacing: 6) {
                MenuBarLabel()
                    .font(.sora(12))
                    .foregroundStyle(.primary)
            }
            .foregroundStyle(Color.stxMuted)
            Spacer(minLength: 8)
            if env.preferences.menuBarItems.allSatisfy({ !$0.isEnabled }) {
                Text(L10n.string(
                    "menu_bar.preview.empty",
                    defaultValue: "No components enabled — the menu bar will show a placeholder icon."
                ))
                .font(.sora(11))
                .foregroundStyle(Color.stxMuted)
                .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

#if DEBUG
#Preview {
    MenuBarSettingsView()
        .environment(AppEnvironment.preview())
        .padding()
        .frame(width: 720)
}
#endif
