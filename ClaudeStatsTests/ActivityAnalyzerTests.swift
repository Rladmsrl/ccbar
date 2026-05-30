import Testing
import Foundation
@testable import ClaudeStats

@Suite("ActivityAnalyzer")
struct ActivityAnalyzerTests {

    private let cal = Calendar.current
    private let day: Date

    init() {
        day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Hour `h` of the test day, as a `Date`.
    private func h(_ value: Double) -> Date { day.addingTimeInterval(value * 3600) }
    private func iv(_ a: Double, _ b: Double) -> DateInterval { DateInterval(start: h(a), end: h(b)) }

    private func session(ai intervals: [DateInterval]) -> Session {
        let stats = SessionStats(title: "t", messageCount: 1, firstActivity: nil, lastActivity: nil,
                                 models: [], timeline: [], activityIntervals: intervals)
        return Session(id: "s", externalID: "s", provider: .claude, projectDirectoryName: "-p",
                       filePath: "/s.jsonl", cwd: nil, lastModified: day, fileSize: 1, stats: stats)
    }

    @Test("union merges overlapping and touching intervals")
    func unionMerges() {
        let merged = ActivityAnalyzer.union([iv(1, 3), iv(2, 4), iv(4, 5), iv(7, 8)])
        #expect(merged == [iv(1, 5), iv(7, 8)])
    }

    @Test("union sorts and is idempotent on disjoint input")
    func unionSorts() {
        let merged = ActivityAnalyzer.union([iv(7, 8), iv(1, 2)])
        #expect(merged == [iv(1, 2), iv(7, 8)])
    }

    @Test("intersection keeps only overlapping spans")
    func intersection() {
        let a = [iv(1, 5), iv(7, 9)]
        let b = [iv(2, 3), iv(4, 8)]
        #expect(ActivityAnalyzer.intersection(a, b) == [iv(2, 3), iv(4, 5), iv(7, 8)])
    }

    @Test("dayActivity clips to the day and computes overlap + ratio")
    func dayActivityOverlap() {
        // Coding surface focused 9–12 and 14–15; AI active 10–11 and 14:30–16.
        let focus = [
            AppFocusInterval(bundleID: "com.apple.dt.Xcode", interval: iv(9, 12)),
            AppFocusInterval(bundleID: "com.microsoft.VSCode", interval: iv(14, 15)),
        ]
        let s = session(ai: [iv(10, 11), iv(14.5, 16)])
        let result = ActivityAnalyzer.dayActivity(
            day: day,
            codingSurfaceFocus: focus,
            cliHostFocus: [],
            sessions: [s],
            calendar: cal
        )

        let hour: TimeInterval = 3600
        let expectedSurface: TimeInterval = 4 * hour      // 3h + 1h
        let expectedAI: TimeInterval = 2.5 * hour         // 1h + 1.5h
        let expectedOverlap: TimeInterval = 1.5 * hour    // 10–11 plus 14:30–15
        #expect(result.codingSurfaceSeconds == expectedSurface)
        #expect(result.aiSeconds == expectedAI)
        #expect(result.overlapSeconds == expectedOverlap)
        let ratioDelta = abs(result.assistedRatio - 0.375)
        #expect(ratioDelta < 1e-9)
        #expect(result.overlapIntervals == [iv(10, 11), iv(14.5, 15)])
    }

    @Test("dayActivity drops activity outside the day")
    func dayActivityClips() {
        let focus = [AppFocusInterval(bundleID: "com.apple.dt.Xcode", interval: iv(-2, 1))]   // mostly yesterday
        let s = session(ai: [iv(0.5, 2)])
        let result = ActivityAnalyzer.dayActivity(
            day: day,
            codingSurfaceFocus: focus,
            cliHostFocus: [],
            sessions: [s],
            calendar: cal
        )
        let hour: TimeInterval = 3600
        #expect(result.codingSurfaceSeconds == hour)   // only 00:00–01:00 counts
        #expect(result.overlapSeconds == 0.5 * hour)   // 00:30–01:00
    }

    @Test("CLI host time is tracked separately and does not affect assisted ratio")
    func cliHostIsSeparate() {
        let surface = [AppFocusInterval(bundleID: "com.openai.codex", interval: iv(9, 10))]
        let cli = [AppFocusInterval(bundleID: "com.apple.Terminal", interval: iv(10, 12))]
        let s = session(ai: [iv(9.5, 11.5)])
        let result = ActivityAnalyzer.dayActivity(
            day: day,
            codingSurfaceFocus: surface,
            cliHostFocus: cli,
            sessions: [s],
            calendar: cal
        )

        let hour: TimeInterval = 3600
        #expect(result.codingSurfaceSeconds == hour)
        #expect(result.cliHostSeconds == 2 * hour)
        #expect(result.overlapSeconds == 0.5 * hour)
        #expect(result.cliAIOverlapSeconds == 1.5 * hour)
        #expect(result.assistedRatio == 0.5)
        #expect(result.aiOnlySeconds == 0)
    }

    @Test("empty day has zero everything and no division by zero")
    func emptyDay() {
        let result = ActivityAnalyzer.dayActivity(
            day: day,
            codingSurfaceFocus: [],
            cliHostFocus: [],
            sessions: [],
            calendar: cal
        )
        #expect(result.isEmpty)
        #expect(result.assistedRatio == 0)
    }
}

@Suite("TranscriptParser.coalesceBursts")
struct CoalesceBurstsTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }

    @Test("messages within the gap collapse into one interval")
    func collapsesNearby() {
        let bursts = TranscriptParser.coalesceBursts([at(0), at(2), at(4), at(20)])
        #expect(bursts.count == 2)
        #expect(bursts[0] == DateInterval(start: at(0), end: at(4)))
    }

    @Test("a lone message widens to the minimum burst length")
    func loneMessageWidened() {
        let bursts = TranscriptParser.coalesceBursts([at(0)])
        #expect(bursts.count == 1)
        #expect(bursts[0].duration == 30)
    }

    @Test("empty input yields no intervals")
    func empty() {
        #expect(TranscriptParser.coalesceBursts([]).isEmpty)
    }
}
