import Foundation

struct GitLinguistAnalyzer: Sendable {
    private static let githubTreeFileLimit = 100_000
    private static let localLargeTreeLimit = 1_000_000

    private let toolLocator: GitStatsToolLocating

    init(toolLocator: GitStatsToolLocating = GitStatsToolLocator()) {
        self.toolLocator = toolLocator
    }

    func stats(repo: GitRepo, scope: GitStatsScope, trackedFiles: [String]) -> GitRepoCodeStats {
        guard let linguistPath = toolLocator.toolPath(named: "github-linguist") else {
            return sccFallbackStats(
                repo: repo,
                scope: scope,
                trackedFiles: trackedFiles,
                warning: "GitHub Linguist runtime is not bundled. Run scripts/build-linguist-runtime.sh after installing github-linguist."
            )
        }

        let linguistResult = GitStatsProcess.run(
            executablePath: linguistPath,
            arguments: linguistArguments(repoRoot: repo.rootPath, scope: scope),
            currentDirectoryPath: repo.rootPath
        )

        guard linguistResult.exitCode == 0 else {
            let reason = linguistResult.errorText.nilIfBlank ?? linguistResult.output.nilIfBlank ?? "GitHub Linguist failed."
            return sccFallbackStats(
                repo: repo,
                scope: scope,
                trackedFiles: trackedFiles,
                warning: reason
            )
        }

        do {
            let linguist = try GitLinguistReport.parse(linguistResult.output)
            let lineStats = sccLineStats(repo: repo, scope: scope)
            let warning = languageStatsWarning(
                trackedFileCount: trackedFiles.count,
                hasLanguages: !linguist.languages.isEmpty,
                hasLineStats: !lineStats.rows.isEmpty
            )
            return GitRepoCodeStats(
                engine: trackedFiles.count > Self.githubTreeFileLimit ? .linguistLargeTree : .linguist,
                scope: scope,
                warning: warning,
                totalFiles: trackedFiles.count,
                analyzedFiles: linguist.analyzedFileCount,
                skippedFiles: max(0, trackedFiles.count - linguist.analyzedFileCount),
                totalBytes: linguist.totalBytes,
                totalLines: lineStats.totalLines,
                sourceLines: lineStats.sourceLines,
                codeFilePaths: linguist.filePaths,
                languageRows: mergeRows(linguist: linguist, lineStats: lineStats)
            )
        } catch {
            return sccFallbackStats(
                repo: repo,
                scope: scope,
                trackedFiles: trackedFiles,
                warning: "GitHub Linguist returned an unexpected JSON shape."
            )
        }
    }

    private func languageStatsWarning(
        trackedFileCount: Int,
        hasLanguages: Bool,
        hasLineStats: Bool
    ) -> String? {
        var messages: [String] = []
        if trackedFileCount > Self.githubTreeFileLimit {
            messages.append("Local large-repo mode raises Linguist's tree limit above GitHub.com's 100,000-file cutoff.")
        }
        if hasLanguages && !hasLineStats {
            messages.append("scc runtime is not bundled; SLOC is unavailable.")
        }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private func linguistArguments(repoRoot: String, scope: GitStatsScope) -> [String] {
        var args = [
            "--breakdown",
            "--json",
            "--tree-size=\(Self.localLargeTreeLimit)",
            repoRoot,
        ]
        if scope == .head {
            args.append(contentsOf: ["--rev", "HEAD"])
        }
        return args
    }

    private func sccFallbackStats(
        repo: GitRepo,
        scope: GitStatsScope,
        trackedFiles: [String],
        warning: String
    ) -> GitRepoCodeStats {
        let lineStats = sccLineStats(repo: repo, scope: scope)
        let totalBytes = lineStats.rows.reduce(0) { $0 + $1.sizeBytes }
        let codeFilePaths = Array(Set(lineStats.rows.flatMap(\.filePaths))).sorted()
        let rows = lineStats.rows
            .map { row in
                GitRepoCodeStats.LanguageRow(
                    language: row.language,
                    fileCount: row.fileCount,
                    sizeBytes: row.sizeBytes,
                    byteShare: totalBytes > 0 ? Double(row.sizeBytes) / Double(totalBytes) : 0,
                    totalLines: row.totalLines,
                    sourceLines: row.sourceLines
                )
            }
            .sorted(by: Self.sortLanguageRows)

        return GitRepoCodeStats(
            engine: lineStats.rows.isEmpty ? .unavailable : .sccFallback,
            scope: scope,
            warning: lineStats.rows.isEmpty ? warning : "\(warning) Showing scc fallback statistics.",
            totalFiles: trackedFiles.count,
            analyzedFiles: rows.reduce(0) { $0 + $1.fileCount },
            skippedFiles: max(0, trackedFiles.count - rows.reduce(0) { $0 + $1.fileCount }),
            totalBytes: totalBytes,
            totalLines: lineStats.totalLines,
            sourceLines: lineStats.sourceLines,
            codeFilePaths: codeFilePaths,
            languageRows: rows
        )
    }

    private func sccLineStats(repo: GitRepo, scope: GitStatsScope) -> GitSCCReport {
        guard let sccPath = toolLocator.toolPath(named: "scc") else {
            return .empty
        }

        let target = SCCScanTarget(repoRoot: repo.rootPath, scope: scope)
        guard let scanRoot = target.scanRoot else {
            return .empty
        }
        defer { target.cleanup() }

        let result = GitStatsProcess.run(
            executablePath: sccPath,
            arguments: ["--format", "json", "--by-file", scanRoot],
            currentDirectoryPath: scanRoot
        )
        guard result.exitCode == 0, let report = try? GitSCCReport.parse(result.output) else {
            return .empty
        }
        return report
    }

    private func mergeRows(linguist: GitLinguistReport, lineStats: GitSCCReport) -> [GitRepoCodeStats.LanguageRow] {
        linguist.languages.map { language in
            let lineRow = lineStats.rowsByLanguage[language.name]
            return GitRepoCodeStats.LanguageRow(
                language: language.name,
                fileCount: language.files.count,
                sizeBytes: language.sizeBytes,
                byteShare: linguist.totalBytes > 0 ? Double(language.sizeBytes) / Double(linguist.totalBytes) : 0,
                totalLines: lineRow?.totalLines ?? 0,
                sourceLines: lineRow?.sourceLines ?? 0
            )
        }
        .sorted(by: Self.sortLanguageRows)
    }

    private static func sortLanguageRows(
        _ lhs: GitRepoCodeStats.LanguageRow,
        _ rhs: GitRepoCodeStats.LanguageRow
    ) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes {
            return lhs.sizeBytes > rhs.sizeBytes
        }
        return lhs.language.localizedStandardCompare(rhs.language) == .orderedAscending
    }
}

protocol GitStatsToolLocating: Sendable {
    func toolPath(named name: String) -> String?
}

struct GitStatsToolLocator: GitStatsToolLocating {
    func toolPath(named name: String) -> String? {
        if let bundled = bundledToolPath(named: name) {
            return bundled
        }

        #if DEBUG
        return developerToolPath(named: name)
        #else
        return nil
        #endif
    }

    private func bundledToolPath(named name: String) -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("GitTools", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    #if DEBUG
    private func developerToolPath(named name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    #endif
}

enum GitStatsProcess {
    struct Result: Sendable {
        let exitCode: Int32
        let output: String
        let errorText: String
    }

    static func run(executablePath: String, arguments: [String], currentDirectoryPath: String) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return Result(exitCode: -1, output: "", errorText: error.localizedDescription)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            errorText: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

struct GitLinguistReport: Sendable, Equatable {
    struct Language: Sendable, Equatable {
        let name: String
        let sizeBytes: Int
        let percentage: Double
        let files: [String]
    }

    let languages: [Language]

    var totalBytes: Int {
        languages.reduce(0) { $0 + $1.sizeBytes }
    }

    var analyzedFileCount: Int {
        languages.reduce(0) { $0 + $1.files.count }
    }

    var filePaths: [String] {
        Array(Set(languages.flatMap(\.files))).sorted()
    }

    static func parse(_ json: String) throws -> GitLinguistReport {
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode([String: LinguistLanguageEntry].self, from: data)
        let languages = decoded.map { name, entry in
            Language(
                name: name,
                sizeBytes: entry.size,
                percentage: Double(entry.percentage) ?? 0,
                files: entry.files ?? []
            )
        }
        return GitLinguistReport(languages: languages.sorted {
            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    private struct LinguistLanguageEntry: Decodable {
        let size: Int
        let percentage: String
        let files: [String]?
    }
}

struct GitSCCReport: Sendable, Equatable {
    struct Language: Sendable, Equatable {
        let language: String
        let fileCount: Int
        let sizeBytes: Int
        let totalLines: Int
        let sourceLines: Int
        let filePaths: [String]
    }

    static let empty = GitSCCReport(rows: [])

    let rows: [Language]

    var totalLines: Int {
        rows.reduce(0) { $0 + $1.totalLines }
    }

    var sourceLines: Int {
        rows.reduce(0) { $0 + $1.sourceLines }
    }

    var rowsByLanguage: [String: Language] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.language, $0) })
    }

    static func parse(_ json: String) throws -> GitSCCReport {
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode([SCCLanguageEntry].self, from: data)
        let rows = decoded
            .filter { $0.name.lowercased() != "total" }
            .map { entry in
                let source = entry.code ?? 0
                let comments = entry.comment ?? 0
                let blanks = entry.blank ?? 0
                return Language(
                    language: entry.name,
                    fileCount: entry.count ?? entry.files?.count ?? 0,
                    sizeBytes: entry.bytes ?? 0,
                    totalLines: entry.lines ?? source + comments + blanks,
                    sourceLines: source,
                    filePaths: entry.files?.map(\.location) ?? []
                )
            }
        return GitSCCReport(rows: rows)
    }

    private struct SCCLanguageEntry: Decodable {
        let name: String
        let bytes: Int?
        let code: Int?
        let comment: Int?
        let blank: Int?
        let lines: Int?
        let count: Int?
        let files: [SCCFileEntry]?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case bytes = "Bytes"
            case code = "Code"
            case comment = "Comment"
            case blank = "Blank"
            case lines = "Lines"
            case count = "Count"
            case files = "Files"
        }
    }

    private struct SCCFileEntry: Decodable {
        let location: String

        enum CodingKeys: String, CodingKey {
            case location = "Location"
        }
    }
}

private final class SCCScanTarget {
    private let tempDirectory: URL?
    let scanRoot: String?

    init(repoRoot: String, scope: GitStatsScope) {
        switch scope {
        case .workingTree:
            tempDirectory = nil
            scanRoot = repoRoot
        case .head:
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("claude-stats-scc-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let archive = root.appendingPathComponent("repo.tar")
                let archiveResult = GitStatsProcess.run(
                    executablePath: GitAnalyzer.gitPath,
                    arguments: ["-C", repoRoot, "archive", "--format=tar", "--output", archive.path, "HEAD"],
                    currentDirectoryPath: repoRoot
                )
                guard archiveResult.exitCode == 0 else {
                    try? FileManager.default.removeItem(at: root)
                    tempDirectory = nil
                    scanRoot = nil
                    return
                }

                let extracted = root.appendingPathComponent("checkout", isDirectory: true)
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                let tarResult = GitStatsProcess.run(
                    executablePath: "/usr/bin/tar",
                    arguments: ["-xf", archive.path, "-C", extracted.path],
                    currentDirectoryPath: root.path
                )
                try? FileManager.default.removeItem(at: archive)
                guard tarResult.exitCode == 0 else {
                    try? FileManager.default.removeItem(at: root)
                    tempDirectory = nil
                    scanRoot = nil
                    return
                }
                tempDirectory = root
                scanRoot = extracted.path
            } catch {
                try? FileManager.default.removeItem(at: root)
                tempDirectory = nil
                scanRoot = nil
            }
        }
    }

    func cleanup() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
