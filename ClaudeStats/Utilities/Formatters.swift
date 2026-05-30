import Foundation

/// Small display formatters shared across views.
enum Format {
    /// Compact token counts: `847`, `12.34K`, `4.12M`, `2.00B`.
    static func tokens(_ count: Int) -> String {
        let n = Double(count)
        switch abs(count) {
        case 1_000_000_000...: return String(format: "%.2fB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.2fM", n / 1_000_000)
        case 1_000...:         return String(format: "%.2fK", n / 1_000)
        default:               return "\(count)"
        }
    }

    /// Compact byte sizes: `847 B`, `12.34 KB`, `4.12 MB`, `2.00 GB`.
    static func bytes(_ count: Int) -> String {
        let n = Double(count)
        switch abs(count) {
        case 1_000_000_000...: return String(format: "%.2f GB", n / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.2f MB", n / 1_000_000)
        case 1_000...:         return String(format: "%.2f KB", n / 1_000)
        default:               return "\(count) B"
        }
    }

    /// `$0.00`, `$1.23`, `$12.34`. Always two decimals; never localizes the
    /// currency symbol away (this is an estimate, not a billing figure).
    static func cost(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    static func relativeDate(_ date: Date, now: Date = .now) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: now)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Day only, no year: `May 1`, `Dec 12`.
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// `09:42`, `21:18`. 24-hour clock, no date component. Used by the
    /// floating tab's hover preview to show recent-event timestamps.
    /// Uses an explicit `HH:mm` DateFormatter so the 24-hour shape is
    /// stable regardless of the user's macOS 12h/24h preference —
    /// `.hour(.twoDigits(amPM: .omitted))` only hides the AM/PM glyph
    /// and still produces 12h hour values on a 12h locale.
    static func shortTime(_ date: Date) -> String {
        Self.shortTimeFormatter.string(from: date)
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Compact duration: `0m`, `7m`, `1h 04m`, `3h`. Rounds to the minute.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : String(format: "%dh %02dm", h, m)
    }

    /// `0%`, `48%`, `100%` from a `0...1` ratio.
    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// `0%`, `48%`, `100%` from percentage points.
    static func percentPoints(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }
}
