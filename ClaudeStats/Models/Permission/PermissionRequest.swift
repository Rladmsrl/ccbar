import CryptoKit
import Foundation

/// A pending Claude Code `PermissionRequest`, normalized from the JSON body
/// CC POSTs to our HTTP hook. `Sendable` value type — kept clean of any
/// connection state (the resolve/drop closures live with the store).
struct PermissionRequest: Sendable, Identifiable, Hashable {
    let id: UUID
    let agentId: String
    let sessionId: String
    let toolName: String
    let toolInput: PermissionJSONValue
    let toolUseId: String?
    /// SHA1 of the canonicalized tool_input. CC may retry the same request,
    /// or two sessions may surface identical asks; we use this to dedupe
    /// pending entries.
    let toolInputFingerprint: String?
    let suggestions: [PermissionSuggestion]
    let createdAt: Date
    /// True when CC ran with `-p` / `--print` — no interactive UI available,
    /// so we auto-deny rather than show a bubble that nobody can answer.
    let isHeadless: Bool
    /// `AskUserQuestion` (Elicitation) flows through the same hook but
    /// renders a multi-question form instead of an Allow/Deny pair.
    let isElicitation: Bool

    init(
        id: UUID = UUID(),
        agentId: String,
        sessionId: String,
        toolName: String,
        toolInput: PermissionJSONValue,
        toolUseId: String?,
        toolInputFingerprint: String?,
        suggestions: [PermissionSuggestion],
        createdAt: Date = .now,
        isHeadless: Bool = false,
        isElicitation: Bool = false
    ) {
        self.id = id
        self.agentId = agentId
        self.sessionId = sessionId
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.toolInputFingerprint = toolInputFingerprint
        self.suggestions = suggestions
        self.createdAt = createdAt
        self.isHeadless = isHeadless
        self.isElicitation = isElicitation
    }
}

/// One `permission_suggestions` entry from the CC payload. We keep the raw
/// dict around so `ClaudeAllowRuleWriter` can re-emit it verbatim into
/// `settings.json.permissions.allow` when the user picks "Always".
struct PermissionSuggestion: Sendable, Identifiable, Hashable {
    let id: UUID
    let kind: Kind
    /// "Always allow Bash(ls:*)" — already localized at the boundary.
    let displayLabel: String
    /// Verbatim suggestion object as it arrived from CC; used by the rule
    /// writer to append into `permissions.allow`.
    let raw: PermissionJSONValue

    enum Kind: String, Sendable, Hashable {
        case addRules
        case other
    }

    init(id: UUID = UUID(), kind: Kind, displayLabel: String, raw: PermissionJSONValue) {
        self.id = id
        self.kind = kind
        self.displayLabel = displayLabel
        self.raw = raw
    }
}

extension PermissionRequest {
    /// SHA1 of canonical JSON encoding of `toolInput`. Used by the hook script
    /// path AND by stores that want to dedupe across reconnects.
    static func fingerprint(of value: PermissionJSONValue) -> String? {
        // `JSONSerialization.data(withJSONObject:)` requires the top-level
        // value to be an array or object — it throws an Obj-C
        // `NSInvalidArgumentException` ("Invalid top-level type in JSON
        // write") otherwise. That exception cannot be caught by Swift's
        // `try?`, and when it unwinds across a Swift async task boundary
        // (we're called from `handleStatePost` on the Permission HTTP
        // server's queue) it corrupts the Swift 6 runtime's
        // `swift_task_isCurrentExecutor` thread-local — every subsequent
        // `@MainActor` executor probe on the main thread then dereferences
        // garbage and SIGBUSes (see DiagnosticReports
        // CCBar-2026-05-26-114452.ips and earlier in that series).
        //
        // Stop / PostToolUseFailure hook payloads carry no `tool_input`
        // field, so we end up here with `.null`; for scalar/null inputs a
        // fingerprint has no matching value anyway, so return nil and let
        // the cancel-ladder fall through to the `toolUseId` exact match or
        // the `Stop` singleton fallback.
        switch value {
        case .array, .object:
            break
        case .null, .bool, .number, .string:
            return nil
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value.asFoundation,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        let digest = Insecure.SHA1.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
