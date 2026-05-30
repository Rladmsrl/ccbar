import Foundation
@testable import ClaudeStats

enum TestPricing {
    /// A small, predictable table for arithmetic assertions.
    static let table = ModelPricing(
        rates: [
            "model-a": ModelPricing.Rates(input: 10, output: 20, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 1),
            "model-b": ModelPricing.Rates(input: 2, output: 4, cacheWrite5m: 2, cacheWrite1h: 3, cacheRead: 0.5),
        ],
        defaultRate: ModelPricing.Rates(input: 1, output: 2, cacheWrite5m: 1, cacheWrite1h: 1, cacheRead: 1)
    )
}
