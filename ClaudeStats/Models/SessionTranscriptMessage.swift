import Foundation

/// A displayable entry from a provider transcript. Providers keep their JSONL
/// quirks private and expose only this small shape to the shared UI.
struct SessionTranscriptMessage: Sendable, Identifiable, Hashable {
    enum Role: String, Sendable, Hashable {
        case user
        case assistant
        case tool
        case system

        var displayName: String {
            switch self {
            case .user: L10n.string("session.role.user", defaultValue: "User")
            case .assistant: L10n.string("session.role.assistant", defaultValue: "Assistant")
            case .tool: L10n.string("session.role.tool", defaultValue: "Tool")
            case .system: L10n.string("session.role.system", defaultValue: "System")
            }
        }
    }

    let id: String
    let role: Role
    let text: String
    let timestamp: Date?
    let model: String?
}
