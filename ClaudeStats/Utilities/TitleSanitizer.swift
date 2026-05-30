import Foundation

/// Cleans up a raw string before it's used as a session title — used for the
/// "first user message" fallback when a transcript has no generated title.
enum TitleSanitizer {
    private static let noisePrefixes = [
        "<system-reminder>", "<command-name>", "<command-message>",
        "<local-command-stdout>", "Caveat:", "[Image", "<bash-",
    ]

    /// Returns a trimmed, single-line, length-capped title, or `nil` if the
    /// text is empty or looks like tooling noise rather than a real prompt.
    static func sanitize(_ raw: String, maxLength: Int = 80) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for prefix in noisePrefixes where trimmed.hasPrefix(prefix) { return nil }

        // Collapse runs of spaces.
        let single = trimmed.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        guard !single.isEmpty else { return nil }
        if single.count <= maxLength { return single }
        return String(single.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
