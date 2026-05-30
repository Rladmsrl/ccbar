import Foundation

/// A single assistant turn's billable contribution, kept around so cross-session
/// aggregation can dedup messages that appear in more than one transcript file.
///
/// When a Claude Code session spawns a subagent (Task tool), the subagent's
/// assistant messages get written to **both** the subagent's own JSONL **and**
/// back into the parent session's JSONL. Without dedup, aggregating tokens /
/// cost across sessions counts every subagent turn twice. Telemetry on a real
/// `.claude/projects/` tree showed 56% of assistant messages were duplicates
/// (parent.jsonl + subagent.jsonl), making the menu-bar cost ~2.3× too high.
///
/// The fix: every assistant message we count remembers its provider-stable
/// `(message.id, requestId)` hash. ``UsageSummary/make(period:sessions:...)``
/// iterates ``BillableMessage`` lists across sessions and skips hashes it has
/// already seen.
///
/// `hash` is optional because not every provider supplies request IDs — Codex
/// transcripts, for example. A `nil`-hash message is never deduped (every
/// instance is counted), which is the safe default for providers without the
/// subagent fan-out pattern.
struct BillableMessage: Sendable, Hashable {
    /// Stable cross-file identity: `"\(message.id):\(requestId)"` when both
    /// are present. `nil` disables cross-session dedup for this message.
    let hash: String?
    let model: String
    let usage: TokenUsage
    let cost: CostEstimate
    /// Used to rebuild the per-hour timeline after dedup. `nil` messages still
    /// contribute to totals but never appear in the timeline.
    let timestamp: Date?
}
