import Foundation

/// Token counts from a single assistant turn or summed across many.
struct TokenUsage: Sendable, Hashable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreation5mTokens: Int = 0
    var cacheCreation1hTokens: Int = 0

    static let zero = TokenUsage()

    /// All tokens that flowed, cached or not — the headline figure.
    var total: Int {
        inputTokens + outputTokens + cacheReadTokens
            + cacheCreation5mTokens + cacheCreation1hTokens
    }

    /// Headline token count with optional cache-read exclusion. `cache_read` is
    /// re-reported on every assistant turn (the cached context is "read" again
    /// each time), so including it can inflate the visible total by 10–100×
    /// versus what flowed end-to-end. `cache_creation` is a one-time event per
    /// cache block and is always counted.
    func total(includingCacheRead: Bool) -> Int {
        includingCacheRead ? total : total - cacheReadTokens
    }

    var cacheCreationTotalTokens: Int { cacheCreation5mTokens + cacheCreation1hTokens }

    /// Fraction of prompt input served from cache. Providers like Codex report
    /// cached input as a subset of total input, without a separate cache-write
    /// count, so this uses the reconstructed prompt-input denominator.
    var cachedInputRate: Double? {
        guard cacheReadTokens > 0 || cacheCreationTotalTokens > 0 else { return nil }
        let denom = inputTokens + cacheReadTokens + cacheCreationTotalTokens
        guard denom > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denom)
    }

    /// Fraction of cache-touching traffic that hit, in `0...1`. Hits are
    /// `cache_read` (the cache had what we asked for); misses are
    /// `cache_creation` (we had to write to prime it). `input_tokens` is the
    /// new-user-message part we weren't even trying to cache, so it isn't in
    /// the denominator. Returns `nil` when there's no cache activity at all.
    var cacheHitRate: Double? {
        let denom = cacheReadTokens + cacheCreationTotalTokens
        guard denom > 0 else { return nil }
        return Double(cacheReadTokens) / Double(denom)
    }

    var dataRevisionID: String {
        [
            inputTokens,
            outputTokens,
            cacheReadTokens,
            cacheCreation5mTokens,
            cacheCreation1hTokens,
        ]
        .map(String.init)
        .joined(separator: ",")
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreation5mTokens: lhs.cacheCreation5mTokens + rhs.cacheCreation5mTokens,
            cacheCreation1hTokens: lhs.cacheCreation1hTokens + rhs.cacheCreation1hTokens
        )
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}
