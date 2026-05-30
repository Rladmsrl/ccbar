import AppKit
import Darwin
import Foundation

/// Activates the terminal tab hosting a foreground Claude Code session.
///
/// **Resolution flow**
///   1. From the hook-reported `sourcePid` (the `claude` process), look up
///      the controlling tty with `ps -o tty=`.
///   2. Walk up the process tree until we hit one of the known terminal
///      app bundle ids. That tells us which AppleScript dialect to use.
///   3. Run the AppleScript that selects the matching tab + activates the
///      app. On macOS 14+ this needs the **Automation** privacy prompt
///      (granted per terminal app the first time we ask).
///
/// Errors flow back via the returned `Result`. The current caller in
/// `LiveSessionRow.focusSession` only logs failures via `Log.session.error`
/// — there's no toast UI surface yet, so silent-on-failure is the
/// behavior to expect until one is added.
struct SessionFocusService: Sendable {

    enum FocusError: LocalizedError {
        case noSourcePid
        case ttyNotFound
        case unsupportedTerminal(bundleId: String?)
        case appleScriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSourcePid:
                return "This session didn't report a PID — re-run the Claude CLI after installing the hook."
            case .ttyNotFound:
                return "Couldn't find the terminal device for this PID. The process may have exited."
            case .unsupportedTerminal(let bundleId):
                return "Don't know how to focus tabs in \(bundleId ?? "this terminal")."
            case .appleScriptFailed(let message):
                return "Terminal focus failed: \(message)"
            }
        }
    }

    /// Bundle ids of terminal apps we know how to script.
    enum TerminalApp: String {
        case appleTerminal = "com.apple.Terminal"
        case iTerm2 = "com.googlecode.iterm2"
        case ghostty = "com.mitchellh.ghostty"
        case warp = "dev.warp.Warp-Stable"
    }

    /// Resolve the tab + activate. Pure function returning a result; the
    /// caller decides how to surface success / failure.
    ///
    /// Runs entirely on the MainActor: `NSAppleScript` and `NSWorkspace`
    /// are both documented main-thread-only, and AppleScript dispatch
    /// also pumps the Automation TCC prompt — so the brief UI hitch is
    /// unavoidable, but the alternative (running off main) risks
    /// generic-error / undocumented behavior. Keep this `async` so
    /// future callers can `await` without blocking themselves.
    @MainActor
    func focus(session: LiveSession) async -> Result<Void, FocusError> {
        guard let sourcePid = session.sourcePid,
              let pid = pid_t(exactly: sourcePid),
              pid > 0
        else {
            return .failure(.noSourcePid)
        }
        guard let tty = Self.ttyName(for: pid) else {
            return .failure(.ttyNotFound)
        }
        guard let terminal = Self.terminalAppOwning(pid: pid) else {
            return .failure(.unsupportedTerminal(bundleId: nil))
        }
        switch terminal {
        case .appleTerminal:
            return Self.runAppleScript(Self.appleTerminalScript(tty: tty))
        case .iTerm2:
            return Self.runAppleScript(Self.iTerm2Script(tty: tty))
        case .ghostty:
            // Ghostty doesn't expose tabs via AppleScript; bring it to the
            // front and let the user pick the tab. Better than nothing.
            return Self.runAppleScript(Self.activateAppScript(bundleId: TerminalApp.ghostty.rawValue))
        case .warp:
            // Warp's AppleScript dictionary is minimal; same fallback as Ghostty.
            return Self.runAppleScript(Self.activateAppScript(bundleId: TerminalApp.warp.rawValue))
        }
    }

    // MARK: - PID / tty helpers

    /// Returns the tty basename (e.g. `ttys003`) for a process, or nil if
    /// the process has none or has exited.
    static func ttyName(for pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let raw = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `ps` prints `??` for processes without a tty.
        guard !trimmed.isEmpty, trimmed != "??" else { return nil }
        return trimmed
    }

    /// Walks up the parent chain from `pid` (skipping at most 8 levels)
    /// looking for a running application whose bundle id is one of our
    /// known terminals. Returns the first match.
    static func terminalAppOwning(pid: pid_t) -> TerminalApp? {
        var current = pid
        for _ in 0..<8 {
            if let app = appForRunningProcess(pid: current), let known = TerminalApp(rawValue: app) {
                return known
            }
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &info, &size, nil, 0)
        }
        // sysctl can return 0 with size=0 if the process disappeared
        // between calls — `info` then stays zero-initialized. Require
        // a positive write before trusting any field.
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    static func appForRunningProcess(pid: pid_t) -> String? {
        NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == pid }?.bundleIdentifier
    }

    // MARK: - AppleScript

    /// Runs the script synchronously off the main actor. Result.success
    /// when the script completes without error. We don't capture the
    /// script's return value (none of our scripts produce one).
    static func runAppleScript(_ source: String) -> Result<Void, FocusError> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.appleScriptFailed("Could not parse AppleScript"))
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo,
           let message = errorInfo[NSAppleScript.errorMessage] as? String {
            return .failure(.appleScriptFailed(message))
        }
        return .success(())
    }

    static func appleTerminalScript(tty: String) -> String {
        // Terminal.app's `tty` property returns "/dev/ttys003". We accept
        // either the basename or the full path from `ps`.
        // Search FIRST, activate LAST — activating before tab selection
        // would briefly show whatever tab was already frontmost.
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(ttyPath)" then
                        set selected of t to true
                        set frontmost of w to true
                        activate
                        return
                    end if
                end repeat
            end repeat
            -- Fallback if no tab matched: just bring the app forward.
            activate
        end tell
        """
    }

    static func iTerm2Script(tty: String) -> String {
        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        return """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(ttyPath)" then
                            select w
                            select t
                            select s
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            -- Fallback if no session matched.
            activate
        end tell
        """
    }

    static func activateAppScript(bundleId: String) -> String {
        """
        tell application id "\(bundleId)"
            activate
        end tell
        """
    }
}
