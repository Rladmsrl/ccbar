import Foundation
import Testing
@testable import ClaudeStats

struct CLIEnvironmentCheckerTests {
    @Test("Version parser extracts semver and falls back to raw output")
    func versionParserExtractsSemverAndFallsBack() {
        #expect(CLIEnvironmentChecker.extractVersion(from: "claude 2.1.43\n") == "2.1.43")
        #expect(CLIEnvironmentChecker.extractVersion(from: "codex-cli 1.2.3-beta.1") == "1.2.3-beta.1")
        #expect(CLIEnvironmentChecker.extractVersion(from: "nightly channel") == "nightly channel")
    }

    @Test("Tool status only marks semver-behind installs as outdated")
    func toolStatusOnlyMarksSemverBehindInstallsAsOutdated() {
        let behind = CLIToolStatus(cli: .claude, command: "claude", version: "2.1.43", latestVersion: "2.1.44", error: nil, diagnostic: nil, envType: .macOS, executablePath: nil)
        let current = CLIToolStatus(cli: .claude, command: "claude", version: "2.1.44", latestVersion: "2.1.44", error: nil, diagnostic: nil, envType: .macOS, executablePath: nil)
        let ahead = CLIToolStatus(cli: .claude, command: "claude", version: "2.1.45", latestVersion: "2.1.44", error: nil, diagnostic: nil, envType: .macOS, executablePath: nil)
        let raw = CLIToolStatus(cli: .claude, command: "claude", version: "nightly channel", latestVersion: "2.1.44", error: nil, diagnostic: nil, envType: .macOS, executablePath: nil)

        #expect(behind.isOutdated)
        #expect(!current.isOutdated)
        #expect(!ahead.isOutdated)
        #expect(!raw.isOutdated)
    }

    @Test("Local detection falls back to scanned CLI paths")
    func localDetectionFallsBackToScannedPaths() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let executable = dir.appendingPathComponent(".volta/bin/claude", isDirectory: false)
        try TempDir.write("", to: executable)

        let runner: CLIEnvironmentChecker.ProcessRunner = { invocation in
            if invocation.executablePath == executable.path {
                return CLIVersionProcessResult(exitCode: 0, stdout: "Claude Code 2.1.43\n", stderr: "", launchError: nil, timedOut: false)
            }
            return CLIVersionProcessResult(exitCode: 127, stdout: "", stderr: "missing", launchError: nil, timedOut: false)
        }
        let checker = CLIEnvironmentChecker(
            rootDirectory: dir.appendingPathComponent("APIProviders", isDirectory: true),
            homeDirectory: dir,
            environment: ["SHELL": "/bin/zsh", "PATH": ""],
            shellConfigFiles: [],
            processRunner: runner,
            latestVersionFetcher: { cli in cli == .claude ? "2.1.44" : nil }
        )

        let status = await checker.toolStatus(for: .claude)

        #expect(status.version == "2.1.43")
        #expect(status.latestVersion == "2.1.44")
        #expect(status.executablePath == executable.path)
        #expect(status.isOutdated)
    }

    @Test("Missing CLI reports a uniform user-facing error")
    func missingCLIReportsUniformError() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let checker = CLIEnvironmentChecker(
            rootDirectory: dir.appendingPathComponent("APIProviders", isDirectory: true),
            homeDirectory: dir,
            environment: ["SHELL": "/bin/zsh", "PATH": ""],
            shellConfigFiles: [],
            processRunner: { _ in
                CLIVersionProcessResult(exitCode: 127, stdout: "", stderr: "command not found", launchError: nil, timedOut: false)
            },
            latestVersionFetcher: { _ in nil }
        )

        let status = await checker.toolStatus(for: .claude)

        #expect(status.version == nil)
        #expect(status.error == "not installed or not executable")
        #expect(status.diagnostic == "command not found")
    }

    @Test("Environment scan finds process and shell-file conflicts")
    func environmentScanFindsProcessAndShellFileConflicts() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let zshrc = dir.appendingPathComponent(".zshrc", isDirectory: false)
        try TempDir.write(
            """
            export ANTHROPIC_BASE_URL="https://gateway.example"
            # export ANTHROPIC_API_KEY=ignored
            OPENAI_API_KEY='sk-openai'
            OTHER_VALUE=1

            """,
            to: zshrc
        )
        let checker = CLIEnvironmentChecker(
            rootDirectory: dir.appendingPathComponent("APIProviders", isDirectory: true),
            homeDirectory: dir,
            environment: [
                "ANTHROPIC_AUTH_TOKEN": "sk-process",
                "OPENAI_PROFILE": "work",
                "PATH": "",
            ],
            shellConfigFiles: [zshrc],
            processRunner: { _ in CLIVersionProcessResult(exitCode: 127, stdout: "", stderr: "", launchError: nil, timedOut: false) },
            latestVersionFetcher: { _ in nil }
        )

        let conflicts = await checker.scanConflicts()

        #expect(conflicts.contains { $0.cli == .claude && $0.varName == "ANTHROPIC_AUTH_TOKEN" && $0.sourceType == .process })
        #expect(conflicts.contains { $0.cli == .claude && $0.varName == "ANTHROPIC_BASE_URL" && $0.lineNumber == 1 && $0.isDeletable })
        #expect(!conflicts.contains { $0.varValue == "ignored" })
    }

    @Test("Deleting conflicts backs up files and removes exact lines")
    func deletingConflictsBacksUpFilesAndRemovesExactLines() async throws {
        let dir = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        let root = dir.appendingPathComponent("APIProviders", isDirectory: true)
        let profile = dir.appendingPathComponent(".zprofile", isDirectory: false)
        try TempDir.write(
            """
            export ANTHROPIC_AUTH_TOKEN=sk-anthropic
            KEEP_ME=1
            ANTHROPIC_BASE_URL=https://gateway.example

            """,
            to: profile
        )
        let checker = CLIEnvironmentChecker(
            rootDirectory: root,
            homeDirectory: dir,
            environment: [:],
            shellConfigFiles: [profile],
            processRunner: { _ in CLIVersionProcessResult(exitCode: 127, stdout: "", stderr: "", launchError: nil, timedOut: false) },
            latestVersionFetcher: { _ in nil }
        )
        let conflicts = await checker.scanConflicts()

        let result = try await checker.deleteConflicts(conflicts)
        let updated = try String(contentsOf: profile, encoding: .utf8)

        #expect(result.deletedConflictIDs.count == 2)
        #expect(result.skippedConflicts.isEmpty)
        #expect(updated.contains("KEEP_ME=1"))
        #expect(!updated.contains("ANTHROPIC_AUTH_TOKEN"))
        #expect(!updated.contains("ANTHROPIC_BASE_URL"))
        #expect(FileManager.default.fileExists(atPath: result.backupDirectory.appendingPathComponent(".zprofile").path))
        #expect(FileManager.default.fileExists(atPath: result.backupDirectory.appendingPathComponent("manifest.json").path))
    }
}

@MainActor
struct CLIEnvironmentViewModelTests {
    @Test("loadIfNeeded only loads once and refresh forces a rerun")
    func loadIfNeededOnlyLoadsOnceAndRefreshForcesRerun() async throws {
        let checker = CountingCLIEnvironmentChecker(
            snapshot: CLIEnvironmentSnapshot(
                statuses: [CLIToolStatus(cli: .claude, command: "claude", version: "2.1.43", latestVersion: nil, error: nil, diagnostic: nil, envType: .macOS, executablePath: nil)],
                conflicts: []
            )
        )
        let vm = CLIEnvironmentViewModel(checker: checker)

        await vm.loadIfNeeded()
        await vm.loadIfNeeded()
        #expect(await checker.checkCount == 1)

        await vm.refresh()
        #expect(await checker.checkCount == 2)
    }

    @Test("Deleting selected conflicts stores cleanup result and refreshes")
    func deletingSelectedConflictsStoresResultAndRefreshes() async throws {
        let conflict = CLIEnvironmentConflict(
            cli: .claude,
            varName: "ANTHROPIC_API_KEY",
            varValue: "sk-test",
            sourceType: .file,
            sourcePath: "/tmp/.zshrc",
            lineNumber: 1,
            isDeletable: true
        )
        let checker = MutableCLIEnvironmentChecker(conflict: conflict)
        let vm = CLIEnvironmentViewModel(checker: checker)

        await vm.refresh()
        vm.toggleSelection(conflict)
        await vm.deleteSelectedConflicts()

        #expect(vm.conflicts.isEmpty)
        #expect(vm.latestCleanupResult?.deletedConflictIDs == [conflict.id])
        #expect(await checker.deleteCount == 1)
    }
}

private actor CountingCLIEnvironmentChecker: CLIEnvironmentChecking {
    private let snapshot: CLIEnvironmentSnapshot
    private var count = 0

    init(snapshot: CLIEnvironmentSnapshot) {
        self.snapshot = snapshot
    }

    var checkCount: Int { count }

    func checkAll() async throws -> CLIEnvironmentSnapshot {
        count += 1
        return snapshot
    }

    func deleteConflicts(_ conflicts: [CLIEnvironmentConflict]) async throws -> CLIEnvironmentCleanupResult {
        CLIEnvironmentCleanupResult(backupDirectory: URL(fileURLWithPath: "/tmp"), deletedConflictIDs: conflicts.map(\.id), skippedConflicts: [])
    }
}

private actor MutableCLIEnvironmentChecker: CLIEnvironmentChecking {
    private var conflict: CLIEnvironmentConflict?
    private var deletes = 0

    init(conflict: CLIEnvironmentConflict) {
        self.conflict = conflict
    }

    var deleteCount: Int { deletes }

    func checkAll() async throws -> CLIEnvironmentSnapshot {
        CLIEnvironmentSnapshot(statuses: [], conflicts: conflict.map { [$0] } ?? [])
    }

    func deleteConflicts(_ conflicts: [CLIEnvironmentConflict]) async throws -> CLIEnvironmentCleanupResult {
        deletes += 1
        let deletedIDs = conflicts.map(\.id)
        conflict = nil
        return CLIEnvironmentCleanupResult(backupDirectory: URL(fileURLWithPath: "/tmp/env-backup"), deletedConflictIDs: deletedIDs, skippedConflicts: [])
    }
}
