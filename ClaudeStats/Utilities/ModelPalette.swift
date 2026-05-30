import SwiftUI

/// Stable, deterministic colors for models so the trend chart, the "By model"
/// list, and the session-row dots all agree.
///
/// Colors come from ``Color/stxRamp`` — a warm deep-red → gold ramp matching
/// the dashboard aesthetic. When a token-ordered set of models is on hand
/// (the chart, the breakdown list), use ``color(at:)`` so the busiest model
/// gets the deepest red and the rest fan out to gold. When only a single name
/// is available (a session row's dots), ``color(for:)`` picks a ramp stop from
/// the name's hash.
enum ModelPalette {
    /// Ramp color for the model at `index` in a token-ordered display set.
    /// Wraps if there are more models than ramp stops.
    static func color(at index: Int) -> Color {
        let ramp = Color.stxRamp
        return ramp[((index % ramp.count) + ramp.count) % ramp.count]
    }

    /// Stable ramp color for a model when no ordered set is available.
    static func color(for model: String) -> Color {
        let ramp = Color.stxRamp
        return ramp[Int(stableHash(model) % UInt64(ramp.count))]
    }

    /// FNV-1a over UTF-8 — process-stable, unlike Swift's randomized
    /// `hashValue`. We only need a well-spread small integer.
    private static func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
