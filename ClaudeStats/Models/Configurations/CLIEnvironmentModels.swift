import Foundation

enum CLIEnvironmentType: String, Codable, Sendable, Hashable {
    case macOS
    case unknown

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .unknown: "unknown"
        }
    }
}

struct CLIToolStatus: Identifiable, Sendable, Hashable {
    var cli: APIProviderCLI
    var command: String
    var version: String?
    var latestVersion: String?
    var error: String?
    var diagnostic: String?
    var envType: CLIEnvironmentType
    var executablePath: String?

    var id: APIProviderCLI { cli }
    var isInstalled: Bool { version != nil }
    var isOutdated: Bool {
        guard let version, let latestVersion else { return false }
        guard let comparison = Self.compare(version, latestVersion) else { return false }
        return comparison == .orderedAscending
    }
    var displayValue: String {
        version ?? error ?? "not installed or not executable"
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = semanticComponents(lhs),
              let right = semanticComponents(rhs) else {
            return nil
        }
        for index in 0..<3 {
            if left[index] < right[index] { return .orderedAscending }
            if left[index] > right[index] { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func semanticComponents(_ version: String) -> [Int]? {
        let core = version.split(separator: "-", maxSplits: 1).first ?? Substring(version)
        let parts = core.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return numbers
    }
}

enum CLIEnvironmentConflictSourceType: String, Codable, Sendable, Hashable {
    case process
    case file

    var displayName: String {
        switch self {
        case .process: "Process Environment"
        case .file: "File"
        }
    }
}

struct CLIEnvironmentConflict: Identifiable, Codable, Sendable, Hashable {
    var cli: APIProviderCLI
    var varName: String
    var varValue: String
    var sourceType: CLIEnvironmentConflictSourceType
    var sourcePath: String
    var lineNumber: Int?
    var isDeletable: Bool

    var id: String {
        [
            cli.rawValue,
            varName,
            sourceType.rawValue,
            sourcePath,
            lineNumber.map(String.init) ?? "process",
        ].joined(separator: "|")
    }

    var sourceDescription: String {
        if let lineNumber {
            "\(sourcePath):\(lineNumber)"
        } else {
            sourcePath
        }
    }

    var maskedValue: String {
        guard !varValue.isEmpty else { return "(empty)" }
        return String(repeating: "*", count: min(max(varValue.count, 8), 18))
    }
}

struct CLIEnvironmentSkippedConflict: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var varName: String
    var sourcePath: String
    var reason: String
}

struct CLIEnvironmentCleanupResult: Sendable, Hashable {
    var backupDirectory: URL
    var deletedConflictIDs: [String]
    var skippedConflicts: [CLIEnvironmentSkippedConflict]
}

struct CLIEnvironmentSnapshot: Sendable, Hashable {
    var statuses: [CLIToolStatus]
    var conflicts: [CLIEnvironmentConflict]
}

extension APIProviderCLI {
    var commandName: String { "claude" }
    var installCommand: String { "curl -fsSL https://claude.ai/install.sh | bash" }
    var installURL: URL { URL(string: "https://code.claude.com/docs/en/quickstart")! }
    var npmPackageName: String { "@anthropic-ai/claude-code" }
}
