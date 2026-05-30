import Foundation
import Testing
@testable import ClaudeStats

@Suite("Claude allow rule writer")
struct ClaudeAllowRuleWriterTests {
    @Test("Appends new addRules entries to permissions.allow")
    func appendsNewRules() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClaudeAllowRuleWriter(paths: ClaudePaths(configDirectory: root))

        let suggestion = PermissionSuggestion(
            kind: .addRules,
            displayLabel: "Always allow Bash(ls:*)",
            raw: .object([
                "type": .string("addRules"),
                "behavior": .string("allow"),
                "destination": .string("localSettings"),
                "rules": .array([
                    .object([
                        "toolName": .string("Bash"),
                        "ruleContent": .string("ls:*"),
                    ]),
                ]),
            ])
        )
        let result = try writer.apply(suggestions: [suggestion])
        #expect(result.addedRules == ["Bash(ls:*)"])

        let data = try Data(contentsOf: writer.settingsURL)
        let root2 = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let permissions = root2["permissions"] as! [String: Any]
        #expect((permissions["allow"] as! [String]).contains("Bash(ls:*)"))
    }

    @Test("Dedupes already-present rules")
    func dedupesExistingRules() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json", isDirectory: false)
        let seed: [String: Any] = [
            "permissions": ["allow": ["Bash(ls:*)"]]
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsURL)
        let writer = ClaudeAllowRuleWriter(paths: ClaudePaths(configDirectory: root))

        let suggestion = PermissionSuggestion(
            kind: .addRules,
            displayLabel: "duplicate",
            raw: .object([
                "type": .string("addRules"),
                "behavior": .string("allow"),
                "rules": .array([
                    .object([
                        "toolName": .string("Bash"),
                        "ruleContent": .string("ls:*"),
                    ]),
                ]),
            ])
        )
        let result = try writer.apply(suggestions: [suggestion])
        #expect(result.addedRules.isEmpty)
        #expect(result.skippedDuplicates == 1)
    }

    @Test("Non-addRules suggestions are ignored")
    func ignoresNonAddRules() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClaudeAllowRuleWriter(paths: ClaudePaths(configDirectory: root))

        let suggestion = PermissionSuggestion(
            kind: .other,
            displayLabel: "Show docs",
            raw: .object(["type": .string("showDocs")])
        )
        let result = try writer.apply(suggestions: [suggestion])
        #expect(result.addedRules.isEmpty)
        // settings.json should not be written.
        #expect(FileManager.default.fileExists(atPath: writer.settingsURL.path) == false)
    }
}
