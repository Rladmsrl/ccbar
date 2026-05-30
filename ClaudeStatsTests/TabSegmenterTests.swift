import CoreGraphics
import Foundation
import Testing
@testable import ClaudeStats

@Suite("TabSegmenter.segments")
struct TabSegmenterSegmentsTests {

    // MARK: - 退化 case

    @Test("Empty sessions returns empty")
    func emptyReturnsEmpty() {
        let result = TabSegmenter.segments(from: [], cap: 5)
        #expect(result.isEmpty)
    }

    @Test("Single session returns one non-overflow segment")
    func singleSession() {
        let session = Self.makeSession(id: "a", state: .working)
        let result = TabSegmenter.segments(from: [session], cap: 5)
        #expect(result.count == 1)
        #expect(result[0].id == "a")
        #expect(result[0].displayState == .working)
        #expect(result[0].isOverflow == false)
        #expect(result[0].overflowCount == 0)
    }

    @Test("cap <= 0 returns empty regardless of input")
    func nonPositiveCapReturnsEmpty() {
        let sessions = [Self.makeSession(id: "a", state: .working)]
        #expect(TabSegmenter.segments(from: sessions, cap: 0).isEmpty)
        #expect(TabSegmenter.segments(from: sessions, cap: -1).isEmpty)
    }

    // MARK: - 在 cap 范围内

    @Test("N == cap returns N non-overflow segments preserving order")
    func nEqualsCap() {
        let sessions = (0..<5).map { Self.makeSession(id: "s\($0)", state: .working) }
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result.count == 5)
        #expect(result.map(\.id) == ["s0", "s1", "s2", "s3", "s4"])
        #expect(result.allSatisfy { !$0.isOverflow })
        #expect(result.allSatisfy { $0.overflowCount == 0 })
    }

    // MARK: - 溢出聚合

    @Test("N == cap + 1 produces (cap-1) independent + 1 overflow segment of count 2")
    func nEqualsCapPlusOne() {
        // cap = 5, N = 6 → 前 4 段独立 + 1 段聚合 sessions[4..5] = 2 个
        let sessions = (0..<6).map {
            Self.makeSession(id: "s\($0)", state: .working, updatedAt: Date(timeIntervalSince1970: Double($0)))
        }
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result.count == 5)
        #expect(result[0..<4].map(\.id) == ["s0", "s1", "s2", "s3"])
        #expect(result[0..<4].allSatisfy { !$0.isOverflow })
        #expect(result[4].id == "overflow")
        #expect(result[4].isOverflow == true)
        #expect(result[4].overflowCount == 2)
    }

    @Test("Overflow segment displayState comes from overflow region max(updatedAt) session")
    func overflowDisplayStateFromMaxUpdated() {
        // cap = 5, N = 8 → 溢出区 = sessions[4..7] = 4 个
        // 让 s7 最新, 它 state == .attention → overflow.displayState 应是 .attention
        let now = Date()
        let sessions: [LiveSession] = [
            Self.makeSession(id: "s0", state: .working, updatedAt: now),
            Self.makeSession(id: "s1", state: .working, updatedAt: now),
            Self.makeSession(id: "s2", state: .working, updatedAt: now),
            Self.makeSession(id: "s3", state: .working, updatedAt: now),
            Self.makeSession(id: "s4", state: .thinking, updatedAt: now.addingTimeInterval(-30)),
            Self.makeSession(id: "s5", state: .juggling, updatedAt: now.addingTimeInterval(-20)),
            Self.makeSession(id: "s6", state: .working,  updatedAt: now.addingTimeInterval(-10)),
            Self.makeSession(id: "s7", state: .attention, updatedAt: now),
        ]
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result.count == 5)
        let overflow = result[4]
        #expect(overflow.isOverflow == true)
        #expect(overflow.displayState == .attention)
        #expect(overflow.overflowCount == 4)
    }

    @Test("Overflow segment needsInput is true if any overflow-region session needsInput")
    func overflowNeedsInputUnion() {
        let sessions: [LiveSession] = (0..<6).map { i in
            Self.makeSession(
                id: "s\(i)",
                state: .working,
                needsInput: i == 5
            )
        }
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result[4].needsInput == true)
    }

    @Test("Overflow segment needsInput false when no overflow-region session needs input")
    func overflowNeedsInputFalse() {
        let sessions: [LiveSession] = (0..<6).map { i in
            Self.makeSession(id: "s\(i)", state: .working, needsInput: false)
        }
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result[4].needsInput == false)
    }

    @Test("Independent segment carries that session's own needsInput")
    func independentSegmentCarriesNeedsInput() {
        let sessions: [LiveSession] = [
            Self.makeSession(id: "a", state: .working, needsInput: true),
            Self.makeSession(id: "b", state: .working, needsInput: false),
        ]
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result[0].needsInput == true)
        #expect(result[1].needsInput == false)
    }

    @Test("Input order is preserved in output segments")
    func orderPreserved() {
        let sessions: [LiveSession] = ["x", "y", "z"].map {
            Self.makeSession(id: $0, state: .working)
        }
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result.map(\.id) == ["x", "y", "z"])
    }

    // MARK: - isForeground forwarding (spec §Amendment 2026-05-26)

    @Test("Independent segment carries isForeground=true when session.kind == .foreground")
    func independentSegmentForegroundFlag() {
        let sessions: [LiveSession] = [
            Self.makeSession(id: "bg", state: .working, kind: .background),
            Self.makeSession(id: "fg", state: .working, kind: .foreground),
        ]
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result.count == 2)
        #expect(result[0].id == "bg")
        #expect(result[0].isForeground == false)
        #expect(result[1].id == "fg")
        #expect(result[1].isForeground == true)
    }

    @Test("Overflow segment takes isForeground from the max(updatedAt) session in overflow region")
    func overflowSegmentForegroundFromMaxUpdated() {
        let now = Date()
        // cap = 5, N = 6 → overflow region = sessions[4..5]
        // s4 is BG (older), s5 is FG (newer) → overflow.isForeground == true
        let sessions: [LiveSession] = [
            Self.makeSession(id: "s0", state: .working, updatedAt: now),
            Self.makeSession(id: "s1", state: .working, updatedAt: now),
            Self.makeSession(id: "s2", state: .working, updatedAt: now),
            Self.makeSession(id: "s3", state: .working, updatedAt: now),
            Self.makeSession(id: "s4", state: .working, updatedAt: now.addingTimeInterval(-10), kind: .background),
            Self.makeSession(id: "s5", state: .working, updatedAt: now, kind: .foreground),
        ]
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result[4].isOverflow == true)
        #expect(result[4].isForeground == true)
    }

    @Test("Overflow segment isForeground=false when max(updatedAt) session is background")
    func overflowSegmentBackgroundFromMaxUpdated() {
        let now = Date()
        let sessions: [LiveSession] = [
            Self.makeSession(id: "s0", state: .working, updatedAt: now),
            Self.makeSession(id: "s1", state: .working, updatedAt: now),
            Self.makeSession(id: "s2", state: .working, updatedAt: now),
            Self.makeSession(id: "s3", state: .working, updatedAt: now),
            Self.makeSession(id: "s4", state: .working, updatedAt: now, kind: .background),
            Self.makeSession(id: "s5", state: .working, updatedAt: now.addingTimeInterval(-10), kind: .foreground),
        ]
        let result = TabSegmenter.segments(from: sessions, cap: 5)
        #expect(result[4].isOverflow == true)
        #expect(result[4].isForeground == false)
    }

    @Test("Foreground sessions are never folded into overflow when cap is smaller than foreground count")
    func foregroundSessionsAreNeverOverflowed() {
        let sessions: [LiveSession] = [
            Self.makeSession(id: "bg0", state: .working, kind: .background),
            Self.makeSession(id: "bg1", state: .attention, kind: .background),
            Self.makeSession(id: "fg0", state: .working, kind: .foreground),
            Self.makeSession(id: "fg1", state: .idle, kind: .foreground),
            Self.makeSession(id: "fg2", state: .attention, kind: .foreground),
            Self.makeSession(id: "fg3", state: .working, kind: .foreground),
        ]

        let result = TabSegmenter.segmentsPreservingForeground(from: sessions, cap: 3)

        #expect(result.map(\.id).filter { $0.hasPrefix("fg") } == ["fg0", "fg1", "fg2", "fg3"])
        #expect(result.filter { !$0.isOverflow }.map(\.id) == ["fg0", "fg1", "fg2", "fg3"])
        #expect(result.last?.isOverflow == true)
        #expect(result.last?.overflowCount == 2)
    }

    // MARK: - Test helpers


    /// `LiveSession.displayState` 现在是 `(state, lastEvent, recentEvents)` 三元组的派生。
    /// 这个 helper 接收期望的 `DisplayState`,反向构造能让 `displayState` 等于该值的 fixture:
    /// 终止态(`.attention` / `.error` / `.sleeping` / `.idle`)用 `state=.idle` +
    /// 在 `recentEvents` 里放对应终止事件;活动态(`.thinking` / `.working` /
    /// `.juggling` / `.sweeping`)用 `state=.working` + `lastEvent`。
    private static func makeSession(
        id: String,
        state: LiveSession.DisplayState,
        needsInput: Bool = false,
        updatedAt: Date = .now,
        kind: LiveSession.Kind = .background
    ) -> LiveSession {
        // DisplayState → (LiveSession.State, lastEvent, recentEvents)
        // 终止态 (attention/error/sleeping/idle) → state == .idle;
        // 活动态 (thinking/working/juggling/sweeping) → state == .working.
        let liveState: LiveSession.State
        let lastEvent: String?
        let recentEvents: [LiveSession.RecentEvent]

        switch state {
        case .idle:
            liveState = .idle
            lastEvent = nil
            recentEvents = []
        case .thinking:
            liveState = .working
            lastEvent = "UserPromptSubmit"
            recentEvents = []
        case .working:
            liveState = .working
            lastEvent = "PreToolUse"
            recentEvents = []
        case .juggling:
            liveState = .working
            lastEvent = "SubagentStart"
            recentEvents = []
        case .attention:
            liveState = .idle
            lastEvent = "Stop"
            recentEvents = [.init(event: "Stop", at: updatedAt)]
        case .sweeping:
            liveState = .working
            lastEvent = "PreCompact"
            recentEvents = []
        case .error:
            liveState = .idle
            lastEvent = "PostToolUseFailure"
            recentEvents = [.init(event: "PostToolUseFailure", at: updatedAt)]
        case .sleeping:
            liveState = .idle
            lastEvent = "SessionEnd"
            recentEvents = [.init(event: "SessionEnd", at: updatedAt)]
        }

        return LiveSession(
            id: id,
            displayTitle: id,
            cwd: nil,
            kind: kind,
            state: liveState,
            needsInput: needsInput,
            startedAt: updatedAt,
            updatedAt: updatedAt,
            lastEvent: lastEvent,
            recentEvents: recentEvents
        )
    }
}

@Suite("TabSegmenter.rects")
struct TabSegmenterRectsTests {

    private static let size = CGSize(width: 24, height: 200)

    @Test("count == 0 returns empty")
    func zeroCountReturnsEmpty() {
        let rects = TabSegmenter.rects(in: Self.size, count: 0, edge: .right)
        #expect(rects.isEmpty)
    }

    @Test("count < 0 returns empty")
    func negativeCountReturnsEmpty() {
        let rects = TabSegmenter.rects(in: Self.size, count: -1, edge: .right)
        #expect(rects.isEmpty)
    }

    @Test("count == 1 returns single rect equal to full size")
    func singleRectFullSize() {
        let rects = TabSegmenter.rects(in: Self.size, count: 1, edge: .right)
        #expect(rects.count == 1)
        #expect(rects[0].origin == .zero)
        #expect(rects[0].size == Self.size)
    }

    @Test("Vertical edge splits height; widths stay full")
    func verticalEdgeSplitsHeight() {
        for edge in [FloatingPanelEdge.left, .right] {
            let rects = TabSegmenter.rects(in: Self.size, count: 4, edge: edge)
            #expect(rects.count == 4)
            #expect(rects.allSatisfy { abs($0.size.width - Self.size.width) < 0.01 })
            let totalHeight = rects.reduce(0) { $0 + $1.size.height }
            #expect(abs(totalHeight - Self.size.height) < 0.01)
        }
    }

    @Test("Horizontal edge splits width; heights stay full")
    func horizontalEdgeSplitsWidth() {
        let size = CGSize(width: 320, height: 24)
        for edge in [FloatingPanelEdge.top, .bottom] {
            let rects = TabSegmenter.rects(in: size, count: 4, edge: edge)
            #expect(rects.count == 4)
            #expect(rects.allSatisfy { abs($0.size.height - size.height) < 0.01 })
            let totalWidth = rects.reduce(0) { $0 + $1.size.width }
            #expect(abs(totalWidth - size.width) < 0.01)
        }
    }

    @Test("Adjacent rects on vertical edge have no gap and no overlap")
    func verticalRectsContiguous() {
        let rects = TabSegmenter.rects(in: Self.size, count: 5, edge: .right)
        for i in 1..<rects.count {
            let previousBottom = rects[i - 1].origin.y + rects[i - 1].size.height
            let currentTop = rects[i].origin.y
            #expect(abs(previousBottom - currentTop) < 0.01)
        }
    }

    @Test("Adjacent rects on horizontal edge have no gap and no overlap")
    func horizontalRectsContiguous() {
        let size = CGSize(width: 320, height: 24)
        let rects = TabSegmenter.rects(in: size, count: 5, edge: .top)
        for i in 1..<rects.count {
            let previousRight = rects[i - 1].origin.x + rects[i - 1].size.width
            let currentLeft = rects[i].origin.x
            #expect(abs(previousRight - currentLeft) < 0.01)
        }
    }
}
