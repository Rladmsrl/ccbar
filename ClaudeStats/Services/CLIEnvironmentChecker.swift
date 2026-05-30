import Foundation

protocol CLIEnvironmentChecking: Sendable {
    func checkAll() async throws -> CLIEnvironmentSnapshot
    func deleteConflicts(_ conflicts: [CLIEnvironmentConflict]) async throws -> CLIEnvironmentCleanupResult
}

struct CLIVersionInvocation: Sendable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
}

struct CLIVersionProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var launchError: String?
    var timedOut: Bool

    var outputText: String {
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStdout.isEmpty { return trimmedStdout }
        return stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorText: String {
        if timedOut { return "version check timed out" }
        if let launchError { return launchError }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CLIEnvironmentChecker: CLIEnvironmentChecking {
    typealias ProcessRunner = @Sendable (CLIVersionInvocation) -> CLIVersionProcessResult
    typealias LatestVersionFetcher = @Sendable (APIProviderCLI) async -> String?

    private let rootDirectory: URL
    private let homeDirectory: URL
    private let environment: [String: String]
    private let shellConfigFiles: [URL]
    private let processRunner: ProcessRunner
    private let latestVersionFetcher: LatestVersionFetcher

    init(
        rootDirectory: URL = ConfigurationProviderStore.defaultRootDirectory(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellConfigFiles: [URL]? = nil,
        processRunner: @escaping ProcessRunner = Self.runProcess,
        latestVersionFetcher: @escaping LatestVersionFetcher = Self.fetchLatestVersion
    ) {
        self.rootDirectory = rootDirectory
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.shellConfigFiles = shellConfigFiles ?? Self.defaultShellConfigFiles(homeDirectory: homeDirectory)
        self.processRunner = processRunner
        self.latestVersionFetcher = latestVersionFetcher
    }

    func checkAll() async throws -> CLIEnvironmentSnapshot {
        async let statusList = toolStatuses()
        async let conflictList = scanConflicts()
        return CLIEnvironmentSnapshot(statuses: await statusList, conflicts: await conflictList)
    }

    func deleteConflicts(_ conflicts: [CLIEnvironmentConflict]) async throws -> CLIEnvironmentCleanupResult {
        let rootDirectory = rootDirectory
        return try await Task.detached(priority: .utility) {
            try Self.deleteConflictsOnDisk(conflicts, rootDirectory: rootDirectory)
        }.value
    }

    func toolStatuses() async -> [CLIToolStatus] {
        await withTaskGroup(of: CLIToolStatus.self) { group in
            for cli in APIProviderCLI.allCases {
                group.addTask {
                    await toolStatus(for: cli)
                }
            }

            var statuses: [CLIToolStatus] = []
            for await status in group {
                statuses.append(status)
            }
            return statuses.sorted { $0.cli.rawValue < $1.cli.rawValue }
        }
    }

    func toolStatus(for cli: APIProviderCLI) async -> CLIToolStatus {
        async let local = localToolStatus(for: cli)
        async let latest = latestVersionFetcher(cli)
        var status = await local
        status.latestVersion = await latest
        return status
    }

    func scanConflicts() async -> [CLIEnvironmentConflict] {
        let environment = environment
        let shellConfigFiles = shellConfigFiles
        return await Task.detached(priority: .utility) {
            Self.scanConflicts(environment: environment, shellConfigFiles: shellConfigFiles)
        }.value
    }

    private func localToolStatus(for cli: APIProviderCLI) async -> CLIToolStatus {
        let command = cli.commandName
        let runner = processRunner
        let environment = environment
        let homeDirectory = homeDirectory
        return await Task.detached(priority: .utility) {
            let direct = Self.tryGetVersion(command: command, environment: environment, runner: runner)
            if let version = direct.version {
                return CLIToolStatus(
                    cli: cli,
                    command: command,
                    version: version,
                    latestVersion: nil,
                    error: nil,
                    diagnostic: nil,
                    envType: .macOS,
                    executablePath: nil
                )
            }

            let scanned = Self.scanCLIVersion(command: command, homeDirectory: homeDirectory, environment: environment, runner: runner)
            if let version = scanned.version {
                return CLIToolStatus(
                    cli: cli,
                    command: command,
                    version: version,
                    latestVersion: nil,
                    error: nil,
                    diagnostic: nil,
                    envType: .macOS,
                    executablePath: scanned.executablePath
                )
            }

            return CLIToolStatus(
                cli: cli,
                command: command,
                version: nil,
                latestVersion: nil,
                error: "not installed or not executable",
                diagnostic: direct.error ?? scanned.error,
                envType: .macOS,
                executablePath: nil
            )
        }.value
    }

    static func extractVersion(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: #"\d+\.\d+\.\d+(-[\w.]+)?"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return trimmed
    }

    static func parseEnvironmentAssignment(_ line: String) -> (name: String, value: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("export ") {
            trimmed = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEnvironmentVariableName(name) else { return nil }
        var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return (name, value)
    }

    static func scanConflicts(environment: [String: String], shellConfigFiles: [URL]) -> [CLIEnvironmentConflict] {
        var conflicts: [CLIEnvironmentConflict] = []

        for cli in APIProviderCLI.allCases {
            let keywords = keywords(for: cli)
            for (key, value) in environment where matches(key, keywords: keywords) {
                conflicts.append(
                    CLIEnvironmentConflict(
                        cli: cli,
                        varName: key,
                        varValue: value,
                        sourceType: .process,
                        sourcePath: "Process Environment",
                        lineNumber: nil,
                        isDeletable: false
                    )
                )
            }
        }

        for file in shellConfigFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let isWritable = FileManager.default.isWritableFile(atPath: file.path)
            for (offset, line) in content.components(separatedBy: "\n").enumerated() {
                guard let assignment = parseEnvironmentAssignment(line) else { continue }
                for cli in APIProviderCLI.allCases where matches(assignment.name, keywords: keywords(for: cli)) {
                    conflicts.append(
                        CLIEnvironmentConflict(
                            cli: cli,
                            varName: assignment.name,
                            varValue: assignment.value,
                            sourceType: .file,
                            sourcePath: file.path,
                            lineNumber: offset + 1,
                            isDeletable: isWritable
                        )
                    )
                }
            }
        }

        return conflicts.sorted {
            if $0.cli != $1.cli { return $0.cli.rawValue < $1.cli.rawValue }
            if $0.sourcePath != $1.sourcePath { return $0.sourcePath < $1.sourcePath }
            if ($0.lineNumber ?? 0) != ($1.lineNumber ?? 0) { return ($0.lineNumber ?? 0) < ($1.lineNumber ?? 0) }
            return $0.varName < $1.varName
        }
    }

    private static func tryGetVersion(command: String, environment: [String: String], runner: ProcessRunner) -> (version: String?, error: String?) {
        let shell = shellPath(from: environment["SHELL"])
        let flag = defaultFlag(forShell: shell)
        let result = runner(
            CLIVersionInvocation(
                executablePath: shell,
                arguments: [flag, "\(command) --version"],
                environment: environment
            )
        )
        return versionResult(from: result)
    }

    private static func scanCLIVersion(
        command: String,
        homeDirectory: URL,
        environment: [String: String],
        runner: ProcessRunner
    ) -> (version: String?, error: String?, executablePath: String?) {
        let currentPath = environment["PATH"] ?? ""
        var lastError: String?

        for directory in searchPaths(homeDirectory: homeDirectory) {
            let executable = directory.appendingPathComponent(command, isDirectory: false)
            guard FileManager.default.fileExists(atPath: executable.path) else { continue }
            var env = environment
            env["PATH"] = "\(directory.path):\(currentPath)"
            let result = runner(
                CLIVersionInvocation(
                    executablePath: executable.path,
                    arguments: ["--version"],
                    environment: env
                )
            )
            let parsed = versionResult(from: result)
            if let version = parsed.version {
                return (version, nil, executable.path)
            }
            lastError = parsed.error
        }

        return (nil, lastError ?? "not installed or not executable", nil)
    }

    private static func versionResult(from result: CLIVersionProcessResult) -> (version: String?, error: String?) {
        if result.exitCode == 0 {
            let raw = result.outputText
            guard !raw.isEmpty else { return (nil, "not installed or not executable") }
            return (extractVersion(from: raw), nil)
        }
        let error = result.errorText
        return (nil, error.isEmpty ? "not installed or not executable" : error)
    }

    private static func runProcess(_ invocation: CLIVersionInvocation) -> CLIVersionProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executablePath)
        process.arguments = invocation.arguments
        process.environment = invocation.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return CLIVersionProcessResult(exitCode: -1, stdout: "", stderr: "", launchError: error.localizedDescription, timedOut: false)
        }

        var timedOut = false
        if semaphore.wait(timeout: .now() + 4) == .timedOut {
            timedOut = true
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CLIVersionProcessResult(
            exitCode: timedOut ? -2 : process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            launchError: nil,
            timedOut: timedOut
        )
    }

    private static func fetchLatestVersion(for cli: APIProviderCLI) async -> String? {
        guard let encodedPackage = cli.npmPackageName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://registry.npmjs.org/\(encodedPackage)") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let distTags = object?["dist-tags"] as? [String: Any]
            return distTags?["latest"] as? String
        } catch {
            return nil
        }
    }

    private static func deleteConflictsOnDisk(
        _ conflicts: [CLIEnvironmentConflict],
        rootDirectory: URL
    ) throws -> CLIEnvironmentCleanupResult {
        let date = Date()
        let backupDirectory = try makeEnvironmentBackupDirectory(rootDirectory: rootDirectory, date: date)
        let candidates = conflicts.filter { $0.sourceType == .file && $0.isDeletable && $0.lineNumber != nil }
        let skipped = conflicts.filter { !($0.sourceType == .file && $0.isDeletable && $0.lineNumber != nil) }.map {
            CLIEnvironmentSkippedConflict(
                id: $0.id,
                varName: $0.varName,
                sourcePath: $0.sourceDescription,
                reason: $0.sourceType == .process ? "Process environment variables cannot be edited from here." : "Source file is not writable."
            )
        }

        var deletedIDs: [String] = []
        var skippedConflicts = skipped
        let grouped = Dictionary(grouping: candidates, by: \.sourcePath)
        var manifestFiles: [[String: Any]] = []

        for (sourcePath, fileConflicts) in grouped {
            let sourceURL = URL(fileURLWithPath: sourcePath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: sourcePath) else {
                skippedConflicts.append(contentsOf: fileConflicts.map {
                    CLIEnvironmentSkippedConflict(id: $0.id, varName: $0.varName, sourcePath: $0.sourceDescription, reason: "Source file no longer exists.")
                })
                continue
            }

            let backupURL = backupDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
            try FileManager.default.copyItem(at: sourceURL, to: backupURL)

            let content = try String(contentsOf: sourceURL, encoding: .utf8)
            var lines = content.components(separatedBy: "\n")
            let sortedConflicts = fileConflicts.sorted { ($0.lineNumber ?? 0) > ($1.lineNumber ?? 0) }
            var removedLineNumbers: [Int] = []

            for conflict in sortedConflicts {
                guard let lineNumber = conflict.lineNumber,
                      lineNumber > 0,
                      lineNumber <= lines.count else {
                    skippedConflicts.append(
                        CLIEnvironmentSkippedConflict(id: conflict.id, varName: conflict.varName, sourcePath: conflict.sourceDescription, reason: "Line number is no longer valid.")
                    )
                    continue
                }
                let index = lineNumber - 1
                guard let current = parseEnvironmentAssignment(lines[index]),
                      current.name == conflict.varName else {
                    skippedConflicts.append(
                        CLIEnvironmentSkippedConflict(id: conflict.id, varName: conflict.varName, sourcePath: conflict.sourceDescription, reason: "Line changed since the last scan.")
                    )
                    continue
                }
                lines.remove(at: index)
                removedLineNumbers.append(lineNumber)
                deletedIDs.append(conflict.id)
            }

            if !removedLineNumbers.isEmpty {
                try lines.joined(separator: "\n").write(to: sourceURL, atomically: true, encoding: .utf8)
            }

            manifestFiles.append(
                [
                    "sourcePath": sourcePath,
                    "backupPath": backupURL.path,
                    "removedLineNumbers": removedLineNumbers.sorted(),
                ]
            )
        }

        let manifest: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: date),
            "files": manifestFiles,
            "deletedConflictIDs": deletedIDs,
            "skipped": skippedConflicts.map {
                [
                    "id": $0.id,
                    "varName": $0.varName,
                    "sourcePath": $0.sourcePath,
                    "reason": $0.reason,
                ]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: backupDirectory.appendingPathComponent("manifest.json", isDirectory: false), options: .atomic)

        return CLIEnvironmentCleanupResult(
            backupDirectory: backupDirectory,
            deletedConflictIDs: deletedIDs,
            skippedConflicts: skippedConflicts
        )
    }

    private static func makeEnvironmentBackupDirectory(rootDirectory: URL, date: Date) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let directory = rootDirectory
            .appendingPathComponent("EnvironmentBackups", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func defaultShellConfigFiles(homeDirectory: URL) -> [URL] {
        [
            homeDirectory.appendingPathComponent(".zshrc", isDirectory: false),
            homeDirectory.appendingPathComponent(".zprofile", isDirectory: false),
            homeDirectory.appendingPathComponent(".bashrc", isDirectory: false),
            homeDirectory.appendingPathComponent(".bash_profile", isDirectory: false),
            homeDirectory.appendingPathComponent(".profile", isDirectory: false),
            URL(fileURLWithPath: "/etc/profile", isDirectory: false),
            URL(fileURLWithPath: "/etc/bashrc", isDirectory: false),
            URL(fileURLWithPath: "/etc/zshrc", isDirectory: false),
            URL(fileURLWithPath: "/etc/zprofile", isDirectory: false),
        ]
    }

    private static func searchPaths(homeDirectory: URL) -> [URL] {
        var paths: [URL] = []
        func append(_ url: URL) {
            if !paths.contains(url) {
                paths.append(url)
            }
        }

        append(homeDirectory.appendingPathComponent(".local/bin", isDirectory: true))
        append(homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true))
        append(homeDirectory.appendingPathComponent("n/bin", isDirectory: true))
        append(homeDirectory.appendingPathComponent(".volta/bin", isDirectory: true))
        append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))

        let fnmBase = homeDirectory.appendingPathComponent(".local/state/fnm_multishells", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: fnmBase, includingPropertiesForKeys: nil) {
            for entry in entries {
                append(entry.appendingPathComponent("bin", isDirectory: true))
            }
        }

        let nvmBase = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: nvmBase, includingPropertiesForKeys: nil) {
            for entry in entries {
                append(entry.appendingPathComponent("bin", isDirectory: true))
            }
        }

        return paths
    }

    private static func shellPath(from raw: String?) -> String {
        guard let raw,
              isValidShell(raw),
              FileManager.default.isExecutableFile(atPath: raw) else {
            return "/bin/sh"
        }
        return raw
    }

    private static func defaultFlag(forShell shell: String) -> String {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "sh", "dash": "-c"
        case "fish": "-lc"
        default: "-lic"
        }
    }

    private static func isValidShell(_ shell: String) -> Bool {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "sh", "bash", "zsh", "fish", "dash": true
        default: false
        }
    }

    private static func isValidEnvironmentVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func keywords(for cli: APIProviderCLI) -> [String] {
        ["ANTHROPIC"]
    }

    private static func matches(_ variableName: String, keywords: [String]) -> Bool {
        let uppercased = variableName.uppercased()
        return keywords.contains { uppercased.contains($0) }
    }
}
