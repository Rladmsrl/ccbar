import Foundation

/// Pure interval arithmetic that turns raw coding-surface focus runs, CLI-host
/// focus runs, and AI activity bursts into a per-day ``DayActivity``. No I/O —
/// easy to unit-test.
enum ActivityAnalyzer {

    // MARK: Day analysis

    static func dayActivity(day: Date,
                            codingSurfaceFocus: [AppFocusInterval],
                            cliHostFocus: [AppFocusInterval],
                            sessions: [Session],
                            calendar: Calendar = .current) -> DayActivity {
        let bounds = dayBounds(for: day, calendar: calendar)

        let codingSurface = union(codingSurfaceFocus.compactMap { clip($0.interval, to: bounds) })
        let cliHost = union(cliHostFocus.compactMap { clip($0.interval, to: bounds) })
        let aiRaw = sessions.flatMap { $0.stats?.activityIntervals ?? [] }
        let ai = union(aiRaw.compactMap { clip($0, to: bounds) })
        let overlap = intersection(codingSurface, ai)
        let cliAIOverlap = intersection(cliHost, ai)

        return DayActivity(
            day: bounds,
            codingSurfaceIntervals: codingSurface,
            aiIntervals: ai,
            overlapIntervals: overlap,
            cliHostIntervals: cliHost,
            cliAIOverlapIntervals: cliAIOverlap,
            codingSurfaceSeconds: totalDuration(codingSurface),
            aiSeconds: totalDuration(ai),
            overlapSeconds: totalDuration(overlap),
            cliHostSeconds: totalDuration(cliHost),
            cliAIOverlapSeconds: totalDuration(cliAIOverlap))
    }

    /// One ``DayActivity`` per day in `days` (each clips against the same
    /// focus/session inputs).
    static func trend(days: [Date],
                      codingSurfaceFocus: [AppFocusInterval],
                      cliHostFocus: [AppFocusInterval],
                      sessions: [Session],
                      calendar: Calendar = .current) -> [DayActivity] {
        days.map {
            dayActivity(
                day: $0,
                codingSurfaceFocus: codingSurfaceFocus,
                cliHostFocus: cliHostFocus,
                sessions: sessions,
                calendar: calendar
            )
        }
    }

    static func dayBounds(for day: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    // MARK: Interval algebra

    /// Sort and merge overlapping/touching intervals into a disjoint, sorted set.
    static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.duration > 0 || $0.start == $0.end }
            .sorted { $0.start < $1.start }
        var out: [DateInterval] = []
        for iv in sorted {
            if let last = out.last, iv.start <= last.end {
                if iv.end > last.end {
                    out[out.count - 1] = DateInterval(start: last.start, end: iv.end)
                }
            } else {
                out.append(iv)
            }
        }
        return out
    }

    /// Intersection of two interval sets. Both are treated as already unioned
    /// (sorted, disjoint); the result is too.
    static func intersection(_ a: [DateInterval], _ b: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let lo = max(a[i].start, b[j].start)
            let hi = min(a[i].end, b[j].end)
            if hi > lo { out.append(DateInterval(start: lo, end: hi)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return out
    }

    static func clip(_ interval: DateInterval, to bounds: DateInterval) -> DateInterval? {
        let lo = max(interval.start, bounds.start)
        let hi = min(interval.end, bounds.end)
        guard hi > lo else { return nil }
        return DateInterval(start: lo, end: hi)
    }

    static func totalDuration(_ intervals: [DateInterval]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.duration }
    }
}
