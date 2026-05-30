import AppKit
import Carbon.HIToolbox
import Foundation

/// Registers global keyboard shortcuts via the Carbon `RegisterEventHotKey`
/// API. We use Carbon rather than `NSEvent.addGlobalMonitorForEvents` because
/// the AppKit monitor requires the Accessibility privilege to observe key
/// presses from other apps, which we'd rather not force users to grant just
/// for an Allow/Deny shortcut. Carbon hotkeys work without any extra
/// permission — same approach as clawd / Electron `globalShortcut`.
///
/// Hotkey IDs are stable across re-registrations so the C-side dispatch
/// callback can look up the action without holding a Swift closure.
@MainActor
final class PermissionGlobalShortcutMonitor {
    enum Action: Equatable {
        case allow
        case deny
        case always
    }

    private var handler: ((Action) -> Void)?
    private var registrations: [Carbon.EventHotKeyRef] = []
    private var hotKeyHandlerRef: EventHandlerRef?
    private var didInstallHandler = false

    private static let signature: OSType = {
        // FourCC for "CSAP" — CCBar Approval. Stable across launches
        // so other apps' hotkey IDs don't collide with ours.
        var bytes: [UInt8] = [0x43, 0x53, 0x41, 0x50] // 'C','S','A','P'
        return bytes.withUnsafeBytes { $0.load(as: OSType.self).bigEndian }
    }()

    private static let allowID: UInt32 = 1
    private static let denyID: UInt32 = 2
    private static let alwaysID: UInt32 = 3

    func update(
        allow: PermissionShortcutSpec?,
        deny: PermissionShortcutSpec?,
        always: PermissionShortcutSpec?,
        onAction: @escaping (Action) -> Void
    ) {
        unregisterAll()
        handler = onAction
        installHandlerIfNeeded()

        if let spec = allow,
           let ref = register(spec: spec, id: Self.allowID) {
            registrations.append(ref)
        }
        if let spec = deny,
           let ref = register(spec: spec, id: Self.denyID) {
            registrations.append(ref)
        }
        if let spec = always,
           let ref = register(spec: spec, id: Self.alwaysID) {
            registrations.append(ref)
        }

        if registrations.isEmpty {
            Log.permission.notice("Global shortcuts: no valid bindings to register")
        } else {
            Log.permission.notice("Global shortcuts: \(self.registrations.count) bindings active")
        }
    }

    func stop() {
        unregisterAll()
        handler = nil
    }

    // MARK: - Carbon plumbing

    private func installHandlerIfNeeded() {
        guard !didInstallHandler else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        Self.currentInstance = self
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandlerCallback,
            1,
            &eventSpec,
            nil,
            &hotKeyHandlerRef
        )
        if status == noErr {
            didInstallHandler = true
        } else {
            Log.permission.error("InstallEventHandler failed: \(status)")
        }
    }

    /// Used by the Carbon C callback to find the active monitor without
    /// having to send an `UnsafeMutableRawPointer` through a Sendable
    /// boundary (which Swift's strict concurrency flags as a data race
    /// candidate). The instance is replaced on every `update()` and
    /// `stop()`. Reads happen from the Carbon dispatch thread, which on
    /// macOS is the main thread for the application event target.
    nonisolated(unsafe) private static weak var currentInstance: PermissionGlobalShortcutMonitor?

    private static let eventHandlerCallback: EventHandlerUPP = { _, eventRef, _ in
        guard let eventRef else { return noErr }
        var hotKeyID = EventHotKeyID()
        let getStatus = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard getStatus == noErr else { return getStatus }
        let id = hotKeyID.id
        Task { @MainActor in
            PermissionGlobalShortcutMonitor.currentInstance?.dispatch(hotKeyID: id)
        }
        return noErr
    }

    private func dispatch(hotKeyID: UInt32) {
        guard let handler else { return }
        switch hotKeyID {
        case Self.allowID:  handler(.allow)
        case Self.denyID:   handler(.deny)
        case Self.alwaysID: handler(.always)
        default: break
        }
    }

    private func register(spec: PermissionShortcutSpec, id: UInt32) -> EventHotKeyRef? {
        guard let keyCode = PermissionKeycode.map(character: spec.nsCharacter) else {
            Log.permission.notice("Global shortcut: no key code for '\(spec.nsCharacter, privacy: .public)'")
            return nil
        }
        let modifiers = Self.carbonModifiers(from: spec.nsModifierFlags)
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            Log.permission.error("RegisterEventHotKey failed for \(spec.humanLabel, privacy: .public): \(status)")
            return nil
        }
        return hotKeyRef
    }

    private func unregisterAll() {
        for ref in registrations {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command)  { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option)   { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift)    { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control)  { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}

/// Map of single-character key tokens → Carbon `kVK_*` virtual key codes.
/// US ANSI layout — fine for the Allow/Deny/Always defaults we use, and the
/// recorder UI only emits characters it sees, so the user types whatever key
/// they want and we look up that character here.
private enum PermissionKeycode {
    static let table: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "\r": kVK_Return,
        "\u{1b}": kVK_Escape,
        " ": kVK_Space,
        "\t": kVK_Tab,
        "\u{7f}": kVK_Delete,
        "-": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash,
        "\\": kVK_ANSI_Backslash,
        "`": kVK_ANSI_Grave,
    ]

    static func map(character: String) -> Int? {
        table[character.lowercased()]
    }
}
