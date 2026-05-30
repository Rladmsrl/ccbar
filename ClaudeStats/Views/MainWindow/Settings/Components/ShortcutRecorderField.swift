import SwiftUI

/// "Click → press a key combo → done" shortcut editor. Reads/writes the
/// keyboard spec as a string like `"cmd+shift+y"` that
/// `PermissionShortcutSpec.parse` understands.
///
/// Rules:
///   - Pressing Esc with no modifiers cancels recording.
///   - The combination must include at least one of cmd / option / shift /
///     control. Bare letters are ignored so normal typing doesn't replace
///     the shortcut while the field has focus.
struct ShortcutRecorderField: View {
    @Binding var spec: String
    var placeholder: String = ""

    @State private var isRecording = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if isRecording {
                    isRecording = false
                    isFocused = false
                } else {
                    isRecording = true
                    isFocused = true
                }
            } label: {
                HStack(spacing: 6) {
                    if isRecording {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                    }
                    Text(displayText)
                        .font(.sora(11, weight: .medium))
                        .foregroundStyle(displayColor)
                        .frame(minWidth: 110, alignment: .leading)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .focusable()
            .focused($isFocused)
            .onKeyPress(phases: [.down]) { keyPress in
                handleKey(keyPress)
            }

            if !spec.isEmpty && !isRecording {
                Button {
                    spec = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.stxMuted)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .onChange(of: isFocused) { _, focused in
            // Click-elsewhere cancels recording without committing.
            if !focused { isRecording = false }
        }
    }

    // MARK: - Display

    private var displayText: String {
        if isRecording {
            return L10n.string("shortcut.recorder.recording", defaultValue: "Press a key…")
        }
        if spec.isEmpty {
            return placeholder.isEmpty
                ? L10n.string("shortcut.recorder.unset", defaultValue: "Click to set")
                : placeholder
        }
        if let parsed = PermissionShortcutSpec.parse(spec) {
            return parsed.humanLabel
        }
        return L10n.string("shortcut.recorder.invalid", defaultValue: "Invalid")
    }

    private var displayColor: Color {
        if isRecording { return Color.red }
        if spec.isEmpty { return Color.stxMuted }
        return .primary
    }

    // MARK: - Capture

    private func handleKey(_ keyPress: KeyPress) -> KeyPress.Result {
        guard isRecording else { return .ignored }

        // Esc alone bails out of the recording.
        if keyPress.key == .escape && keyPress.modifiers.isEmpty {
            isRecording = false
            isFocused = false
            return .handled
        }

        // Bare keys (no modifier) are ignored — would otherwise eat normal
        // typing if focus drifted in.
        guard !keyPress.modifiers.isEmpty else { return .ignored }

        // Disallow modifier-only events (Shift, Option, etc. on their own).
        guard !isPureModifier(keyPress.key) else { return .ignored }

        spec = Self.encode(modifiers: keyPress.modifiers, key: keyPress.key)
        isRecording = false
        isFocused = false
        return .handled
    }

    private func isPureModifier(_ key: KeyEquivalent) -> Bool {
        // KeyEquivalent's character for plain modifier keys is the modifier
        // character itself, which onKeyPress generally doesn't surface, but
        // guard against odd hardware layouts.
        let ch = key.character
        return ch == "\u{F700}" || ch == "\u{F701}" || ch == "\u{F702}" || ch == "\u{F703}"
    }

    // MARK: - Encoding

    static func encode(modifiers: EventModifiers, key: KeyEquivalent) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.option)  { parts.append("option") }
        if modifiers.contains(.shift)   { parts.append("shift") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        parts.append(encodeKey(key))
        return parts.joined(separator: "+")
    }

    private static func encodeKey(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: return "return"
        case .escape: return "escape"
        case .space:  return "space"
        case .tab:    return "tab"
        case .delete: return "delete"
        default:
            return String(key.character).lowercased()
        }
    }
}
