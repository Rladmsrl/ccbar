import Foundation

/// Token usage for one model in one time bucket. Sessions store an hourly
/// timeline (bucket = start of hour, local calendar); the UI re-buckets to
/// coarser units (e.g. days) for wider periods.
struct ModelBucket: Sendable, Hashable, Identifiable {
    let model: String
    /// Start of the bucket in the local calendar (start of hour as stored,
    /// or start of day once re-bucketed).
    let start: Date
    let usage: TokenUsage

    var id: String { "\(model)|\(start.timeIntervalSinceReferenceDate)" }
    var tokens: Int { usage.total }
}

extension Array where Element == ModelBucket {
    /// Merge buckets sharing the same `(model, start)` — used after flattening
    /// many sessions. Result is sorted by `start` ascending.
    func mergedByModelBucket() -> [ModelBucket] {
        var acc: [String: [Date: TokenUsage]] = [:]
        for b in self { acc[b.model, default: [:]][b.start, default: .zero] += b.usage }
        return acc
            .flatMap { model, byStart in byStart.map { ModelBucket(model: model, start: $0.key, usage: $0.value) } }
            .sorted { $0.start < $1.start }
    }

    /// Re-bucket every entry to the start of the given calendar unit (e.g.
    /// `.day`), then merge by `(model, bucket)`.
    func rebucketed(by unit: Calendar.Component, calendar: Calendar = .current) -> [ModelBucket] {
        map { b in
            let start = calendar.dateInterval(of: unit, for: b.start)?.start ?? b.start
            return ModelBucket(model: b.model, start: start, usage: b.usage)
        }
        .mergedByModelBucket()
    }

    var totalTokens: Int { reduce(0) { $0 + $1.tokens } }

    /// Distinct model names, ordered by total tokens descending (name as a
    /// stable tiebreak).
    var modelsByTotalDescending: [String] {
        var totals: [String: Int] = [:]
        for b in self { totals[b.model, default: 0] += b.tokens }
        return totals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }
}
