import Foundation

/// What the bubble UI returns when the user clicks Allow / Deny / Always /
/// (closes the panel). Translated to a JSON body by the HTTP server.
enum PermissionDecision: Sendable, Hashable {
    /// CC unblocks and runs the tool.
    case allow(message: String?)
    /// CC unblocks and *doesn't* run the tool, surfacing `message` in chat.
    case deny(message: String?)
    /// We bail out of the decision; CC will fall back to its built-in
    /// in-chat permission prompt. Implemented as 204 No Content (CC checks
    /// for this status). Used for non-interceptible flows like headless,
    /// elicitation cancel, and DND.
    case noDecision
}

extension PermissionDecision {
    /// JSON body Claude Code expects on success. Matches the shape it
    /// publishes for an HTTP `PermissionRequest` hook:
    ///   { "hookSpecificOutput": { "hookEventName": "PermissionRequest",
    ///       "decision": { "behavior": "allow" | "deny", "message": "..." } } }
    func responseBody(hookEventName: String = "PermissionRequest") -> Data? {
        switch self {
        case .noDecision:
            return nil
        case .allow(let message), .deny(let message):
            var decision: [String: Any] = ["behavior": behaviorString]
            if let message, !message.isEmpty {
                decision["message"] = message
            }
            let envelope: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": hookEventName,
                    "decision": decision,
                ],
            ]
            return try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]
            )
        }
    }

    private var behaviorString: String {
        switch self {
        case .allow: return "allow"
        case .deny: return "deny"
        case .noDecision: return ""
        }
    }
}
