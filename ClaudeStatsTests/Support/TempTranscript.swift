import Foundation

/// Helpers for building throwaway `~/.claude`-shaped directory trees in a
/// temp location, so scanner/parser tests don't touch the real config.
enum TempDir {
    /// Create a unique temp directory; the caller is responsible for cleanup
    /// (use `defer { try? FileManager.default.removeItem(at: dir) }`).
    static func make() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStatsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
    }
}

/// A minimal but realistic Claude Code transcript: a queue-op, an ai-title,
/// two user prompts, two assistant turns on different models with usage and
/// timestamps on two different days.
enum SampleTranscript {
    static let aiTitle = "Refactor the parser"
    static let cwd = "/Users/dev/projects/demo"

    /// 2026-01-10 and 2026-01-11 (UTC).
    static let lines: [String] = [
        #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-10T09:00:00.000Z","sessionId":"S"}"#,
        #"{"type":"ai-title","sessionId":"S","aiTitle":"Refactor the parser"}"#,
        #"{"type":"user","timestamp":"2026-01-10T09:00:01.000Z","cwd":"/Users/dev/projects/demo","sessionId":"S","message":{"role":"user","content":"please refactor the parser"}}"#,
        #"{"type":"assistant","timestamp":"2026-01-10T09:00:05.000Z","cwd":"/Users/dev/projects/demo","sessionId":"S","message":{"model":"model-a","role":"assistant","content":[{"type":"text","text":"on it"}],"usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}"#,
        #"{"type":"user","timestamp":"2026-01-11T10:00:00.000Z","cwd":"/Users/dev/projects/demo","sessionId":"S","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-01-11T10:00:10.000Z","cwd":"/Users/dev/projects/demo","sessionId":"S","message":{"model":"model-b","role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":50,"output_tokens":75,"cache_creation_input_tokens":300,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":0}}}}"#,
        #"{"type":"assistant","timestamp":"2026-01-11T10:00:20.000Z","cwd":"/Users/dev/projects/demo","sessionId":"S","message":{"model":"model-a","role":"assistant","content":[{"type":"text","text":"more"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}"#,
    ]

    static var text: String { lines.joined(separator: "\n") + "\n" }
}
