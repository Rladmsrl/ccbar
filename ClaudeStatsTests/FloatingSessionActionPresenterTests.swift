import Foundation
import Testing
@testable import ClaudeStats

@Suite("FloatingSessionActionPresenter")
struct FloatingSessionActionPresenterTests {
    @Test("foreground sessions appear as focusable rows")
    func foregroundSessionsAppearAsRows() {
        let session = Self.session(
            id: "fg",
            title: "claude-stats",
            kind: .foreground,
            state: .working,
            sourcePid: 1234,
            lastEvent: "PreToolUse"
        )

        let model = FloatingSessionActionPresenter.makeModel(
            sessions: [session],
            unreadDoneSessions: []
        )

        #expect(model.rows.map(\.session.id) == ["fg"])
        #expect(model.rows.first?.attention == .running)
        #expect(model.rows.first?.canFocus == true)
        #expect(model.backgroundSummary == nil)
    }

    @Test("quiet background sessions are hidden and counted in summary")
    func quietBackgroundSessionsAreSummarized() {
        let bg = Self.session(
            id: "bg",
            title: "worker",
            kind: .background,
            state: .working,
            lastEvent: "PreToolUse"
        )

        let model = FloatingSessionActionPresenter.makeModel(
            sessions: [bg],
            unreadDoneSessions: []
        )

        #expect(model.rows.isEmpty)
        #expect(model.backgroundSummary?.hiddenCount == 1)
        #expect(model.backgroundSummary?.runningCount == 1)
    }

    @Test("actionable background sessions appear as rows")
    func actionableBackgroundSessionsAppearAsRows() {
        let bg = Self.session(
            id: "bg",
            title: "worker",
            kind: .background,
            state: .idle,
            lastEvent: "StopFailure",
            recentEvents: [.init(event: "StopFailure", at: .now)]
        )

        let model = FloatingSessionActionPresenter.makeModel(
            sessions: [bg],
            unreadDoneSessions: []
        )

        #expect(model.rows.map(\.session.id) == ["bg"])
        #expect(model.rows.first?.attention == .error)
        #expect(model.backgroundSummary == nil)
    }

    @Test("rows are sorted by attention priority")
    func rowsSortByAttentionPriority() {
        let sessions = [
            Self.session(id: "idle", title: "idle", state: .idle),
            Self.session(id: "running", title: "running", state: .working, lastEvent: "PreToolUse"),
            Self.session(id: "done", title: "done", state: .idle, lastEvent: "Stop", recentEvents: [.init(event: "Stop", at: .now)]),
            Self.session(id: "warning", title: "warning", state: .working, lastEvent: "PreCompact"),
            Self.session(id: "error", title: "error", state: .idle, lastEvent: "StopFailure", recentEvents: [.init(event: "StopFailure", at: .now)]),
            Self.session(id: "needs", title: "needs", state: .working, needsInput: true),
        ]

        let model = FloatingSessionActionPresenter.makeModel(
            sessions: sessions,
            unreadDoneSessions: ["done"]
        )

        #expect(model.rows.map(\.session.id) == ["needs", "error", "warning", "done", "running", "idle"])
    }

    @Test("subtitles use reason and action")
    func subtitlesUseReasonAndAction() {
        let session = Self.session(
            id: "done",
            title: "release-notes",
            state: .idle,
            lastEvent: "Stop",
            recentEvents: [.init(event: "Stop", at: .now)]
        )

        let model = FloatingSessionActionPresenter.makeModel(
            sessions: [session],
            unreadDoneSessions: ["done"]
        )

        #expect(model.rows.first?.reason == "Done")
        #expect(model.rows.first?.action == "Turn finished")
        #expect(model.rows.first?.subtitle == "Done · Turn finished")
    }

    @Test("segment sessions exclude quiet background and include actionable background")
    func segmentSessionsMatchActionableSurface() {
        let foreground = Self.session(
            id: "fg",
            title: "claude-stats",
            kind: .foreground,
            state: .working
        )
        let quietBackground = Self.session(
            id: "quiet-bg",
            title: "worker",
            kind: .background,
            state: .working,
            lastEvent: "PreToolUse"
        )
        let actionableBackground = Self.session(
            id: "action-bg",
            title: "worker-alert",
            kind: .background,
            state: .idle,
            lastEvent: "StopFailure",
            recentEvents: [.init(event: "StopFailure", at: .now)]
        )

        let model = FloatingSessionActionPresenter.makeModel(
            sessions: [quietBackground, foreground, actionableBackground],
            unreadDoneSessions: []
        )

        #expect(model.segmentSessions.map(\.id) == ["fg", "action-bg"])
    }

    @Test("all foreground sessions appear in rows and segments even when quiet or unfocusable")
    func allForegroundSessionsAppearInRowsAndSegments() {
        let running = Self.session(
            id: "fg-running",
            title: "app",
            kind: .foreground,
            state: .working,
            sourcePid: 1001,
            lastEvent: "PreToolUse"
        )
        let idleUnfocusable = Self.session(
            id: "fg-idle",
            title: "docs",
            kind: .foreground,
            state: .idle,
            sourcePid: nil
        )
        let doneRead = Self.session(
            id: "fg-done",
            title: "tests",
            kind: .foreground,
            state: .idle,
            sourcePid: 1003,
            lastEvent: "Stop",
            recentEvents: [.init(event: "Stop", at: .now)]
        )
        let quietBackground = Self.session(
            id: "quiet-bg",
            title: "worker",
            kind: .background,
            state: .working,
            sourcePid: nil,
            lastEvent: "PreToolUse"
        )

        let model = FloatingSessionActionPresenter.makeModel(
            sessions: [quietBackground, running, idleUnfocusable, doneRead],
            unreadDoneSessions: []
        )

        #expect(model.rows.map(\.session.id) == ["fg-running", "fg-idle", "fg-done"])
        #expect(model.segmentSessions.map(\.id) == ["fg-running", "fg-idle", "fg-done"])
        #expect(model.backgroundSummary?.hiddenCount == 1)
    }

    private static func session(
        id: String,
        title: String,
        kind: LiveSession.Kind = .foreground,
        state: LiveSession.State = .working,
        needsInput: Bool = false,
        sourcePid: Int? = 999,
        startedAt: Date = Date(timeIntervalSince1970: 1),
        updatedAt: Date = Date(timeIntervalSince1970: 2),
        lastEvent: String? = nil,
        recentEvents: [LiveSession.RecentEvent] = []
    ) -> LiveSession {
        LiveSession(
            id: id,
            displayTitle: title,
            kind: kind,
            state: state,
            needsInput: needsInput,
            sourcePid: sourcePid,
            startedAt: startedAt,
            updatedAt: updatedAt,
            lastEvent: lastEvent,
            recentEvents: recentEvents
        )
    }
}
