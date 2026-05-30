import Foundation

/// The merged coding-surface / CLI-host / AI activity picture for a single
/// calendar day.
///
/// All interval arrays are disjoint, sorted, and clipped to `day`. Durations
/// are precomputed (the analyzer already walked the intervals to build them).
struct DayActivity: Sendable, Hashable {
    /// The day this covers: `[start, start + 24h)` in the local calendar.
    let day: DateInterval
    /// Union of GUI coding-surface focus intervals.
    let codingSurfaceIntervals: [DateInterval]
    /// Union of AI activity bursts.
    let aiIntervals: [DateInterval]
    /// `codingSurfaceIntervals ∩ aiIntervals` — coding surface focused and AI active.
    let overlapIntervals: [DateInterval]
    /// Union of terminal / CLI host focus intervals.
    let cliHostIntervals: [DateInterval]
    /// `cliHostIntervals ∩ aiIntervals` — CLI host focused and AI active.
    let cliAIOverlapIntervals: [DateInterval]

    let codingSurfaceSeconds: TimeInterval
    let aiSeconds: TimeInterval
    let overlapSeconds: TimeInterval
    let cliHostSeconds: TimeInterval
    let cliAIOverlapSeconds: TimeInterval

    /// GUI coding-surface time that had no concurrent AI activity.
    var soloCodingSurfaceSeconds: TimeInterval { max(0, codingSurfaceSeconds - overlapSeconds) }
    /// AI activity with no GUI coding surface or CLI host focused.
    var aiOnlySeconds: TimeInterval {
        let coveredBySurfaceOrCLI = Self.totalUnionDuration(overlapIntervals + cliAIOverlapIntervals)
        return max(0, aiSeconds - coveredBySurfaceOrCLI)
    }

    /// Share of GUI coding-surface time spent with AI also active. `0` when
    /// there was no coding-surface time. *Not* a quality score — just a
    /// coincidence ratio.
    var assistedRatio: Double {
        codingSurfaceSeconds > 0 ? overlapSeconds / codingSurfaceSeconds : 0
    }

    var isEmpty: Bool { codingSurfaceIntervals.isEmpty && cliHostIntervals.isEmpty && aiIntervals.isEmpty }

    static func empty(day: DateInterval) -> DayActivity {
        DayActivity(
            day: day,
            codingSurfaceIntervals: [],
            aiIntervals: [],
            overlapIntervals: [],
            cliHostIntervals: [],
            cliAIOverlapIntervals: [],
            codingSurfaceSeconds: 0,
            aiSeconds: 0,
            overlapSeconds: 0,
            cliHostSeconds: 0,
            cliAIOverlapSeconds: 0
        )
    }

    private static func totalUnionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in sorted {
            guard interval.duration > 0 else { continue }
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged.reduce(0) { $0 + $1.duration }
    }
}
