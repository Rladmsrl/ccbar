import Foundation

/// A GitHub-style calendar grid: an array of week columns, each holding 7 day
/// starts in calendar order (`firstWeekday` first). Days that fall outside the
/// visible `range` are still emitted so every column is a full 7 — callers can
/// test inclusion with `range.contains(day)`.
///
/// The grid is built once from a `DateInterval` and rendered as a `LazyHGrid`
/// of 7 rows × N columns; row labels come from `weekdaySymbols`.
struct CalendarGrid: Sendable {
    /// One entry per week-column where the represented month changes from the
    /// previous column. Drives the month-label strip on top of the grid.
    struct MonthLabel: Sendable, Equatable {
        let weekIndex: Int
        let label: String
    }

    /// The columns, oldest-week first. Inner arrays are always length 7.
    let weeks: [[Date]]
    /// Localized one-letter weekday symbols (M/T/W/…), aligned to the rows.
    let weekdaySymbols: [String]
    /// Precomputed `(weekIndex, monthAbbrev)` pairs marking the first column
    /// of each visible month. Built once at init so renderers don't allocate
    /// a `DateFormatter` per body pass.
    let monthLabels: [MonthLabel]
    /// The interval the grid was built for. Useful for callers that want to
    /// filter out-of-range days during rendering.
    let range: DateInterval
    /// First weekday (1 = Sunday … 7 = Saturday) used to align rows.
    let firstWeekday: Int

    init(spanning range: DateInterval, calendar: Calendar = .current) {
        self.range = range
        self.firstWeekday = calendar.firstWeekday

        let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: range.start)?.start ?? range.start
        let lastWeekStart = calendar.dateInterval(of: .weekOfYear, for: range.end)?.start ?? range.end

        var weeks: [[Date]] = []
        var cursor = firstWeekStart
        while cursor <= lastWeekStart {
            var days: [Date] = []
            for offset in 0..<7 {
                let day = calendar.date(byAdding: .day, value: offset, to: cursor) ?? cursor
                days.append(calendar.startOfDay(for: day))
            }
            weeks.append(days)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        self.weeks = weeks

        let standalone = calendar.veryShortStandaloneWeekdaySymbols
        let startIndex = firstWeekday - 1
        var rotated: [String] = []
        rotated.reserveCapacity(7)
        for i in 0..<7 {
            let idx = (startIndex + i) % 7
            rotated.append(idx < standalone.count ? standalone[idx] : "")
        }
        self.weekdaySymbols = rotated

        self.monthLabels = Self.buildMonthLabels(weeks: weeks, range: range, calendar: calendar)
    }

    /// Walks the week columns once, emitting a label whenever the month
    /// changes. Anchors each column on the first in-range day; if no day in
    /// the column is in range, falls back to the first in-range day of any
    /// later week so the label still corresponds to a visible month.
    private static func buildMonthLabels(
        weeks: [[Date]],
        range: DateInterval,
        calendar: Calendar
    ) -> [MonthLabel] {
        guard !weeks.isEmpty else { return [] }
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = calendar.locale ?? .current
        fmt.dateFormat = "MMM"

        var out: [MonthLabel] = []
        var lastMonth = -1
        for (i, week) in weeks.enumerated() {
            // Prefer the first in-range day in this week; if none, look forward
            // through later weeks until one is found. Avoids landing on `week[0]`
            // when that date is outside `range` (would mislabel boundary weeks
            // if the range ever starts mid-week).
            let representative: Date? = {
                if let inWeek = week.first(where: { range.contains($0) }) { return inWeek }
                for j in (i + 1)..<weeks.count {
                    if let next = weeks[j].first(where: { range.contains($0) }) { return next }
                }
                return nil
            }()
            guard let representative else { continue }
            let month = calendar.component(.month, from: representative)
            if month != lastMonth {
                out.append(MonthLabel(weekIndex: i, label: fmt.string(from: representative)))
                lastMonth = month
            }
        }
        return out
    }
}
