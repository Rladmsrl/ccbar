import Foundation
import Testing
@testable import ClaudeStats

@Suite("PermissionBubbleView.commandSummary")
struct PermissionBubbleCommandSummaryTests {
    @Test("Object with `command` key returns the command value")
    func objectCommand() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .object(["command": .string("ls -la")]),
            toolName: "Bash"
        )
        #expect(summary == "ls -la")
    }

    @Test("Object with `prompt` key returns the prompt value")
    func objectPrompt() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .object(["prompt": .string("hello")]),
            toolName: "Ask"
        )
        #expect(summary == "hello")
    }

    @Test("Object with `url` key returns the url when no command/prompt present")
    func objectUrl() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .object(["url": .string("https://example.com")]),
            toolName: "WebFetch"
        )
        #expect(summary == "https://example.com")
    }

    @Test("Empty-string value is skipped so the next priority key wins")
    func emptyValueSkipped() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .object([
                "command": .string(""),
                "prompt": .string("real prompt"),
            ]),
            toolName: "X"
        )
        #expect(summary == "real prompt")
    }

    @Test("Object without any known key falls back to a JSON dump")
    func objectFallbackToJSONDump() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .object(["foo": .number(1)]),
            toolName: "X"
        )
        #expect(summary.contains("foo"))
        #expect(summary.contains("1"))
    }

    @Test("Array tool input falls back to a JSON dump")
    func arrayFallbackToJSONDump() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .array([.string("a"), .string("b")]),
            toolName: "X"
        )
        #expect(summary.contains("a"))
        #expect(summary.contains("b"))
    }

    // Regression guard for the SIGBUS in commit 1d6eb9c's sibling site —
    // scalar/null top-level must never be fed to JSONSerialization.data,
    // otherwise the Obj-C NSInvalidArgumentException corrupts the Swift 6
    // executor thread-local and crashes the main thread later.
    @Test("Null tool input returns toolName instead of crashing")
    func nullFallsBackToToolName() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .null,
            toolName: "Stop"
        )
        #expect(summary == "Stop")
    }

    @Test("Bool tool input returns toolName instead of crashing")
    func boolFallsBackToToolName() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .bool(true),
            toolName: "Bash"
        )
        #expect(summary == "Bash")
    }

    @Test("Number tool input returns toolName instead of crashing")
    func numberFallsBackToToolName() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .number(42),
            toolName: "Bash"
        )
        #expect(summary == "Bash")
    }

    @Test("String tool input returns toolName instead of crashing")
    func stringFallsBackToToolName() {
        let summary = PermissionBubbleView.commandSummary(
            toolInput: .string("hi"),
            toolName: "Bash"
        )
        #expect(summary == "Bash")
    }
}
