import Foundation
import Testing
@testable import ClaudeStats

@Suite("LiveSession.displayState")
struct LiveSessionDisplayStateTests {

    @Test("Stop 之后晚到的 PostToolUse 不该把绿色翻成橙")
    func stopThenLatePostToolUseStaysAttention() {
        let session = makeSession(
            state: .idle,
            lastEvent: "PostToolUse",
            recentEvents: [
                .init(event: "Stop",        at: Date(timeIntervalSince1970: 1)),
                .init(event: "PostToolUse", at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .attention)
    }

    @Test("Stop 之后晚到的 SubagentStop 不该把绿色翻成橙")
    func stopThenLateSubagentStopStaysAttention() {
        let session = makeSession(
            state: .idle,
            lastEvent: "SubagentStop",
            recentEvents: [
                .init(event: "Stop",         at: Date(timeIntervalSince1970: 1)),
                .init(event: "SubagentStop", at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .attention)
    }

    @Test("新一轮 UserPromptSubmit 把 state 翻回 working → 蓝 (thinking)")
    func newPromptGoesThinking() {
        let session = makeSession(
            state: .working,
            lastEvent: "UserPromptSubmit",
            recentEvents: [
                .init(event: "Stop",              at: Date(timeIntervalSince1970: 1)),
                .init(event: "UserPromptSubmit",  at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .thinking)
    }

    @Test("StopFailure 之后晚到的 PostToolUse 保持 error (红)")
    func stopFailureThenLatePostToolUseStaysError() {
        let session = makeSession(
            state: .idle,
            lastEvent: "PostToolUse",
            recentEvents: [
                .init(event: "StopFailure",  at: Date(timeIntervalSince1970: 1)),
                .init(event: "PostToolUse",  at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .error)
    }

    @Test("SessionEnd 是最后一个终止事件 → sleeping")
    func sessionEndGivesSleeping() {
        let session = makeSession(
            state: .idle,
            lastEvent: "SessionEnd",
            recentEvents: [
                .init(event: "Stop",       at: Date(timeIntervalSince1970: 1)),
                .init(event: "SessionEnd", at: Date(timeIntervalSince1970: 2)),
            ]
        )
        #expect(session.displayState == .sleeping)
    }

    @Test("state==idle 且 recentEvents 里没终止事件 → idle (dormant)")
    func idleWithNoTerminalEventGivesIdle() {
        let session = makeSession(
            state: .idle,
            lastEvent: "PreToolUse",
            recentEvents: [
                .init(event: "PreToolUse", at: Date(timeIntervalSince1970: 1)),
            ]
        )
        #expect(session.displayState == .idle)
    }

    // MARK: - Helper

    private func makeSession(
        state: LiveSession.State,
        lastEvent: String?,
        recentEvents: [LiveSession.RecentEvent]
    ) -> LiveSession {
        LiveSession(
            id: "s",
            displayTitle: "s",
            cwd: nil,
            kind: .background,
            state: state,
            needsInput: false,
            startedAt: .now,
            updatedAt: .now,
            lastEvent: lastEvent,
            recentEvents: recentEvents
        )
    }
}
