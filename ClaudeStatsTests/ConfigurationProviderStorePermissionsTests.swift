import Foundation
import Testing
@testable import ClaudeStats

/// `providers.json` can hold inline API keys (when the user picks the JSON
/// key-storage mode), so the on-disk file must be owner-readable only, the
/// same as the permission server's `server.token`.
@Suite("Provider library file permissions")
struct ConfigurationProviderStorePermissionsTests {

    @Test("saveLibrary writes providers.json with 0600 permissions")
    func providersFileIsOwnerOnly() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let root = temp.appendingPathComponent("ProviderLibrary", isDirectory: true)
        let store = ConfigurationProviderStore(
            rootDirectory: root,
            claudePaths: ClaudePaths(configDirectory: temp.appendingPathComponent("Claude", isDirectory: true)),
            secretStore: InMemoryAPIProviderSecretStore()
        )

        try await store.saveLibrary(ConfigurationProviderLibrary())

        let url = root.appendingPathComponent("providers.json", isDirectory: false)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
    }
}
