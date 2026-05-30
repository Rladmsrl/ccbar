import Foundation

/// Manages the lifecycle of our `~/.claude/settings.json` hook entries.
///
/// Two kinds of hooks land in the same file:
///   - **Command hooks** for the 14 state events. Each runs our shared sh
///     script with the event name as `$1`; the script `curl`s the body to
///     `/state`. Fire-and-forget.
///   - **One HTTP hook** for `PermissionRequest`. CC calls it directly over
///     HTTP and blocks on the response — that's how we get to render a
///     bubble and feed back an `allow` / `deny` decision.
///
/// Install is fully reversible: a state file at
/// `~/Library/Application Support/CCBar/PermissionHooks/permission-hook-state.json`
/// remembers the user's original hook entries per event, and `uninstall()`
/// restores them verbatim.
protocol ClaudePermissionHookInstalling: Sendable {
    var scriptURL: URL { get }
    var settingsURL: URL { get }
    var stateURL: URL { get }

    func install(port: Int, options: InstallOptions) throws -> ClaudePermissionHookInstallResult
    func uninstall(options: InstallOptions) throws -> ClaudePermissionHookUninstallResult
    func currentStatus(port: Int) -> ClaudePermissionHookStatus
    func scriptNeedsUpgrade() -> Bool
    func upgradeScriptInPlace() throws
}

extension ClaudePermissionHookInstalling {
    /// Convenience: install both state hooks + permission hook (preserves
    /// pre-Amendment-#2 behavior).
    func install(port: Int) throws -> ClaudePermissionHookInstallResult {
        try install(port: port, options: .all)
    }

    /// Convenience: uninstall both buckets (preserves pre-Amendment-#2 behavior).
    func uninstall() throws -> ClaudePermissionHookUninstallResult {
        try uninstall(options: .all)
    }
}

struct ClaudePermissionHookInstallResult: Sendable, Hashable {
    let scriptURL: URL
    let settingsURL: URL
    let settingsBackupURL: URL
    let addedEvents: [String]
    let updatedEvents: [String]
    let preservedExistingHookCount: Int
}

struct ClaudePermissionHookUninstallResult: Sendable, Hashable {
    let restoredEvents: [String]
    let didRemoveScript: Bool
}

/// Selects which hook bucket to install/uninstall. State hooks coexist with
/// foreign hooks via append-merge; PermissionRequest is exclusive ownership
/// (CC protocol: first to return a decision wins). See spec §Amendment 2026-05-26 #2.
struct InstallOptions: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    /// 14 state events (SessionStart, UserPromptSubmit, etc.) — appended
    /// to existing entries, safe to coexist with foreign hooks.
    static let stateHooks      = InstallOptions(rawValue: 1 << 0)
    /// PermissionRequest — exclusive ownership, overwrites any foreign hook.
    static let permissionHook  = InstallOptions(rawValue: 1 << 1)
    /// Both buckets (default — preserves backward compatibility).
    static let all: InstallOptions = [.stateHooks, .permissionHook]
}

enum ClaudePermissionHookStatus: Sendable, Hashable {
    case installed(eventCount: Int)
    case orphaned
    case partiallyInstalled(missingEvents: [String])
    case notInstalled
}

struct ClaudePermissionHookInstaller: ClaudePermissionHookInstalling {
    let paths: ClaudePaths

    init(paths: ClaudePaths = .default) {
        self.paths = paths
    }

    var scriptURL: URL { PermissionHookPaths.hookScriptURL() }
    var settingsURL: URL { paths.configDirectory.appendingPathComponent("settings.json", isDirectory: false) }
    var stateURL: URL { PermissionHookPaths.stateURL() }
    var backupsDirectory: URL { PermissionHookPaths.backupsDirectory() }

    /// All 14 state hooks we register. Mirrors clawd's CORE + VERSIONED list.
    /// CC silently drops events it doesn't know about, so registering the
    /// version-gated ones (`PreCompact` / `PostCompact` / `StopFailure`)
    /// even on older versions is a no-op rather than an error.
    static let stateEvents: [String] = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Stop", "StopFailure",
        "SubagentStart", "SubagentStop",
        "Notification", "Elicitation",
        "PreCompact", "PostCompact",
    ]

    static let permissionEvent = "PermissionRequest"

    /// Bumped whenever the generated sh script's protocol changes.
    /// v2 dropped the `Authorization: Bearer` header — CC's HTTP hook can't
    /// add one anyway, and `127.0.0.1` is the actual trust boundary.
    /// v3 added `?pid=$PPID` so the server can resolve the terminal that
    /// owns the foreground session (used by the focus-jump feature).
    static let scriptVersion = 3
    static let scriptVersionMarker = "# Permission hook script version: 3"

    private static let commandMarker = "claude-permission-hook.sh"

    // MARK: - Install

    func install(port: Int, options: InstallOptions = .all) throws -> ClaudePermissionHookInstallResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: PermissionHookPaths.directory(), withIntermediateDirectories: true)

        // 1. Load existing settings.json (or empty)
        let existingData: Data? = fileManager.fileExists(atPath: settingsURL.path)
            ? try Data(contentsOf: settingsURL)
            : nil
        var rootObject: [String: Any]
        if let data = existingData, !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
                throw ClaudePermissionHookInstallError.settingsJSONMalformed
            }
            rootObject = parsed
        } else {
            rootObject = [:]
        }

        // 2. Backup settings.json — but skip if the most recent backup is
        // byte-identical to the current contents. Without this, the now
        // always-on install path (Amendment #2) would write a new backup
        // file every app launch, accumulating indefinitely.
        let backupURL: URL
        if let data = existingData {
            try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            if let existing = Self.mostRecentBackup(in: backupsDirectory),
               let existingData = try? Data(contentsOf: existing),
               existingData == data {
                // Already backed up identical content, reuse.
                backupURL = existing
            } else {
                let stamp = Self.timestampString(for: .now)
                backupURL = backupsDirectory.appendingPathComponent("settings.json.\(stamp)", isDirectory: false)
                try data.write(to: backupURL, options: .atomic)
            }
        } else {
            backupURL = backupsDirectory.appendingPathComponent("settings.json.absent", isDirectory: false)
        }

        // 3. Snapshot the existing `hooks` block so uninstall can restore.
        let existingHooks = rootObject["hooks"] as? [String: Any] ?? [:]
        let existingState = loadState()
        let originalHooks: [String: Any]
        if let saved = existingState?.originalHooks {
            // Reinstall: keep the original (pre-our-changes) snapshot.
            originalHooks = saved
        } else {
            originalHooks = existingHooks
        }

        // 4. Write/refresh the bridge script.
        try writeBridgeScript()

        // 5. Compose the new `hooks` block, gated by `options`.
        var newHooks = existingHooks
        var addedEvents: [String] = []
        var updatedEvents: [String] = []
        var preservedHooks = 0

        if options.contains(.stateHooks) {
            for event in Self.stateEvents {
                let result = Self.mergeCommandHook(into: newHooks[event], scriptPath: scriptURL.path, event: event)
                newHooks[event] = result.value
                if result.changed {
                    if result.wasNew { addedEvents.append(event) } else { updatedEvents.append(event) }
                }
                preservedHooks += result.preservedCount
            }
        }

        if options.contains(.permissionHook) {
            // PermissionRequest is a blocking slot — Claude Code dispatches all
            // matching hooks in array order and the first one to return a
            // decision wins. If a foreign hook (e.g. another desktop pet, an
            // ensoai-style helper) was registered before us, our HTTP hook
            // never gets called. Take exclusive ownership while we're enabled;
            // the original array is already preserved verbatim in `state.
            // originalHooks[PermissionRequest]` and restored on uninstall.
            let permissionURL = "http://127.0.0.1:\(port)/permission"
            let desiredPermissionEntry: [String: Any] = [
                "matcher": "",
                "hooks": [["type": "http", "url": permissionURL, "timeout": 600]],
            ]
            let existingPermissionArray = (newHooks[Self.permissionEvent] as? [Any]) ?? []
            newHooks[Self.permissionEvent] = [desiredPermissionEntry]
            if existingPermissionArray.isEmpty {
                addedEvents.append(Self.permissionEvent)
            } else {
                updatedEvents.append(Self.permissionEvent)
            }
        }

        rootObject["hooks"] = newHooks

        // 6. Persist state BEFORE writing settings.json so a mid-write crash
        // still leaves a recoverable state file.
        let state = State(
            installedAt: .now,
            port: port,
            settingsBackupPath: existingData != nil ? backupURL.path : nil,
            originalHooks: originalHooks
        )
        try writeState(state)

        // 7. Write settings.json atomically.
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outputData = try JSONSerialization.data(
            withJSONObject: rootObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try outputData.write(to: settingsURL, options: .atomic)

        return ClaudePermissionHookInstallResult(
            scriptURL: scriptURL,
            settingsURL: settingsURL,
            settingsBackupURL: backupURL,
            addedEvents: addedEvents,
            updatedEvents: updatedEvents,
            preservedExistingHookCount: preservedHooks
        )
    }

    // MARK: - Uninstall

    /// Removes our hook entries (per `options`) from `settings.json`,
    /// restoring any pre-install foreign entries from the state file.
    ///
    /// FIXME(amendment #2): when called with `options: .stateHooks` only
    /// (without `.all`), `stateURL` is not removed. Subsequent
    /// `install(options: .stateHooks)` would then read stale `originalHooks`
    /// from the lingering state file and incorrectly believe the foreign
    /// hooks at install time were what's currently saved. Current App paths
    /// never call this with `.stateHooks` only (state hooks are always on),
    /// so the trap is dormant. If a partial-uninstall path is ever exposed,
    /// guard against this by clearing the stateURL.
    func uninstall(options: InstallOptions = .all) throws -> ClaudePermissionHookUninstallResult {
        let fileManager = FileManager.default
        let state = loadState()
        var restoredEvents: [String] = []

        if fileManager.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL),
           var rootObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            var hooks = rootObject["hooks"] as? [String: Any] ?? [:]
            var touchedEvents: [String] = []
            if options.contains(.stateHooks) { touchedEvents.append(contentsOf: Self.stateEvents) }
            if options.contains(.permissionHook) { touchedEvents.append(Self.permissionEvent) }
            for event in touchedEvents {
                let stripped = Self.stripOurEntries(from: hooks[event])
                if let original = state?.originalHooks?[event] {
                    hooks[event] = original
                    restoredEvents.append(event)
                } else if let stripped, !Self.isEmptyHooksValue(stripped) {
                    hooks[event] = stripped
                } else {
                    hooks.removeValue(forKey: event)
                }
            }
            if hooks.isEmpty {
                rootObject.removeValue(forKey: "hooks")
            } else {
                rootObject["hooks"] = hooks
            }
            let outputData = try JSONSerialization.data(
                withJSONObject: rootObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try outputData.write(to: settingsURL, options: .atomic)
        }

        // Script / state files only matter for state hooks. Token / port files
        // are server-level, only remove if uninstalling everything.
        var didRemoveScript = false
        if options.contains(.stateHooks), fileManager.fileExists(atPath: scriptURL.path) {
            try fileManager.removeItem(at: scriptURL)
            didRemoveScript = true
        }
        if options == .all {
            try? fileManager.removeItem(at: stateURL)
            try? fileManager.removeItem(at: PermissionHookPaths.tokenFileURL())
            try? fileManager.removeItem(at: PermissionHookPaths.portFileURL())
        }

        return ClaudePermissionHookUninstallResult(
            restoredEvents: restoredEvents,
            didRemoveScript: didRemoveScript
        )
    }

    // MARK: - Status

    /// Whether the bridge script, state file, and all 14 state hooks + the
    /// PermissionRequest hook are present at `port`. Returns `.notInstalled`
    /// if the script/state file are absent, `.orphaned` if they exist but the
    /// settings.json hooks are gone, `.partiallyInstalled` if some events
    /// missing, `.installed` if all are present.
    ///
    /// FIXME(amendment #2): does not account for the bucketed install model.
    /// When only `.stateHooks` is installed (the new always-on default and
    /// `permissionApprovalEnabled = false`), this method incorrectly reports
    /// `.partiallyInstalled(missingEvents: ["PermissionRequest"])`. Currently
    /// has no production callers (grep), so the misleading return value is
    /// dormant. If a UI surface starts using this, refactor to take
    /// `options: InstallOptions` and only check the requested bucket.
    func currentStatus(port: Int) -> ClaudePermissionHookStatus {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: scriptURL.path),
              fileManager.fileExists(atPath: stateURL.path) else {
            return .notInstalled
        }
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else {
            return .orphaned
        }
        var missing: [String] = []
        for event in Self.stateEvents where !Self.eventContainsOurCommandHook(hooks[event], scriptPath: scriptURL.path) {
            missing.append(event)
        }
        if !Self.eventContainsOurHTTPHook(hooks[Self.permissionEvent], port: port) {
            missing.append(Self.permissionEvent)
        }
        if missing.isEmpty {
            return .installed(eventCount: Self.stateEvents.count + 1)
        }
        if missing.count == Self.stateEvents.count + 1 {
            return .orphaned
        }
        return .partiallyInstalled(missingEvents: missing)
    }

    // MARK: - Upgrade

    func scriptNeedsUpgrade() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              let content = try? String(contentsOf: scriptURL, encoding: .utf8)
        else { return false }
        return !content.contains(Self.scriptVersionMarker)
    }

    func upgradeScriptInPlace() throws {
        try writeBridgeScript()
    }

    // MARK: - Merge logic

    struct MergeResult {
        let value: Any
        let changed: Bool
        let wasNew: Bool
        let preservedCount: Int
    }

    /// Build the desired entry for a command hook event, preserving any
    /// foreign entries the user already had.
    static func mergeCommandHook(into existing: Any?, scriptPath: String, event: String) -> MergeResult {
        let desiredCommand = commandForState(scriptPath: scriptPath, event: event)
        let desiredEntry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": desiredCommand]],
        ]
        return mergeEntry(into: existing, desired: desiredEntry, matches: { commandHookMatches($0, scriptPath: scriptPath) })
    }

    static func mergeHTTPHook(into existing: Any?, port: Int) -> MergeResult {
        let url = "http://127.0.0.1:\(port)/permission"
        let desiredEntry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "http", "url": url, "timeout": 600]],
        ]
        return mergeEntry(into: existing, desired: desiredEntry, matches: { httpHookMatchesOurEndpoint($0) })
    }

    /// Merge `desired` into the value at `existing`. `existing` may be nil
    /// (no entry yet), an array (CC's normal shape), or a single object
    /// (legacy shape). Foreign entries are kept as-is.
    private static func mergeEntry(
        into existing: Any?,
        desired: [String: Any],
        matches: (Any) -> Bool
    ) -> MergeResult {
        var array: [Any]
        switch existing {
        case nil:
            array = []
        case let value as [Any]:
            array = value
        case let single as [String: Any]:
            array = [single]
        default:
            array = []
        }

        var ourIndex: Int? = nil
        for (i, entry) in array.enumerated() {
            if matches(entry) {
                ourIndex = i
                break
            }
        }
        let preservedCount = array.count - (ourIndex == nil ? 0 : 1)
        if let idx = ourIndex {
            let existingEntry = array[idx]
            let unchanged = (existingEntry as? NSDictionary)?.isEqual(to: desired) ?? false
            if unchanged {
                return MergeResult(value: array, changed: false, wasNew: false, preservedCount: preservedCount)
            }
            array[idx] = desired
            return MergeResult(value: array, changed: true, wasNew: false, preservedCount: preservedCount)
        }
        array.append(desired)
        return MergeResult(value: array, changed: true, wasNew: true, preservedCount: preservedCount)
    }

    // MARK: - Strip / detect helpers

    private static func stripOurEntries(from value: Any?) -> Any? {
        guard let array = value as? [Any] else { return value }
        let filtered = array.filter { entry in
            !commandHookMatches(entry, scriptPath: nil) && !httpHookMatchesOurEndpoint(entry)
        }
        return filtered
    }

    private static func isEmptyHooksValue(_ value: Any) -> Bool {
        if let array = value as? [Any], array.isEmpty { return true }
        return false
    }

    static func commandHookMatches(_ entry: Any, scriptPath: String?) -> Bool {
        guard let dict = entry as? [String: Any],
              let hooks = dict["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            (hook["type"] as? String) == "command"
                && ((hook["command"] as? String)?.contains(commandMarker) ?? false)
                && (scriptPath == nil || ((hook["command"] as? String)?.contains(scriptPath!) ?? false))
        }
    }

    static func httpHookMatchesOurEndpoint(_ entry: Any) -> Bool {
        guard let dict = entry as? [String: Any],
              let hooks = dict["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            (hook["type"] as? String) == "http"
                && ((hook["url"] as? String)?.hasPrefix("http://127.0.0.1:") ?? false)
                && ((hook["url"] as? String)?.hasSuffix("/permission") ?? false)
        }
    }

    static func eventContainsOurCommandHook(_ value: Any?, scriptPath: String) -> Bool {
        guard let array = value as? [Any] else { return false }
        return array.contains { commandHookMatches($0, scriptPath: scriptPath) }
    }

    static func eventContainsOurHTTPHook(_ value: Any?, port: Int) -> Bool {
        guard let array = value as? [Any] else { return false }
        return array.contains { entry in
            guard let dict = entry as? [String: Any],
                  let hooks = dict["hooks"] as? [[String: Any]] else { return false }
            return hooks.contains { hook in
                (hook["type"] as? String) == "http"
                    && (hook["url"] as? String) == "http://127.0.0.1:\(port)/permission"
            }
        }
    }

    // MARK: - Commands

    static func commandForState(scriptPath: String, event: String) -> String {
        "/bin/sh \(shellSingleQuoted(scriptPath)) \(shellSingleQuoted(event))"
    }

    // MARK: - State persistence

    private struct State: Codable {
        var installedAt: Date
        var port: Int
        var settingsBackupPath: String?
        /// Per-event original hooks JSON, captured before our first install.
        /// Serialized as a JSON-encoded `Data` blob because `[String: Any]`
        /// isn't `Codable`.
        var originalHooks: [String: Any]?

        private enum CodingKeys: String, CodingKey {
            case installedAt
            case port
            case settingsBackupPath
            case originalHooks
        }

        init(installedAt: Date, port: Int, settingsBackupPath: String?, originalHooks: [String: Any]?) {
            self.installedAt = installedAt
            self.port = port
            self.settingsBackupPath = settingsBackupPath
            self.originalHooks = originalHooks
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installedAt = try container.decode(Date.self, forKey: .installedAt)
            port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 23333
            settingsBackupPath = try container.decodeIfPresent(String.self, forKey: .settingsBackupPath)
            if let raw = try container.decodeIfPresent(Data.self, forKey: .originalHooks) {
                originalHooks = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? [String: Any]
            } else {
                originalHooks = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(installedAt, forKey: .installedAt)
            try container.encode(port, forKey: .port)
            try container.encodeIfPresent(settingsBackupPath, forKey: .settingsBackupPath)
            if let originalHooks {
                let raw = try JSONSerialization.data(withJSONObject: originalHooks, options: [.sortedKeys])
                try container.encode(raw, forKey: .originalHooks)
            }
        }
    }

    private func writeState(_ state: State) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    // MARK: - Bridge script

    private func writeBridgeScript() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.bridgeScript(
            tokenFilePath: PermissionHookPaths.tokenFileURL().path,
            portFilePath: PermissionHookPaths.portFileURL().path
        )
        .write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func bridgeScript(tokenFilePath: String, portFilePath: String) -> String {
        let portPath = shellSingleQuoted(portFilePath)
        _ = tokenFilePath  // retained for API stability; no longer attached to requests
        return """
        #!/bin/sh
        # Generated by CCBar. Uninstall from the app to remove this file.
        \(scriptVersionMarker)
        #
        # Forwards each Claude Code hook event to the local CCBar HTTP
        # server. POST body = the JSON payload CC fed us on stdin; event name
        # goes on the URL path so the server can route without inspecting JSON.
        # `pid` query is our PPID — the Claude Code process that invoked us.
        # The server walks up from there to find the owning terminal tab.
        # No bearer header — CC's HTTP hook can't add one, and we rely on the
        # 127.0.0.1 loopback for isolation (same as clawd).
        set -u

        EVENT="${1:-unknown}"
        PORT=$(/bin/cat \(portPath) 2>/dev/null || /bin/echo 23333)
        SOURCE_PID="${PPID:-0}"

        BODY=$(/bin/cat)
        if [ -z "$BODY" ]; then BODY='{}'; fi

        /usr/bin/curl -sS --max-time 0.5 \\
          -H 'Content-Type: application/json' \\
          --data-binary "$BODY" \\
          "http://127.0.0.1:$PORT/state/$EVENT?pid=$SOURCE_PID" >/dev/null 2>&1 || true

        exit 0
        """
    }

    // MARK: - Helpers

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Returns the newest `settings.json.*` file in `directory`, or nil if
    /// the directory doesn't exist / contains no such files. Used to
    /// deduplicate backups across always-on `install` calls.
    static func mostRecentBackup(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let backups = entries.filter { $0.lastPathComponent.hasPrefix("settings.json.") && $0.lastPathComponent != "settings.json.absent" }
        return backups.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

enum ClaudePermissionHookInstallError: LocalizedError {
    case settingsJSONMalformed

    var errorDescription: String? {
        switch self {
        case .settingsJSONMalformed:
            return L10n.string(
                "permission.hook.error.malformed_settings",
                defaultValue: "Could not parse ~/.claude/settings.json. Fix the JSON syntax first."
            )
        }
    }
}
