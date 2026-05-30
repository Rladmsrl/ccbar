import Foundation

/// Appends `permission_suggestions` "addRules" entries into
/// `~/.claude/settings.json` under `permissions.allow` (or `.deny`,
/// per the suggestion's `behavior` field). Mirrors what Claude Code's
/// built-in "Always allow X" button does — once the rule is in the file,
/// CC stops asking on subsequent matching tool calls.
///
/// The writer reads → mutates → atomically writes. Dedupes by exact string
/// match. Out-of-scope (intentionally) for the MVP: writing to project-
/// scoped settings (`<project>/.claude/settings.json`) — we always write to
/// the user-level file because the bubble doesn't know which project the
/// session lives in.
struct ClaudeAllowRuleWriter: Sendable {
    let paths: ClaudePaths

    init(paths: ClaudePaths = .default) {
        self.paths = paths
    }

    var settingsURL: URL {
        paths.configDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    struct Result: Sendable, Hashable {
        let addedRules: [String]
        let skippedDuplicates: Int
    }

    /// Apply all `addRules` entries from `suggestions`. Returns the rules
    /// that were appended (deduped) so the UI can flash them.
    @discardableResult
    func apply(suggestions: [PermissionSuggestion]) throws -> Result {
        let addRules = suggestions.filter { $0.kind == .addRules }
        guard !addRules.isEmpty else {
            return Result(addedRules: [], skippedDuplicates: 0)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)

        var rootObject: [String: Any] = [:]
        if fileManager.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL),
           !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
                throw ClaudeAllowRuleWriterError.settingsMalformed
            }
            rootObject = parsed
        }

        var permissions = rootObject["permissions"] as? [String: Any] ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        var deny = (permissions["deny"] as? [String]) ?? []

        var added: [String] = []
        var skipped = 0
        for suggestion in addRules {
            let parsed = Self.rules(from: suggestion)
            let target = parsed.behavior == "deny" ? "deny" : "allow"
            for rule in parsed.rules {
                if target == "allow" {
                    if allow.contains(rule) {
                        skipped += 1
                    } else {
                        allow.append(rule)
                        added.append(rule)
                    }
                } else {
                    if deny.contains(rule) {
                        skipped += 1
                    } else {
                        deny.append(rule)
                        added.append(rule)
                    }
                }
            }
        }

        if added.isEmpty {
            return Result(addedRules: [], skippedDuplicates: skipped)
        }

        permissions["allow"] = allow
        if !deny.isEmpty {
            permissions["deny"] = deny
        }
        rootObject["permissions"] = permissions

        let output = try JSONSerialization.data(
            withJSONObject: rootObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try output.write(to: settingsURL, options: .atomic)

        return Result(addedRules: added, skippedDuplicates: skipped)
    }

    // MARK: - Parsing

    struct ParsedRules: Sendable, Hashable {
        let behavior: String
        let destination: String
        let rules: [String]
    }

    /// Pull the rule strings out of an `addRules` suggestion's raw JSON.
    /// Returns the strings in `Bash(ls:*)` form — matches `permissions.allow`
    /// shape directly.
    static func rules(from suggestion: PermissionSuggestion) -> ParsedRules {
        var behavior = "allow"
        var destination = "localSettings"
        var rules: [String] = []

        if let dict = suggestion.raw.object {
            if case .string(let b) = dict["behavior"] ?? .null { behavior = b }
            if case .string(let d) = dict["destination"] ?? .null { destination = d }
            if case .array(let arr) = dict["rules"] ?? .null {
                for entry in arr {
                    if let rule = renderRule(entry) {
                        rules.append(rule)
                    }
                }
            } else {
                // Some payloads put the rule at the top level (no `rules`
                // wrapper). Accept both.
                if let rule = renderRule(suggestion.raw) {
                    rules.append(rule)
                }
            }
        }
        return ParsedRules(behavior: behavior, destination: destination, rules: rules)
    }

    private static func renderRule(_ value: PermissionJSONValue) -> String? {
        guard let dict = value.object else { return nil }
        let toolName: String? = {
            if case .string(let s) = dict["toolName"] ?? .null { return s }
            return nil
        }()
        let ruleContent: String? = {
            if case .string(let s) = dict["ruleContent"] ?? .null { return s }
            return nil
        }()
        switch (toolName, ruleContent) {
        case let (.some(tool), .some(content)) where !content.isEmpty:
            return "\(tool)(\(content))"
        case let (.some(tool), _):
            return tool
        default:
            return nil
        }
    }
}

enum ClaudeAllowRuleWriterError: LocalizedError {
    case settingsMalformed

    var errorDescription: String? {
        switch self {
        case .settingsMalformed:
            return L10n.string(
                "permission.allow_rule.error.malformed_settings",
                defaultValue: "Could not parse ~/.claude/settings.json to write the always-allow rule."
            )
        }
    }
}
