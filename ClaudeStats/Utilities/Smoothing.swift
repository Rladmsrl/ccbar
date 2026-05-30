import Foundation

/// Centered moving-average smoothing for chart trend lines — enough to turn a
/// spiky per-bucket series into the "rough distribution" the Usage screen
/// wants. The window is forced odd; near the edges it shrinks to the
/// available span.
enum Smoothing {
    static func movingAverage(_ values: [Double], window: Int) -> [Double] {
        let n = values.count
        guard n > 2, window > 1 else { return values }
        let w = max(3, window | 1)        // odd, ≥ 3
        let half = w / 2
        return (0..<n).map { i in
            let lo = max(0, i - half)
            let hi = min(n - 1, i + half)
            var sum = 0.0
            for j in lo...hi { sum += values[j] }
            return sum / Double(hi - lo + 1)
        }
    }

    /// Window sized to the series length & grain: ≈ 3 hours of an hourly day,
    /// ≈ count/8 (clamped to `[3, 9]`) for daily series.
    static func adaptiveWindow(count: Int, granularity: TrendGranularity) -> Int {
        switch granularity {
        case .hour: return 5
        case .day:  return min(9, max(3, count / 8))
        }
    }
}
