import Foundation
import Testing
@testable import ClaudeStats

@Suite("Legacy feature data cleaner")
struct LegacyFeatureDataCleanerTests {
    @Test("Removes legacy TokenTown data and ignores missing directory")
    func removesLegacyTokenTownData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyFeatureDataCleanerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tokenTownDirectory = root
            .appendingPathComponent("Claude Stats", isDirectory: true)
            .appendingPathComponent("TokenTown", isDirectory: true)
        let stateDirectory = tokenTownDirectory.appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1}"#.utf8)
            .write(to: stateDirectory.appendingPathComponent("state.json"))

        let cleaner = LegacyFeatureDataCleaner(applicationSupportDirectory: root)
        cleaner.cleanRemovedFeatureData()

        #expect(!FileManager.default.fileExists(atPath: tokenTownDirectory.path))

        cleaner.cleanRemovedFeatureData()
        #expect(!FileManager.default.fileExists(atPath: tokenTownDirectory.path))
    }

    @Test("Removed town page raw value falls back at navigation normalization")
    func townPageRawValueIsRemoved() {
        #expect(MainPage(rawValue: "town") == nil)
    }
}
