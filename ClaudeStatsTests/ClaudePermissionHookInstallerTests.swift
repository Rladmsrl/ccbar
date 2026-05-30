import Foundation
import Testing
@testable import ClaudeStats

@Suite("Claude permission hook installer")
struct ClaudePermissionHookInstallerTests {

    @Test("Install round-trip preserves foreign hooks and uninstall fully restores them")
    func roundTripPreservesForeignHooks() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        // Seed settings.json with a foreign SessionStart hook the user owns.
        let settingsURL = root.appendingPathComponent("settings.json", isDirectory: false)
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": "/usr/bin/whoami"],
            "hooks": [
                "SessionStart": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "/tmp/user-own-hook.sh"]
                        ],
                    ],
                ],
            ],
        ]
        try writeJSON(original, to: settingsURL)

        // Tests need to write the bridge script + state somewhere disposable,
        // but ClaudePermissionHookInstaller uses static PermissionHookPaths
        // for those. The script/state live under
        // ~/Library/Application Support/CCBar/PermissionHooks/ no
        // matter what — clean those up at the end so subsequent tests start
        // fresh. (Project-local stubs would be a bigger refactor.)
        let scriptURL = PermissionHookPaths.hookScriptURL()
        let stateURL = PermissionHookPaths.stateURL()
        let priorScriptData = try? Data(contentsOf: scriptURL)
        let priorStateData = try? Data(contentsOf: stateURL)
        // Important: wipe any pre-existing state from a real install, or
        // the installer's "reinstall — preserve saved originalHooks" branch
        // will graft this user's actual ~/.claude/settings.json hooks into
        // the test's expected snapshot.
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: stateURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: stateURL)
            if let priorScriptData {
                try? priorScriptData.write(to: scriptURL, options: .atomic)
            }
            if let priorStateData {
                try? priorStateData.write(to: stateURL, options: .atomic)
            }
        }

        let installer = ClaudePermissionHookInstaller(paths: ClaudePaths(configDirectory: root))
        let result = try installer.install(port: 23333)
        #expect(result.addedEvents.contains("PermissionRequest"))
        #expect(result.addedEvents.contains("SessionStart")) // appended alongside user's existing entry
        #expect(result.preservedExistingHookCount >= 1)

        // Re-read and check the user's hook is still there.
        let installedJSON = try readJSON(from: settingsURL)
        let installedHooks = installedJSON["hooks"] as! [String: Any]
        let installedSessionStart = installedHooks["SessionStart"] as! [Any]
        #expect(installedSessionStart.count == 2) // user's + ours
        let permissionEntries = installedHooks["PermissionRequest"] as! [Any]
        #expect(permissionEntries.count == 1)

        // statusLine untouched.
        #expect((installedJSON["statusLine"] as? [String: Any])?["command"] as? String == "/usr/bin/whoami")

        // Uninstall.
        let uninstall = try installer.uninstall()
        #expect(uninstall.didRemoveScript)
        let restoredJSON = try readJSON(from: settingsURL)
        let restoredHooks = restoredJSON["hooks"] as! [String: Any]
        let restoredSessionStart = restoredHooks["SessionStart"] as! [Any]
        #expect(restoredSessionStart.count == 1) // only the user's hook is left
        #expect(restoredHooks["PermissionRequest"] == nil)
    }

    @Test("Bridge script contains the version marker")
    func bridgeScriptHasVersionMarker() {
        let script = ClaudePermissionHookInstaller.bridgeScript(
            tokenFilePath: "/tmp/token",
            portFilePath: "/tmp/port"
        )
        #expect(script.contains(ClaudePermissionHookInstaller.scriptVersionMarker))
        #expect(script.contains("/tmp/port"))
    }

    @Test("mergeCommandHook leaves existing foreign entries alone")
    func mergeCommandHookPreservesForeign() {
        let existing: Any = [
            [
                "matcher": "",
                "hooks": [["type": "command", "command": "/tmp/user.sh"]] as [Any],
            ] as [String: Any],
        ] as [Any]
        let result = ClaudePermissionHookInstaller.mergeCommandHook(
            into: existing,
            scriptPath: "/path/to/claude-permission-hook.sh",
            event: "SessionStart"
        )
        let arr = result.value as! [Any]
        #expect(arr.count == 2)
        #expect(result.preservedCount == 1)
        #expect(result.wasNew)
    }

    @Test("Reinstalling on top of our own entry doesn't duplicate")
    func reinstallDoesNotDuplicate() {
        let script = "/path/to/claude-permission-hook.sh"
        let first = ClaudePermissionHookInstaller.mergeCommandHook(into: nil, scriptPath: script, event: "Stop")
        let second = ClaudePermissionHookInstaller.mergeCommandHook(into: first.value, scriptPath: script, event: "Stop")
        #expect((second.value as! [Any]).count == 1)
        #expect(second.changed == false)
    }

    @Test("install with .stateHooks only installs state events, leaves PermissionRequest alone")
    func installStateOnlyLeavesPermissionRequest() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        // Seed settings.json with a foreign PermissionRequest hook (ensoai-style).
        let settingsURL = root.appendingPathComponent("settings.json", isDirectory: false)
        let original: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "/tmp/ensoai-hook.cjs"]
                        ],
                    ],
                ],
            ],
        ]
        try writeJSON(original, to: settingsURL)

        let scriptURL = PermissionHookPaths.hookScriptURL()
        let stateURL = PermissionHookPaths.stateURL()
        let priorScriptData = try? Data(contentsOf: scriptURL)
        let priorStateData = try? Data(contentsOf: stateURL)
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: stateURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: stateURL)
            if let priorScriptData { try? priorScriptData.write(to: scriptURL, options: .atomic) }
            if let priorStateData { try? priorStateData.write(to: stateURL, options: .atomic) }
        }

        let installer = ClaudePermissionHookInstaller(paths: ClaudePaths(configDirectory: root))
        let result = try installer.install(port: 23333, options: .stateHooks)

        // State events should be added.
        #expect(result.addedEvents.contains("SessionStart"))
        #expect(result.addedEvents.contains("UserPromptSubmit"))
        // PermissionRequest should NOT appear in addedEvents or updatedEvents.
        #expect(!result.addedEvents.contains("PermissionRequest"))
        #expect(!result.updatedEvents.contains("PermissionRequest"))

        // Foreign PermissionRequest hook must still be intact.
        let installedJSON = try readJSON(from: settingsURL)
        let installedHooks = installedJSON["hooks"] as! [String: Any]
        let permissionEntries = installedHooks["PermissionRequest"] as! [Any]
        #expect(permissionEntries.count == 1)
        let firstEntry = permissionEntries[0] as! [String: Any]
        let hooks = firstEntry["hooks"] as! [[String: Any]]
        #expect(hooks[0]["command"] as? String == "/tmp/ensoai-hook.cjs")
    }

    @Test("uninstall with .permissionHook only removes PermissionRequest, leaves state hooks intact")
    func uninstallPermissionOnlyLeavesStateHooks() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let settingsURL = root.appendingPathComponent("settings.json", isDirectory: false)
        try writeJSON(["hooks": [:]], to: settingsURL)

        let scriptURL = PermissionHookPaths.hookScriptURL()
        let stateURL = PermissionHookPaths.stateURL()
        let priorScriptData = try? Data(contentsOf: scriptURL)
        let priorStateData = try? Data(contentsOf: stateURL)
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: stateURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: stateURL)
            if let priorScriptData { try? priorScriptData.write(to: scriptURL, options: .atomic) }
            if let priorStateData { try? priorStateData.write(to: stateURL, options: .atomic) }
        }

        let installer = ClaudePermissionHookInstaller(paths: ClaudePaths(configDirectory: root))
        // First install everything.
        _ = try installer.install(port: 23333, options: .all)

        // Then uninstall just the permission hook.
        _ = try installer.uninstall(options: .permissionHook)

        let json = try readJSON(from: settingsURL)
        let hooks = json["hooks"] as! [String: Any]
        // PermissionRequest gone.
        #expect(hooks["PermissionRequest"] == nil)
        // State events still installed.
        #expect(hooks["SessionStart"] != nil)
        #expect(hooks["UserPromptSubmit"] != nil)
        // Script must still exist (state hooks still rely on it).
        #expect(FileManager.default.fileExists(atPath: scriptURL.path))
    }

    @Test("Foreign PermissionRequest hook is restored after partial .permissionHook uninstall")
    func restoreForeignPermissionHookOnPartialUninstall() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        // Seed settings.json with a foreign ensoai-style PermissionRequest hook.
        let settingsURL = root.appendingPathComponent("settings.json", isDirectory: false)
        let original: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": "/tmp/ensoai-hook.cjs"]
                        ],
                    ],
                ],
            ],
        ]
        try writeJSON(original, to: settingsURL)

        let scriptURL = PermissionHookPaths.hookScriptURL()
        let stateURL = PermissionHookPaths.stateURL()
        let priorScriptData = try? Data(contentsOf: scriptURL)
        let priorStateData = try? Data(contentsOf: stateURL)
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: stateURL)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: stateURL)
            if let priorScriptData { try? priorScriptData.write(to: scriptURL, options: .atomic) }
            if let priorStateData { try? priorStateData.write(to: stateURL, options: .atomic) }
        }

        let installer = ClaudePermissionHookInstaller(paths: ClaudePaths(configDirectory: root))
        // 1. Full install — CCBar's PermissionRequest replaces foreign hook,
        //    original ensoai entry is preserved verbatim in state.originalHooks.
        _ = try installer.install(port: 23333, options: .all)
        let installedJSON = try readJSON(from: settingsURL)
        let installedPermission = (installedJSON["hooks"] as! [String: Any])["PermissionRequest"] as! [Any]
        let installedFirstEntry = installedPermission[0] as! [String: Any]
        let installedHooks = installedFirstEntry["hooks"] as! [[String: Any]]
        #expect(installedHooks[0]["type"] as? String == "http") // CCBar's HTTP hook in place

        // 2. Partial uninstall: just the permission hook.
        _ = try installer.uninstall(options: .permissionHook)

        // 3. Foreign ensoai PermissionRequest must be restored.
        let restoredJSON = try readJSON(from: settingsURL)
        let restoredHooks = restoredJSON["hooks"] as! [String: Any]
        let restoredPermission = restoredHooks["PermissionRequest"] as! [Any]
        #expect(restoredPermission.count == 1)
        let firstEntry = restoredPermission[0] as! [String: Any]
        let hooks = firstEntry["hooks"] as! [[String: Any]]
        #expect(hooks[0]["command"] as? String == "/tmp/ensoai-hook.cjs")

        // 4. State hooks should still be in place since we didn't uninstall them.
        #expect(restoredHooks["SessionStart"] != nil)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! [String: Any]
    }
}
