import Foundation

enum GitStatsScope: String, CaseIterable, Identifiable, Codable, Sendable {
    case head
    case workingTree

    var id: String { rawValue }

    var label: String {
        switch self {
        case .head: return "HEAD"
        case .workingTree: return "Working Tree"
        }
    }
}

enum GitLanguageStatsEngine: String, Codable, Sendable {
    case linguist
    case linguistLargeTree
    case sccFallback
    case unavailable

    var label: String {
        switch self {
        case .linguist: return "GitHub Linguist"
        case .linguistLargeTree: return "GitHub Linguist (large repo)"
        case .sccFallback: return "scc fallback"
        case .unavailable: return "Unavailable"
        }
    }
}

struct GitRepoCodeStats: Codable, Sendable, Equatable {
    struct LanguageRow: Identifiable, Codable, Sendable, Equatable {
        let language: String
        let fileCount: Int
        let sizeBytes: Int
        let byteShare: Double
        let totalLines: Int
        let sourceLines: Int

        var id: String { language }
    }

    let engine: GitLanguageStatsEngine
    let scope: GitStatsScope
    let warning: String?
    let totalFiles: Int
    let analyzedFiles: Int
    let skippedFiles: Int
    let totalBytes: Int
    let totalLines: Int
    let sourceLines: Int
    let codeFilePaths: [String]
    let languageRows: [LanguageRow]

    static let empty = GitRepoCodeStats(
        engine: .unavailable,
        scope: .head,
        warning: nil,
        totalFiles: 0,
        analyzedFiles: 0,
        skippedFiles: 0,
        totalBytes: 0,
        totalLines: 0,
        sourceLines: 0,
        codeFilePaths: [],
        languageRows: []
    )

    static func unavailable(scope: GitStatsScope, totalFiles: Int, warning: String) -> GitRepoCodeStats {
        GitRepoCodeStats(
            engine: .unavailable,
            scope: scope,
            warning: warning,
            totalFiles: totalFiles,
            analyzedFiles: 0,
            skippedFiles: totalFiles,
            totalBytes: 0,
            totalLines: 0,
            sourceLines: 0,
            codeFilePaths: [],
            languageRows: []
        )
    }
}

struct GitContributorStat: Identifiable, Codable, Sendable, Equatable {
    let name: String
    let email: String
    let commitCount: Int
    let share: Double

    var id: String { "\(name)|\(email)" }
    var displayName: String {
        email.isEmpty ? name : "\(name) <\(email)>"
    }
}

struct GitCodeContributionStat: Identifiable, Codable, Sendable, Equatable {
    let name: String
    let email: String
    let lineCount: Int
    let share: Double

    var id: String { "\(name)|\(email)" }
    var displayName: String {
        email.isEmpty ? name : "\(name) <\(email)>"
    }
}

struct GitRepoInspectorBaseStats: Codable, Sendable, Equatable {
    let code: GitRepoCodeStats
    let contributors: [GitContributorStat]
}

struct GitRepoCodeOwnershipStats: Codable, Sendable, Equatable {
    let codeContributors: [GitCodeContributionStat]
}

enum GitCodeOwnershipLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded([GitCodeContributionStat])
    case failed(String)
}

struct GitRepoInspectorStats: Codable, Sendable, Equatable {
    let base: GitRepoInspectorBaseStats
    let ownership: GitRepoCodeOwnershipStats

    var code: GitRepoCodeStats { base.code }
    var contributors: [GitContributorStat] { base.contributors }
    var codeContributors: [GitCodeContributionStat] { ownership.codeContributors }

    init(base: GitRepoInspectorBaseStats, ownership: GitRepoCodeOwnershipStats) {
        self.base = base
        self.ownership = ownership
    }

    init(code: GitRepoCodeStats, codeContributors: [GitCodeContributionStat], contributors: [GitContributorStat]) {
        self.base = GitRepoInspectorBaseStats(code: code, contributors: contributors)
        self.ownership = GitRepoCodeOwnershipStats(codeContributors: codeContributors)
    }

    static let empty = GitRepoInspectorStats(base: .empty, ownership: .empty)
}

extension GitRepoInspectorBaseStats {
    static let empty = GitRepoInspectorBaseStats(code: .empty, contributors: [])
}

extension GitRepoCodeOwnershipStats {
    static let empty = GitRepoCodeOwnershipStats(codeContributors: [])
}
