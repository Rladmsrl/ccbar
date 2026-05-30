import SwiftUI

/// The AI coding tools CCBar can read. Single-platform: ``claude``.
/// The enum is retained (instead of being inlined away) so existing call sites
/// — switches, persisted prefs, asset lookups — keep their signatures stable
/// and a future second provider can slot back in.
enum ProviderKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case claude

    var id: String { rawValue }

    var displayName: String { "Claude Code" }
    var shortName: String { "Claude" }
    var assetName: String { "claudecode-logo" }
    var monochromeAssetName: String { "claudecode" }
    var iconSystemName: String { "sparkles" }
    var accentColor: Color { Color(red: 0.85, green: 0.45, blue: 0.20) }
}
