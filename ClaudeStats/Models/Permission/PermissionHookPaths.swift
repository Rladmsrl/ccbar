import Foundation

/// File-system locations for the permission-hook bridge: the sh script Claude
/// Code calls, its state file (for reversible uninstall), and the directory
/// that holds backups of `~/.claude/settings.json`.
enum PermissionHookPaths {
    private static let appSupportFolderName = "CCBar"
    private static let permissionFolderName = "PermissionHooks"

    static func directory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(appSupportFolderName, isDirectory: true)
            .appendingPathComponent(permissionFolderName, isDirectory: true)
    }

    static func hookScriptURL(fileManager: FileManager = .default) -> URL {
        directory(fileManager: fileManager)
            .appendingPathComponent("claude-permission-hook.sh", isDirectory: false)
    }

    static func stateURL(fileManager: FileManager = .default) -> URL {
        directory(fileManager: fileManager)
            .appendingPathComponent("permission-hook-state.json", isDirectory: false)
    }

    static func backupsDirectory(fileManager: FileManager = .default) -> URL {
        directory(fileManager: fileManager)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// Local file the hook script writes its discovered server port into so
    /// the script can be regenerated when the port changes without forcing a
    /// settings.json re-write.
    static func portFileURL(fileManager: FileManager = .default) -> URL {
        directory(fileManager: fileManager)
            .appendingPathComponent("server.port", isDirectory: false)
    }

    /// Shared secret the hook script attaches as a header so an unrelated
    /// process bound to the same port can't trivially feed us decisions.
    static func tokenFileURL(fileManager: FileManager = .default) -> URL {
        directory(fileManager: fileManager)
            .appendingPathComponent("server.token", isDirectory: false)
    }
}
