import SwiftUI

/// Permission-request UI rendered inside the floating tab's expanded
/// content. Three blocks, vertically:
///   1. Tool chip + title + session tag (+N more chip)
///   2. The command itself, monospaced, wrapped, sized to read at a glance
///   3. Optional always-allow radio list
///   4. Deny / Always / Allow buttons with semantic tints
struct PermissionBubbleView: View {
    let request: PermissionRequest
    let pendingCount: Int
    let allowShortcut: PermissionShortcutSpec?
    let denyShortcut: PermissionShortcutSpec?
    let alwaysShortcut: PermissionShortcutSpec?
    let errorMessage: String?
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onAlways: (PermissionSuggestion) -> Void

    @State private var selectedSuggestionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            commandBlock
            if !addRulesSuggestions.isEmpty {
                suggestionList
            }
            if let errorMessage, !errorMessage.isEmpty {
                errorText(errorMessage)
            }
            Spacer(minLength: 0)
            actionRow
        }
        .padding(14)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.stxAccent)

            Text(headerTitle)
                .font(.sora(12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(request.toolName)
                .font(.sora(10, weight: .semibold))
                .tracking(0.4)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.stxAccent.opacity(0.16), in: Capsule())
                .foregroundStyle(Color.stxAccent)

            Spacer(minLength: 4)

            Text(sessionLabel)
                .font(.sora(9))
                .foregroundStyle(Color.stxMuted)

            if pendingCount > 1 {
                Text("+\(pendingCount - 1)")
                    .font(.sora(9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.1), in: Capsule())
            }
        }
    }

    private var headerTitle: String {
        request.isElicitation
            ? L10n.string("permission.bubble.title.elicitation", defaultValue: "Claude is asking")
            : L10n.string("permission.bubble.title.permission", defaultValue: "Permission required")
    }

    private var sessionLabel: String {
        let suffix = String(request.sessionId.suffix(6))
        return "#\(suffix)"
    }

    // MARK: - Command block

    private var commandBlock: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(commandSummary)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 120)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.stxStroke, lineWidth: 1)
        )
    }

    private var commandSummary: String {
        Self.commandSummary(toolInput: request.toolInput, toolName: request.toolName)
    }

    /// Pure rendering helper extracted so it can be unit-tested without
    /// instantiating the SwiftUI view. See
    /// `PermissionBubbleCommandSummaryTests`.
    nonisolated static func commandSummary(
        toolInput: PermissionJSONValue,
        toolName: String
    ) -> String {
        if let dict = toolInput.object {
            for key in ["command", "prompt", "path", "url", "text", "description"] {
                if case .string(let value) = dict[key] ?? .null, !value.isEmpty {
                    return value
                }
            }
        }
        // JSONSerialization.data(withJSONObject:) 要求 top-level 是 array/object —
        // scalar/null 会抛 Obj-C 的 NSInvalidArgumentException, Swift 的 try? 抓不住,
        // 沿 async task 边界 unwind 时污染 swift_task_isCurrentExecutor thread-local,
        // 主线程后续任何 @MainActor 探针 SIGBUS。同源 fix: commit 1d6eb9c
        // (PermissionRequest.fingerprint(of:))。Stop / PostToolUseFailure 的 hook
        // payload 没有 tool_input, toolInput 落到 .null, 必须先 guard。
        switch toolInput {
        case .array, .object:
            if let data = try? JSONSerialization.data(
                withJSONObject: toolInput.asFoundation,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
        case .null, .bool, .number, .string:
            break
        }
        return toolName
    }

    // MARK: - Suggestions

    private var addRulesSuggestions: [PermissionSuggestion] {
        request.suggestions.filter { $0.kind == .addRules }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(addRulesSuggestions) { suggestion in
                suggestionRow(suggestion)
            }
        }
    }

    private func suggestionRow(_ suggestion: PermissionSuggestion) -> some View {
        let isSelected = (selectedSuggestionID ?? addRulesSuggestions.first?.id) == suggestion.id
        return Button {
            selectedSuggestionID = suggestion.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.stxAccent : Color.stxMuted)
                Text(ruleShortLabel(for: suggestion))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func ruleShortLabel(for suggestion: PermissionSuggestion) -> String {
        suggestion.displayLabel.replacingOccurrences(of: "Always allow ", with: "")
    }

    private var chosenSuggestion: PermissionSuggestion? {
        if let id = selectedSuggestionID,
           let match = addRulesSuggestions.first(where: { $0.id == id }) {
            return match
        }
        return addRulesSuggestions.first
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.sora(10, weight: .medium))
            .foregroundStyle(Color.red)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(action: onDeny) {
                Text(L10n.string("permission.bubble.deny", defaultValue: "Deny"))
            }
            .buttonStyle(PermissionActionStyle(role: .deny))
            .keyboardShortcut(denyShortcut?.keyEquivalent ?? "d", modifiers: denyShortcut?.modifiers ?? [.command, .option])

            if let chosen = chosenSuggestion {
                Button { onAlways(chosen) } label: {
                    Text(L10n.string("permission.bubble.always", defaultValue: "Always"))
                }
                .buttonStyle(PermissionActionStyle(role: .neutral))
                .keyboardShortcut(alwaysShortcut?.keyEquivalent ?? "a", modifiers: alwaysShortcut?.modifiers ?? [.command, .option, .shift])
            }

            Button(action: onAllow) {
                Text(L10n.string("permission.bubble.allow", defaultValue: "Allow"))
            }
            .buttonStyle(PermissionActionStyle(role: .allow))
            .keyboardShortcut(allowShortcut?.keyEquivalent ?? "a", modifiers: allowShortcut?.modifiers ?? [.command, .option])
        }
    }
}

/// macOS system button styles (.bordered / .borderedProminent) swallow our
/// `.tint(.red)` etc. on the floating panel — they pick up the panel's own
/// material backdrop. To get unambiguous green/red action buttons we paint
/// the background ourselves.
private struct PermissionActionStyle: ButtonStyle {
    enum Role {
        case allow
        case deny
        case neutral
    }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sora(12, weight: role == .allow ? .semibold : .medium))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.78 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var background: Color {
        switch role {
        case .allow:   return Color.green
        case .deny:    return Color.red.opacity(0.12)
        case .neutral: return Color.primary.opacity(0.06)
        }
    }

    private var foreground: Color {
        switch role {
        case .allow:   return .white
        case .deny:    return Color.red
        case .neutral: return .primary
        }
    }

    private var border: Color {
        switch role {
        case .allow:   return Color.green.opacity(0.4)
        case .deny:    return Color.red.opacity(0.45)
        case .neutral: return Color.stxStroke
        }
    }
}
