import Foundation

/// A single transcript discovered on disk. Cheap metadata is filled by the
/// scanner; ``stats`` is parsed lazily (and cached) by ``SessionStore``.
struct Session: Sendable, Identifiable, Hashable {
    /// Stable id: `"<encoded-project-dir>::<transcript-uuid>"`.
    let id: String
    /// The transcript file's own basename without extension (the session UUID).
    let externalID: String
    let provider: ProviderKind
    /// The encoded project directory name (Claude's `~/.claude/projects/<this>`).
    let projectDirectoryName: String
    /// Absolute path of the `.jsonl` transcript.
    let filePath: String
    /// Working directory the session ran in, if it could be read cheaply.
    let cwd: String?
    let lastModified: Date
    let fileSize: Int64

    /// Filled in after parsing. `nil` until ``SessionStore`` parses it.
    var stats: SessionStats?

    /// Display name for the project: the real `cwd`'s last path component,
    /// falling back to a de-mangled form of the encoded directory name.
    var projectDisplayName: String {
        if let cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        // Claude encodes `/Users/me/dev/foo` as `-Users-me-dev-foo`.
        let parts = projectDirectoryName.split(separator: "-")
        return parts.last.map(String.init) ?? projectDirectoryName
    }
}
