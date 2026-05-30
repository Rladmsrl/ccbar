import Foundation
import Testing
@testable import ClaudeStats

@Suite("AI config scanner")
struct AIConfigScannerTests {
    @Test("Discovers Claude global/project configs with missing files as coverage")
    func discoversConfigsAndDiagnostics() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeHome = root.appendingPathComponent(".claude", isDirectory: true)
        let project = root.appendingPathComponent("Projects/DemoApp", isDirectory: true)

        try TempDir.write(#"{"theme":"dark"}"#, to: claudeHome.appendingPathComponent("settings.json"))
        try TempDir.write("# Claude\n- [ ] Keep instructions tidy\n", to: claudeHome.appendingPathComponent("CLAUDE.md"))
        try TempDir.write(
            "Project: \(project.path)\n\n# Plan\n- [ ] Build Configs\n- [x] Inspect files\nBlocked by malformed JSON.\n",
            to: claudeHome.appendingPathComponent("plans/demo-plan.md")
        )
        try TempDir.write("# Orphan\n- [ ] Not assigned\n", to: claudeHome.appendingPathComponent("plans/orphan.md"))
        try TempDir.write(#"{"plugins":["official"]}"#, to: claudeHome.appendingPathComponent("plugins/installed_plugins.json"))

        try TempDir.write("# Project agents\n", to: project.appendingPathComponent("AGENTS.md"))
        try TempDir.write(#"{"broken": true"#, to: project.appendingPathComponent(".claude/settings.local.json"))

        let snapshot = await makeScanner(claudeHome: claudeHome)
            .scan(sessions: [makeSession(provider: .claude, cwd: project.path)])

        let global = try #require(snapshot.projects.first { $0.id == AIConfigProject.globalID })
        #expect(global.documents.contains { $0.title == "settings.json" && $0.exists })
        #expect(global.documents.contains { $0.kind == .pluginConfig && $0.title == "installed_plugins.json" })

        let projectGroup = try #require(snapshot.projects.first { $0.path == project.path })

        let missingClaude = try #require(projectGroup.documents.first { $0.title == "Project CLAUDE.md" })
        #expect(!missingClaude.exists)
        #expect(missingClaude.diagnostics.isEmpty)

        let badJSON = try #require(projectGroup.documents.first { $0.title == "Project settings.local.json" })
        #expect(badJSON.diagnostics.contains { $0.severity == .error })

        #expect(projectGroup.documents.contains { $0.kind == .plan && $0.title == "demo-plan.md" })
        let unassigned = try #require(snapshot.projects.first { $0.id == AIConfigProject.unassignedID })
        #expect(unassigned.documents.map(\.title) == ["orphan.md"])
        #expect(snapshot.summary.planStats.total == 2)
        #expect(snapshot.summary.planStats.assigned == 1)
        #expect(snapshot.summary.planStats.unassigned == 1)
    }

    @Test("Markdown stats are fence-aware and count tasks")
    func markdownStats() {
        let stats = AIConfigScanner.stats(forMarkdown: """
        # Heading
        - [ ] Open task
        - [x] Done task
        TODO: next
        blocked until review
        ```swift
        # Not a heading
        - [ ] Not a task
        ```
        cancelled item
        """)

        #expect(stats.headingCount == 1)
        #expect(stats.uncheckedTaskCount == 1)
        #expect(stats.checkedTaskCount == 1)
        #expect(stats.todoMentions == 1)
        #expect(stats.blockedMentions == 1)
        #expect(stats.cancelledMentions == 1)
    }

    @Test("Large files keep metadata and skip content preview")
    func largeFileSkipsPreview() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeHome = root.appendingPathComponent(".claude", isDirectory: true)
        let project = root.appendingPathComponent("Projects/Large", isDirectory: true)
        let largeMarkdown = String(repeating: "x", count: AIConfigScanner.previewByteLimit + 1)
        try TempDir.write(largeMarkdown, to: project.appendingPathComponent("CLAUDE.md"))

        let snapshot = await makeScanner(claudeHome: claudeHome)
            .scan(sessions: [makeSession(provider: .claude, cwd: project.path)])
        let projectGroup = try #require(snapshot.projects.first { $0.path == project.path })
        let document = try #require(projectGroup.documents.first { $0.title == "Project CLAUDE.md" })

        #expect(document.exists)
        #expect(document.contentPreview == nil)
        #expect(document.isPreviewTruncated)
        #expect(document.fileSize ?? 0 > Int64(AIConfigScanner.previewByteLimit))
        #expect(document.diagnostics.contains { $0.severity == .warning })
    }

    private func makeScanner(claudeHome: URL) -> AIConfigScanner {
        let registry = ProviderRegistry(
            providers: [
                ClaudeProvider(paths: ClaudePaths(configDirectory: claudeHome), pricing: TestPricing.table),
            ]
        )
        return AIConfigScanner(registry: registry)
    }

    private func makeSession(provider: ProviderKind, cwd: String) -> Session {
        Session(
            id: "\(provider.rawValue)::test",
            externalID: "test",
            provider: provider,
            projectDirectoryName: cwd.replacingOccurrences(of: "/", with: "-"),
            filePath: "\(cwd)/session.jsonl",
            cwd: cwd,
            lastModified: Date(timeIntervalSince1970: 100),
            fileSize: 100,
            stats: nil
        )
    }
}
