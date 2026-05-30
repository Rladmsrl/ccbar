import Foundation

/// A time window for the Usage screen / share export: either one of the named
/// ``StatsPeriod`` presets, or an explicit `[start, end]` range of calendar days.
enum PeriodSelection: Hashable, Sendable {
    case preset(StatsPeriod)
    /// Inclusive calendar-day bounds (only the day component matters).
    case custom(start: Date, end: Date)

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .preset(let period):
            return period.contains(date, now: now, calendar: calendar)
        case .custom(let start, let end):
            let lo = calendar.startOfDay(for: min(start, end))
            guard let hi = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end))) else { return false }
            return date >= lo && date < hi
        }
    }

    /// Short label for the readout that replaces the period picker in an
    /// exported panel — e.g. `TODAY`, `LAST 7 DAYS`, `MAY 1 – MAY 12`.
    func label(calendar: Calendar = .current) -> String {
        switch self {
        case .preset(let period):
            return period.displayName
        case .custom(let start, let end):
            let lo = min(start, end), hi = max(start, end)
            if calendar.isDate(lo, inSameDayAs: hi) {
                return Format.day(lo)
            }
            return "\(Format.day(lo)) – \(Format.day(hi))"
        }
    }
}
