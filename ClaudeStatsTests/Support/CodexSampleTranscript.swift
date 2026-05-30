import Foundation
@testable import ClaudeStats

/// A minimal but realistic Codex CLI `rollout-*.jsonl` transcript: session
/// metadata, a `turn_context` naming the model, two user/agent message pairs,
/// two `token_count` events carrying turn deltas, and a trailing rate-limit-only
/// `token_count` (`info: null`) that must be ignored.
enum CodexSampleTranscript {
    static let sessionID = "019d4d6f-f74e-7221-a8cb-142a1fef07bc"
    static let cwd = "/Users/dev/projects/demo"
    static let threadName = "Refactor the parser"
    static let model = "gpt-5.1-codex"

    static let lines: [String] = [
        #"{"timestamp":"2026-01-10T09:00:00.000Z","type":"session_meta","payload":{"id":"019d4d6f-f74e-7221-a8cb-142a1fef07bc","timestamp":"2026-01-10T09:00:00.000Z","cwd":"/Users/dev/projects/demo","originator":"test","cli_version":"0.1.0","source":"test","model_provider":"openai"}}"#,
        #"{"timestamp":"2026-01-10T09:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/Users/dev/projects/demo","model":"gpt-5.1-codex"}}"#,
        #"{"timestamp":"2026-01-10T09:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"please refactor the parser"}}"#,
        #"{"timestamp":"2026-01-10T09:00:03.000Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"019d4d6f-f74e-7221-a8cb-142a1fef07bc","thread_name":"Refactor the parser"}}"#,
        #"{"timestamp":"2026-01-10T09:00:06.000Z","type":"event_msg","payload":{"type":"agent_message","message":"on it"}}"#,
        #"{"timestamp":"2026-01-10T09:00:08.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"cached_input_tokens":1000,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1300},"last_token_usage":{"input_tokens":1100,"cached_input_tokens":1000,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1300}},"rate_limits":null}}"#,
        #"{"timestamp":"2026-01-10T10:30:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"more please"}}"#,
        #"{"timestamp":"2026-01-10T10:30:05.000Z","type":"event_msg","payload":{"type":"agent_message","message":"sure"}}"#,
        #"{"timestamp":"2026-01-10T10:30:08.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":300,"cached_input_tokens":100,"output_tokens":50,"reasoning_output_tokens":10,"total_tokens":350}}}}"#,
        #"{"timestamp":"2026-01-10T10:31:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":1.0,"window_minutes":300}}}}"#,
    ]

    static var text: String { lines.joined(separator: "\n") + "\n" }

    /// Pricing with an exact rate for the sample model — `input` 10, `output`
    /// 20, `cacheRead` 1 (USD per million tokens).
    static let pricing = ModelPricing(
        rates: ["gpt-5.1-codex": ModelPricing.Rates(input: 10, output: 20, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1)],
        defaultRate: ModelPricing.Rates(input: 1, output: 2, cacheWrite5m: 1, cacheWrite1h: 1, cacheRead: 1)
    )
}
