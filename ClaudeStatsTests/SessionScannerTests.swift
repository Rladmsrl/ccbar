import Testing
import Foundation
@testable import ClaudeStats

@Suite("SessionScanner")
struct SessionScannerTests {

    @Test("Discovers transcripts, skips tiny files, extracts cwd")
    func scansProjectsTree() async throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projects.appendingPathComponent("-Users-dev-projects-demo", isDirectory: true)

        let realID = "11111111-2222-3333-4444-555555555555"
        try TempDir.write(SampleTranscript.text, to: projectDir.appendingPathComponent("\(realID).jsonl"))
        // Below the 100-byte floor — should be ignored.
        try TempDir.write(#"{"type":"x"}"#, to: projectDir.appendingPathComponent("tiny.jsonl"))
        // Non-jsonl — should be ignored.
        try TempDir.write("not a transcript", to: projectDir.appendingPathComponent("notes.txt"))

        let sessions = await SessionScanner(paths: ClaudePaths(configDirectory: root)).scan()

        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.id == "-Users-dev-projects-demo::\(realID)")
        #expect(session.externalID == realID)
        #expect(session.provider == .claude)
        #expect(session.projectDirectoryName == "-Users-dev-projects-demo")
        #expect(session.cwd == SampleTranscript.cwd)
        #expect(session.fileSize >= SessionScanner.minimumFileSize)
    }

    @Test("Returns nothing when the projects directory is absent")
    func missingDirectory() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        let sessions = await SessionScanner(paths: ClaudePaths(configDirectory: root)).scan()
        #expect(sessions.isEmpty)
    }
}
