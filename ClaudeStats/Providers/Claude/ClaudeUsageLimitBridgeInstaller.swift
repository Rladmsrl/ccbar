import Foundation

protocol ClaudeUsageLimitBridgeInstalling: Sendable {
    var scriptURL: URL { get }
    var cacheURL: URL { get }
    var settingsURL: URL { get }
    var stateURL: URL { get }

    /// Manual / advanced path: writes the bridge script and returns the
    /// settings snippet so the user can paste it themselves.
    func install() throws -> ClaudeUsageLimitBridgeConfiguration
    func settingsSnippet() -> String

    /// One-click install: writes the bridge script (chaining any existing
    /// statusLine.command as downstream) and merges the statusLine block
    /// into the user's settings.json. Backs the file up first; persists
    /// the original statusLine in a state file so uninstall can restore it.
    func installAuto() throws -> ClaudeUsageLimitAutoInstallResult

    /// Restores the user's settings.json to its pre-install state and
    /// removes the bridge script + state file. If settings.json no longer
    /// references our bridge (user edited it manually), only the bridge
    /// script and state file are removed.
    func uninstall() throws -> ClaudeUsageLimitUninstallResult

    /// Reads the persisted state file to determine the current install
    /// status; verifies the script file actually exists and that
    /// settings.json's statusLine still points at it.
    func currentStatus() -> ClaudeUsageLimitBridgeStatus

    /// Whether the on-disk bridge script is on the latest version. False
    /// when the file is missing the current version marker; callers can
    /// silently rewrite the script via ``upgradeScriptInPlace()``.
    func scriptNeedsUpgrade() -> Bool

    /// Rewrites just the bridge script (no settings.json touching), preserving
    /// the previously-recorded downstream chain. Safe to call on every launch
    /// when ``scriptNeedsUpgrade()`` is true — does not create new settings.json
    /// backups.
    func upgradeScriptInPlace() throws
}

struct ClaudeUsageLimitBridgeConfiguration: Sendable, Hashable {
    let scriptURL: URL
    let cacheURL: URL
    let settingsURL: URL
    let settingsSnippet: String
}

struct ClaudeUsageLimitAutoInstallResult: Sendable, Hashable {
    let scriptURL: URL
    let settingsURL: URL
    let settingsBackupURL: URL
    /// Whether the user had a statusLine before install — surfaced so the UI
    /// can mention "your existing status line is preserved as downstream".
    let preservedDownstreamCommand: String?
}

struct ClaudeUsageLimitUninstallResult: Sendable, Hashable {
    let didRestoreSettings: Bool
    let didRemoveScript: Bool
}

enum ClaudeUsageLimitBridgeStatus: Sendable, Hashable {
    /// Bridge is installed and settings.json points at it.
    case installed(downstreamCommand: String?)
    /// Bridge script and state exist but settings.json was changed externally.
    case orphaned
    case notInstalled
}

struct ClaudeUsageLimitBridgeInstaller: ClaudeUsageLimitBridgeInstalling {
    let paths: ClaudePaths
    private let scriptURLOverride: URL?
    private let cacheURLOverride: URL?

    init(paths: ClaudePaths = .default, scriptURL: URL? = nil, cacheURL: URL? = nil) {
        self.paths = paths
        self.scriptURLOverride = scriptURL
        self.cacheURLOverride = cacheURL
    }

    var scriptURL: URL { scriptURLOverride ?? UsageLimitCachePaths.claudeBridgeScriptURL() }
    var cacheURL: URL { cacheURLOverride ?? UsageLimitCachePaths.claudeCacheURL() }
    var settingsURL: URL { paths.configDirectory.appendingPathComponent("settings.json", isDirectory: false) }
    var stateURL: URL { UsageLimitCachePaths.claudeBridgeStateURL() }
    var backupsDirectory: URL { UsageLimitCachePaths.claudeBridgeBackupsDirectory() }

    // MARK: - Advanced path (legacy)

    func install() throws -> ClaudeUsageLimitBridgeConfiguration {
        try writeBridgeScript(downstreamCommand: nil)
        return ClaudeUsageLimitBridgeConfiguration(
            scriptURL: scriptURL,
            cacheURL: cacheURL,
            settingsURL: settingsURL,
            settingsSnippet: settingsSnippet()
        )
    }

    /// Shell command Claude Code should run for `statusLine`. Wrapped in
    /// `sh -c '...'`-friendly single quotes because Claude Code's command
    /// field is parsed by `/bin/sh -c`, and the script lives in
    /// `~/Library/Application Support/...` whose path has spaces.
    private var settingsCommand: String {
        "/bin/sh \(shellSingleQuoted(scriptURL.path))"
    }

    func settingsSnippet() -> String {
        """
        {
          "statusLine": {
            "type": "command",
            "command": "\(jsonEscaped(settingsCommand))"
          }
        }
        """
    }

    // MARK: - One-click install

    func installAuto() throws -> ClaudeUsageLimitAutoInstallResult {
        let fileManager = FileManager.default

        // Load existing settings.json (or empty document if absent).
        let existingData: Data? = fileManager.fileExists(atPath: settingsURL.path)
            ? try Data(contentsOf: settingsURL)
            : nil
        var rootObject: [String: Any]
        if let data = existingData, !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
                throw ClaudeBridgeInstallError.settingsJSONMalformed
            }
            rootObject = parsed
        } else {
            rootObject = [:]
        }

        // Detect existing statusLine.
        let existingStatusLine = rootObject["statusLine"] as? [String: Any]
        let existingCommand = existingStatusLine?["command"] as? String
        let alreadyOurs = existingCommand.map { Self.commandReferencesScript($0, scriptPath: scriptURL.path) } ?? false

        // Compute the downstream command to chain to. If the user already had
        // a statusLine that wasn't ours, that command becomes the downstream.
        // On reinstall (alreadyOurs), preserve the previously-saved downstream
        // from the state file so the chain doesn't get truncated.
        let downstreamCommand: String?
        if alreadyOurs {
            downstreamCommand = loadState()?.originalStatusLine?["command"] as? String
        } else {
            downstreamCommand = existingCommand
        }

        // Backup current settings.json (only if it exists and isn't already
        // ours — no point backing up our own previous install).
        let backupURL: URL
        if let data = existingData {
            try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            let stamp = Self.timestampString(for: .now)
            backupURL = backupsDirectory.appendingPathComponent("settings.json.\(stamp)", isDirectory: false)
            try data.write(to: backupURL, options: .atomic)
        } else {
            backupURL = backupsDirectory.appendingPathComponent("settings.json.absent", isDirectory: false)
        }

        // Persist state BEFORE modifying settings.json, so we can roll back
        // on failure mid-write.
        if !alreadyOurs {
            let state = BridgeState(
                installedAt: .now,
                settingsBackupPath: existingData != nil ? backupURL.path : nil,
                originalStatusLine: existingStatusLine
            )
            try writeState(state)
        }

        // Write the bridge script (with downstream chain inlined).
        try writeBridgeScript(downstreamCommand: downstreamCommand)

        // Merge statusLine into the JSON tree.
        var newStatusLine: [String: Any] = [
            "type": "command",
            "command": settingsCommand,
        ]
        // Preserve padding/refreshInterval/etc. that the user had configured.
        if let existingStatusLine {
            for (key, value) in existingStatusLine where key != "type" && key != "command" {
                newStatusLine[key] = value
            }
        }
        rootObject["statusLine"] = newStatusLine

        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outputData = try JSONSerialization.data(
            withJSONObject: rootObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try outputData.write(to: settingsURL, options: .atomic)

        return ClaudeUsageLimitAutoInstallResult(
            scriptURL: scriptURL,
            settingsURL: settingsURL,
            settingsBackupURL: backupURL,
            preservedDownstreamCommand: downstreamCommand
        )
    }

    // MARK: - Uninstall

    func uninstall() throws -> ClaudeUsageLimitUninstallResult {
        let fileManager = FileManager.default
        let state = loadState()

        var didRestoreSettings = false
        if fileManager.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL),
           var rootObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] {
            let currentStatusLine = rootObject["statusLine"] as? [String: Any]
            let currentCommand = currentStatusLine?["command"] as? String
            if let cmd = currentCommand, Self.commandReferencesScript(cmd, scriptPath: scriptURL.path) {
                // Restore: if state has a snapshot, put it back; otherwise drop.
                if let original = state?.originalStatusLine {
                    rootObject["statusLine"] = original
                } else {
                    rootObject.removeValue(forKey: "statusLine")
                }
                let outputData = try JSONSerialization.data(
                    withJSONObject: rootObject,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                try outputData.write(to: settingsURL, options: .atomic)
                didRestoreSettings = true
            }
        }

        var didRemoveScript = false
        if fileManager.fileExists(atPath: scriptURL.path) {
            try fileManager.removeItem(at: scriptURL)
            didRemoveScript = true
        }
        if fileManager.fileExists(atPath: stateURL.path) {
            try? fileManager.removeItem(at: stateURL)
        }

        return ClaudeUsageLimitUninstallResult(
            didRestoreSettings: didRestoreSettings,
            didRemoveScript: didRemoveScript
        )
    }

    // MARK: - Status

    func currentStatus() -> ClaudeUsageLimitBridgeStatus {
        let fileManager = FileManager.default
        let state = loadState()
        let scriptExists = fileManager.fileExists(atPath: scriptURL.path)
        let stateExists = state != nil

        guard scriptExists, stateExists else { return .notInstalled }

        // Verify settings.json still points at us.
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let statusLine = root["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              Self.commandReferencesScript(command, scriptPath: scriptURL.path)
        else {
            return .orphaned
        }

        let downstream = state?.originalStatusLine?["command"] as? String
        return .installed(downstreamCommand: downstream)
    }

    // MARK: - Version upgrade

    func scriptNeedsUpgrade() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              let content = try? String(contentsOf: scriptURL, encoding: .utf8)
        else { return false }
        return !content.contains(Self.scriptVersionMarker)
    }

    func upgradeScriptInPlace() throws {
        let downstream = loadState()?.originalStatusLine?["command"] as? String
        try writeBridgeScript(downstreamCommand: downstream)
    }

    // MARK: - State persistence

    private struct BridgeState: Codable {
        var installedAt: Date
        var settingsBackupPath: String?
        var originalStatusLine: [String: Any]?

        private enum CodingKeys: String, CodingKey {
            case installedAt
            case settingsBackupPath
            case originalStatusLine
        }

        init(installedAt: Date, settingsBackupPath: String?, originalStatusLine: [String: Any]?) {
            self.installedAt = installedAt
            self.settingsBackupPath = settingsBackupPath
            self.originalStatusLine = originalStatusLine
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installedAt = try container.decode(Date.self, forKey: .installedAt)
            settingsBackupPath = try container.decodeIfPresent(String.self, forKey: .settingsBackupPath)
            if let raw = try container.decodeIfPresent(Data.self, forKey: .originalStatusLine) {
                originalStatusLine = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? [String: Any]
            } else {
                originalStatusLine = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(installedAt, forKey: .installedAt)
            try container.encodeIfPresent(settingsBackupPath, forKey: .settingsBackupPath)
            if let originalStatusLine {
                let raw = try JSONSerialization.data(withJSONObject: originalStatusLine, options: [.sortedKeys])
                try container.encode(raw, forKey: .originalStatusLine)
            }
        }
    }

    private func writeState(_ state: BridgeState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func loadState() -> BridgeState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BridgeState.self, from: data)
    }

    // MARK: - Bridge script

    private func writeBridgeScript(downstreamCommand: String?) throws {
        let directory = scriptURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try bridgeScript(cacheURL: cacheURL, downstreamCommand: downstreamCommand)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    /// Bumped whenever the generated script's behaviour changes. The app
    /// re-installs the script on launch when the on-disk copy is missing
    /// this marker (or has a lower version).
    ///
    /// v5: same-window reconciliation keeps the max only for 60s from the
    ///     per-window high-water capture timestamp, and serializes
    ///     reconcile+replace with a short-lived lock. This prevents stale lower
    ///     writes from concurrent sessions overwriting a fresher high-water mark
    ///     before the app polls it, while still allowing real provider-side
    ///     decreases to show within the one-minute cache budget.
    static let scriptVersion = 5
    static let scriptVersionMarker = "# Bridge script version: 5"

    private func bridgeScript(cacheURL: URL, downstreamCommand: String?) -> String {
        let cachePath = shellSingleQuoted(cacheURL.path)
        let downstream = downstreamCommand.map { shellSingleQuoted($0) } ?? "''"
        return """
        #!/bin/sh
        # Generated by CCBar. Do not edit by hand — uninstall from the
        # app and reinstall if you want a different downstream command.
        \(Self.scriptVersionMarker)
        #
        # Multiple Claude Code sessions each emit their own statusLine with
        # their session-local view of rate_limits.five_hour.used_percentage.
        # Within the same quota window (same resets_at) these can disagree by
        # 20+ percentage points depending on each session's reporting lag.
        # Some stale background sessions even keep emitting yesterday's
        # resets_at after the user has moved on. The cache reconciliation
        # strategy (v5):
        #   - DROP the write entirely if its resets_at is OLDER than the
        #     cached one (stale session hasn't seen reset)
        #   - when resets_at matches, keep the max used_percentage for up to
        #     60s from the first time that high-water value was captured, so a
        #     lagging session cannot erase a fresher high before CCBar polls
        #     the cache
        #   - after that 60s high-water budget, accept the new value so real
        #     provider-side decreases are not pinned
        #   - ADOPT the new value verbatim when resets_at advances (real
        #     window rollover)
        # Reconcile and replace run under a short-lived mkdir lock so
        # concurrent statusLine processes cannot clobber fresher cache writes.
        # Cross-session 1s-level flicker is also dampened by Swift's
        # UsageLimitStore.stabilize 60s rolling max on the consumer side.
        set -eu

        CACHE=\(cachePath)
        DOWNSTREAM=\(downstream)
        DIR=$(/usr/bin/dirname "$CACHE")
        TMP="${CACHE}.$$"
        INPUT_FILE="${CACHE}.in.$$"
        NEW_FILE="${CACHE}.new.$$"
        LOCK_DIR="${CACHE}.lock"
        LOCK_HELD=0

        cleanup() {
          /bin/rm -f "$TMP" "$INPUT_FILE" "$NEW_FILE" 2>/dev/null || true
          if [ "$LOCK_HELD" -eq 1 ]; then
            /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
          fi
        }
        trap cleanup EXIT

        INPUT=$(/bin/cat)
        /bin/mkdir -p "$DIR"

        # Stash stdin so plutil can re-extract individual scalars below.
        /usr/bin/printf "%s" "$INPUT" > "$INPUT_FILE"

        # Pull the rate_limits subtree. Empty/null exits silently.
        if ! /usr/bin/plutil -extract rate_limits json -o "$NEW_FILE" "$INPUT_FILE" 2>/dev/null; then
          if [ -n "$DOWNSTREAM" ]; then
            /usr/bin/printf "%s" "$INPUT" | /bin/sh -c "$DOWNSTREAM"
          fi
          exit 0
        fi
        if [ ! -s "$NEW_FILE" ] || /usr/bin/grep -qx 'null' "$NEW_FILE"; then
          if [ -n "$DOWNSTREAM" ]; then
            /usr/bin/printf "%s" "$INPUT" | /bin/sh -c "$DOWNSTREAM"
          fi
          exit 0
        fi

        acquire_lock() {
          attempts=0
          while ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; do
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 20 ]; then
              /usr/bin/printf "%s\\n" "CCBar Claude usage bridge: timed out waiting for cache lock" >&2
              return 1
            fi
            /bin/sleep 0.1
          done
          LOCK_HELD=1
          return 0
        }

        release_lock() {
          if [ "$LOCK_HELD" -eq 1 ]; then
            /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
            LOCK_HELD=0
          fi
        }

        stamp_capture_time() {
          key="$1"
          captured_at="$2"
          /usr/bin/plutil -replace "$key"._ccbar_high_water_captured_at -integer "$captured_at" "$NEW_FILE" 2>/dev/null || true
        }

        # Reconcile a single window against the cached value.
        # Outcomes (per window, written into NEW_FILE):
        #   - cache missing / no new value → no-op (leaves whatever was in NEW_FILE)
        #   - same resets_at + high-water captured <=60s ago → max(old, new)
        #   - same resets_at + high-water captured >60s ago → no-op (accept new)
        #   - resets_at moved backwards → restore cached value (this window's
        #     write came from a stale session that hasn't seen the reset yet)
        #   - resets_at moved forward → no-op (accept new — real window rollover)
        reconcile_window() {
          key="$1"
          new_used=$(/usr/bin/plutil -extract "$key".used_percentage raw -o - "$NEW_FILE" 2>/dev/null || true)
          new_reset=$(/usr/bin/plutil -extract "$key".resets_at raw -o - "$NEW_FILE" 2>/dev/null || true)
          if [ -z "$new_used" ] || [ -z "$new_reset" ]; then return; fi
          now_epoch=$(/bin/date +%s)
          if [ ! -f "$CACHE" ]; then
            stamp_capture_time "$key" "$now_epoch"
            return
          fi
          old_used=$(/usr/bin/plutil -extract "$key".used_percentage raw -o - "$CACHE" 2>/dev/null || true)
          old_reset=$(/usr/bin/plutil -extract "$key".resets_at raw -o - "$CACHE" 2>/dev/null || true)
          if [ -z "$old_used" ] || [ -z "$old_reset" ]; then
            stamp_capture_time "$key" "$now_epoch"
            return
          fi
          old_captured_at=$(/usr/bin/plutil -extract "$key"._ccbar_high_water_captured_at raw -o - "$CACHE" 2>/dev/null || true)
          if [ -z "$old_captured_at" ]; then
            old_captured_at=$(/usr/bin/stat -f %m "$CACHE" 2>/dev/null || /usr/bin/printf "%s" "$now_epoch")
          fi
          reset_cmp=$(/usr/bin/awk -v a="$old_reset" -v b="$new_reset" 'BEGIN {
            if (a == b) print "eq"
            else if (a ~ /^[0-9.]+$/ && b ~ /^[0-9.]+$/) print (a+0 > b+0) ? "gt" : "lt"
            else print (a > b) ? "gt" : "lt"
          }')
          case "$reset_cmp" in
            eq)
              used_cmp=$(/usr/bin/awk -v a="$old_used" -v b="$new_used" 'BEGIN { if (a+0 > b+0) print "gt"; else if (a+0 < b+0) print "lt"; else print "eq" }')
              case "$used_cmp" in
                gt)
                  high_age=$((now_epoch - old_captured_at))
                  if [ "$high_age" -le 60 ]; then
                    /usr/bin/plutil -replace "$key".used_percentage -float "$old_used" "$NEW_FILE" 2>/dev/null || true
                    stamp_capture_time "$key" "$old_captured_at"
                  else
                    stamp_capture_time "$key" "$now_epoch"
                  fi
                  ;;
                lt)
                  stamp_capture_time "$key" "$now_epoch"
                  ;;
                eq)
                  stamp_capture_time "$key" "$old_captured_at"
                  ;;
              esac
              ;;
            gt)
              # Cached reset is LATER than this write's — this write came
              # from a stale session that hasn't seen the new window. Pin
              # the cached (more recent) values back into NEW_FILE so the
              # write below doesn't lose ground.
              /usr/bin/plutil -replace "$key".used_percentage -float "$old_used" "$NEW_FILE" 2>/dev/null || true
              /usr/bin/plutil -replace "$key".resets_at -integer "$old_reset" "$NEW_FILE" 2>/dev/null || true
              stamp_capture_time "$key" "$old_captured_at"
              ;;
            lt)
              # New reset is later than cached → real window rollover, accept
              # the new values verbatim (no replace needed).
              stamp_capture_time "$key" "$now_epoch"
              ;;
          esac
        }

        if acquire_lock; then
          reconcile_window five_hour
          reconcile_window seven_day

          /bin/cp "$NEW_FILE" "$TMP"
          /bin/mv "$TMP" "$CACHE"
          release_lock
        fi

        if [ -n "$DOWNSTREAM" ]; then
          /usr/bin/printf "%s" "$INPUT" | /bin/sh -c "$DOWNSTREAM"
        fi

        exit 0
        """
    }
    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func jsonEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Whether a settings.json `command` string refers to our bridge script.
    /// Matches both the legacy raw-path form (which is broken when the path
    /// contains spaces, but might still be present in older installs) and
    /// the current `/bin/sh '<path>'` form.
    private static func commandReferencesScript(_ command: String, scriptPath: String) -> Bool {
        command == scriptPath || command.contains(scriptPath)
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

enum ClaudeBridgeInstallError: LocalizedError {
    case settingsJSONMalformed

    var errorDescription: String? {
        switch self {
        case .settingsJSONMalformed:
            return L10n.string(
                "usage.limit.bridge.error.malformed_settings",
                defaultValue: "Could not parse ~/.claude/settings.json. Fix the JSON syntax first."
            )
        }
    }
}
