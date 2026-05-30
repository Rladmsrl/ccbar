import Foundation
import Testing
@testable import ClaudeStats

@Suite("LiveSession.RecentEvent.humanized")
struct RecentEventHumanizationTests {

    @Test("Known events map to fixed human-readable strings")
    func knownEventsAreHumanized() {
        let cases: [(String, String)] = [
            ("UserPromptSubmit",   "Prompt submitted"),
            ("PreToolUse",         "Running tool"),
            ("PostToolUse",        "Tool done"),
            ("PostToolUseFailure", "Tool failed"),
            ("SubagentStart",      "Subagent started"),
            ("SubagentStop",       "Subagent done"),
            ("Stop",               "Turn finished"),
            ("StopFailure",        "Turn interrupted"),
            ("Notification",       "Notification"),
            ("PreCompact",         "Compacting\u{2026}"),
            ("PostCompact",        "Compacted"),
            ("SessionStart",       "Session started"),
            ("SessionEnd",         "Session ended"),
        ]
        for (event, expected) in cases {
            let recent = LiveSession.RecentEvent(event: event, at: .now)
            #expect(recent.humanized == expected,
                    "event=\(event) expected=\(expected) got=\(recent.humanized)")
        }
    }

    @Test("Unknown event names fall through to the raw string")
    func unknownEventsFallThrough() {
        let recent = LiveSession.RecentEvent(event: "SomeFutureHook", at: .now)
        #expect(recent.humanized == "SomeFutureHook")
    }

    @Test("Empty event name falls through to empty string")
    func emptyEventFallsThrough() {
        let recent = LiveSession.RecentEvent(event: "", at: .now)
        #expect(recent.humanized == "")
    }
}
