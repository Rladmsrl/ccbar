import Foundation

/// Where Claude Code keeps its data on disk. Injectable so tests can point
/// it at a temp directory.
struct ClaudePaths: Sendable, Hashable {
    /// `~/.claude` (or `$CLAUDE_CONFIG_DIR` when set).
    let configDirectory: URL

    /// `<configDirectory>/projects` — one subdirectory per project (with the
    /// cwd path encoded as the directory name), each holding `<uuid>.jsonl`
    /// transcripts.
    var projectsDirectory: URL { configDirectory.appendingPathComponent("projects", isDirectory: true) }

    init(configDirectory: URL) { self.configDirectory = configDirectory }

    static let `default`: ClaudePaths = {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return ClaudePaths(configDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudePaths(configDirectory: home.appendingPathComponent(".claude", isDirectory: true))
    }()
}
