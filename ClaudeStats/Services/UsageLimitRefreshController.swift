import Foundation

/// Drives usage-limit refreshes independently of `SessionStore.lastRefreshedAt`.
/// Two signals:
///
/// 1. **File mtime polling** — a 5-second timer checks the bridge cache files
///    we know about. When a file's mtime moves forward, that's a new Claude
///    Code response. Polling is simpler and more robust than `vnode` watches,
///    which die when the file is rotated by `mv` (which is exactly what the
///    bridge script does on every write).
///
/// 2. **UI heartbeat** — a 30-second timer triggers a soft refresh so the
///    "resets in 2h 14m" / "~Xh Ym" displays move with the wall clock even
///    when no new Claude Code response has come in.
@MainActor
final class UsageLimitRefreshController {
    private let watchedURLs: [URL]
    private var lastSeenMtimes: [URL: Date] = [:]
    private var fileWatchTimer: Timer?
    private var heartbeatTimer: Timer?
    private var onFileChange: (() -> Void)?
    private var onHeartbeat: (() -> Void)?

    static let filePollInterval: TimeInterval = 15
    static let heartbeatInterval: TimeInterval = 60

    init(watchedURLs: [URL]? = nil) {
        self.watchedURLs = watchedURLs ?? [
            UsageLimitCachePaths.claudeCacheURL(),
            URL(fileURLWithPath: "/tmp/statusline-rate-limits.json", isDirectory: false),
            URL(fileURLWithPath: "/tmp/open-island-rl.json", isDirectory: false),
            URL(fileURLWithPath: "/tmp/vibe-island-rl.json", isDirectory: false),
        ]
    }

    func start(onFileChange: @escaping () -> Void, onHeartbeat: @escaping () -> Void) {
        stop()
        self.onFileChange = onFileChange
        self.onHeartbeat = onHeartbeat
        // Prime the mtime baseline so we don't fire on first tick just because
        // we observed the file for the first time.
        for url in watchedURLs {
            lastSeenMtimes[url] = mtime(of: url)
        }
        fileWatchTimer = Timer.scheduledTimer(
            withTimeInterval: Self.filePollInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.pollFiles() }
        }
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.onHeartbeat?() }
        }
    }

    func stop() {
        fileWatchTimer?.invalidate()
        fileWatchTimer = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        onFileChange = nil
        onHeartbeat = nil
    }

    private func pollFiles() {
        var fired = false
        for url in watchedURLs {
            let current = mtime(of: url)
            let previous = lastSeenMtimes[url]
            if current != previous {
                lastSeenMtimes[url] = current
                if !fired { onFileChange?(); fired = true }
            }
        }
    }

    private func mtime(of url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
