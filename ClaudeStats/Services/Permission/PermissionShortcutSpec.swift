import AppKit
import Foundation
import SwiftUI

/// User-facing shortcut spec parsed from strings like `"cmd+option+a"`,
/// `"ctrl+shift+enter"`, `"f1"`. Tokens are case-insensitive and separated
/// by `+`. The final token is the key; preceding tokens are modifiers.
///
/// Supports just enough vocabulary for the permission bubble's three
/// shortcuts (Allow / Deny / Always). Not a general-purpose shortcut
/// editor — when we add a proper one we'll replace this.
struct PermissionShortcutSpec: Sendable {
    let modifiers: EventModifiers
    let keyEquivalent: KeyEquivalent
    /// AppKit-side modifier flag set (matches `NSEvent.modifierFlags &
    /// .deviceIndependentFlagsMask`) for use with global event monitors.
    let nsModifierFlags: NSEvent.ModifierFlags
    /// AppKit character for global-monitor key matching. Lower-case for
    /// letter keys, single-char for symbols, empty for function keys we
    /// don't surface globally.
    let nsCharacter: String
    /// Pretty form, for display in Settings ("⌘⌥A").
    let humanLabel: String

    static func parse(_ string: String) -> PermissionShortcutSpec? {
        let tokens = string.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyToken = tokens.last, tokens.count >= 1 else { return nil }
        let modifierTokens = tokens.dropLast()

        var modifiers: EventModifiers = []
        var nsFlags: NSEvent.ModifierFlags = []
        for token in modifierTokens {
            switch token {
            case "cmd", "command", "⌘":
                modifiers.insert(.command)
                nsFlags.insert(.command)
            case "option", "opt", "alt", "⌥":
                modifiers.insert(.option)
                nsFlags.insert(.option)
            case "shift", "⇧":
                modifiers.insert(.shift)
                nsFlags.insert(.shift)
            case "ctrl", "control", "⌃":
                modifiers.insert(.control)
                nsFlags.insert(.control)
            default:
                return nil
            }
        }

        let (keyEquivalent, nsChar) = mapKeyToken(keyToken) ?? (KeyEquivalent(Character(keyToken.first.map(String.init) ?? "")), keyToken)
        guard !nsChar.isEmpty else { return nil }

        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        label += keyToken.uppercased()

        return PermissionShortcutSpec(
            modifiers: modifiers,
            keyEquivalent: keyEquivalent,
            nsModifierFlags: nsFlags,
            nsCharacter: nsChar,
            humanLabel: label
        )
    }

    /// True when this AppKit `NSEvent` matches the parsed shortcut. Used by
    /// the global hotkey monitor. Modifier comparison is exact (the user
    /// can't trigger ⌘⌥A by holding ⌘⌥⇧A).
    func matches(event: NSEvent) -> Bool {
        let masked = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard masked == nsModifierFlags else { return false }
        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        return chars == nsCharacter
    }

    private static func mapKeyToken(_ token: String) -> (KeyEquivalent, String)? {
        // Map a few common named keys to their SwiftUI representation. For
        // letters / digits we fall through to the caller's "first char"
        // construction.
        switch token {
        case "return", "enter": return (.return, "\r")
        case "escape", "esc":   return (.escape, "\u{1b}")
        case "space":           return (.space, " ")
        case "tab":             return (.tab, "\t")
        case "delete":          return (.delete, "\u{7f}")
        default:
            if token.count == 1, let ch = token.first {
                return (KeyEquivalent(ch), String(ch))
            }
            return nil
        }
    }
}
