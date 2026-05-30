import AppKit
import Foundation

/// Thin wrapper over `NSSound(named:)` for the permission alert sounds.
/// Sound names match the system sounds shipped in
/// `/System/Library/Sounds/` so users can pick a name familiar from the
/// "Notifications" preference pane.
enum PermissionSoundPlayer {

    /// macOS built-in alert sounds. `none` (empty string) = silent.
    static let availableSoundNames: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    static func play(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let sound = NSSound(named: NSSound.Name(trimmed)) else {
            Log.permission.notice("Sound '\(trimmed, privacy: .public)' not found")
            return
        }
        sound.stop()
        sound.play()
    }
}
