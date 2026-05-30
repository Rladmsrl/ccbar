import Foundation

struct LegacyFeatureDataCleaner {
    private let applicationSupportDirectory: URL
    private let homeDirectory: URL
    private let fileManager: FileManager

    init(
        applicationSupportDirectory: URL? = nil,
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    func cleanRemovedFeatureData() {
        let migrated = migrateLegacyAppSupportDirectoryIfNeeded()
        // settings.json 和 bridge 脚本里都硬编码了 .../Claude Stats/... 绝对路径,
        // 迁移目录后这些引用变成 dangling,Claude Code 调 hook 会 "No such file"。
        // 不管 migrate 这次是否真的搬了目录,只要看到旧路径残留就重写,保证幂等。
        rewriteHardcodedClaudeStatsPathReferences(migrated: migrated)
        removeLegacyTokenTownData()
    }

    /// 把 ~/Library/Application Support/Claude Stats/ 整体改名成 CCBar/。
    /// app 在改名前(1.6.9 及更早)用前者存 usage-limit cache 和 permission
    /// hook state;改名后所有路径常量指向后者。仅当旧目录存在且新目录不存在
    /// 时执行,保证幂等;两个都在时不动旧的,避免覆盖新数据。
    @discardableResult
    private func migrateLegacyAppSupportDirectoryIfNeeded() -> Bool {
        let oldDir = applicationSupportDirectory.appendingPathComponent("Claude Stats", isDirectory: true)
        let newDir = applicationSupportDirectory.appendingPathComponent("CCBar", isDirectory: true)

        guard fileManager.fileExists(atPath: oldDir.path) else { return false }
        guard !fileManager.fileExists(atPath: newDir.path) else {
            Log.app.info("Both 'Claude Stats' and 'CCBar' app support dirs exist; leaving legacy alone")
            return false
        }

        do {
            try fileManager.moveItem(at: oldDir, to: newDir)
            Log.app.notice("Migrated app support: Claude Stats -> CCBar")
            return true
        } catch {
            Log.app.error("Failed to migrate legacy app support: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 改名后修补 3 处硬编码的旧绝对路径:
    /// 1. ~/.claude/settings.json — hooks.*.command 和 statusLine.command
    /// 2. .../CCBar/PermissionHooks/claude-permission-hook.sh — 脚本里 cat 的 portFile 路径
    /// 3. .../CCBar/UsageLimits/claude-statusline-bridge.sh — 脚本里 read/write 的 cache 路径
    private func rewriteHardcodedClaudeStatsPathReferences(migrated: Bool) {
        let oldFragment = "/Library/Application Support/Claude Stats/"
        let newFragment = "/Library/Application Support/CCBar/"

        rewriteFile(
            at: homeDirectory.appendingPathComponent(".claude/settings.json", isDirectory: false),
            replacing: oldFragment,
            with: newFragment
        )
        rewriteFile(
            at: applicationSupportDirectory.appendingPathComponent("CCBar/PermissionHooks/claude-permission-hook.sh", isDirectory: false),
            replacing: oldFragment,
            with: newFragment
        )
        rewriteFile(
            at: applicationSupportDirectory.appendingPathComponent("CCBar/UsageLimits/claude-statusline-bridge.sh", isDirectory: false),
            replacing: oldFragment,
            with: newFragment
        )
        _ = migrated
    }

    private func rewriteFile(at url: URL, replacing oldFragment: String, with newFragment: String) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8), text.contains(oldFragment) else { return }
            let replaced = text.replacingOccurrences(of: oldFragment, with: newFragment)
            try replaced.write(to: url, atomically: true, encoding: .utf8)
            Log.app.notice("Rewrote Claude Stats paths in \(url.lastPathComponent, privacy: .public)")
        } catch {
            Log.app.error("Failed to rewrite \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeLegacyTokenTownData() {
        let tokenTownDirectory = applicationSupportDirectory
            .appendingPathComponent("CCBar", isDirectory: true)
            .appendingPathComponent("TokenTown", isDirectory: true)
        guard fileManager.fileExists(atPath: tokenTownDirectory.path) else { return }

        do {
            try fileManager.removeItem(at: tokenTownDirectory)
            Log.app.info("Removed legacy TokenTown data at \(tokenTownDirectory.path, privacy: .public)")
        } catch {
            Log.app.error("Failed to remove legacy TokenTown data: \(error.localizedDescription, privacy: .public)")
        }
    }
}
