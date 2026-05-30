import Foundation
import Testing
@testable import ClaudeStats

@Suite("API provider switcher")
struct APIProviderSwitcherTests {
    @Test("Claude provider writes managed env and preserves non-provider settings")
    func claudeProviderPreservesNonProviderSettings() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let claudeConfig = temp.appendingPathComponent("Claude", isDirectory: true)
        let settingsURL = claudeConfig.appendingPathComponent("settings.json", isDirectory: false)
        try TempDir.write(
            """
            {
              "env" : {
                "ANTHROPIC_BASE_URL" : "https://old.example",
                "ANTHROPIC_API_KEY" : "old-key",
                "CUSTOM_ENV" : "keep-me"
              },
              "permissions" : {
                "allow" : ["Bash(ls)"]
              },
              "statusLine" : {
                "command" : "echo ok"
              }
            }
            """,
            to: settingsURL
        )

        let store = makeStore(temp: temp, claudeConfig: claudeConfig)
        let provider = CLIAPIProvider(
            id: "gateway",
            cli: .claude,
            name: "Gateway",
            baseURL: "https://gateway.example",
            apiKey: .inline("sk-gateway"),
            model: "claude-compatible"
        )

        _ = try await store.apply(provider: provider, currentActive: nil, keyStorageMode: .json)

        let object = try readJSONObject(settingsURL)
        let env = try #require(object["env"] as? [String: Any])
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "https://gateway.example")
        #expect(env["ANTHROPIC_AUTH_TOKEN"] as? String == "sk-gateway")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["CUSTOM_ENV"] as? String == "keep-me")
        #expect(object["permissions"] != nil)
        #expect(object["statusLine"] != nil)
    }

    @Test("Import Current creates Default provider")
    func importCurrentCreatesDefaultProvider() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let claudeConfig = temp.appendingPathComponent("Claude", isDirectory: true)
        try TempDir.write(
            """
            {
              "env" : {
                "ANTHROPIC_BASE_URL" : "https://current.example",
                "ANTHROPIC_AUTH_TOKEN" : "sk-current",
                "ANTHROPIC_MODEL" : "current-model"
              }
            }
            """,
            to: claudeConfig.appendingPathComponent("settings.json")
        )

        let store = makeStore(temp: temp, claudeConfig: claudeConfig)
        let provider = try await store.importCurrentProvider(
            cli: .claude,
            name: "Default",
            id: "default",
            keyStorageMode: .json
        )

        #expect(provider.id == "default")
        #expect(provider.origin.kind == .importedDefault)
        #expect(provider.name == "Default")
        #expect(provider.baseURL == "https://current.example")
        #expect(provider.apiKey == .inline("sk-current"))
        #expect(provider.model == "current-model")
    }

    @MainActor
    @Test("Enable Provider backs up live files and updates active id")
    func enableProviderBacksUpAndUpdatesActiveID() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let claudeConfig = temp.appendingPathComponent("Claude", isDirectory: true)
        try TempDir.write(#"{ "env" : { "ANTHROPIC_BASE_URL" : "https://default.example" } }"#, to: claudeConfig.appendingPathComponent("settings.json"))
        let store = makeStore(temp: temp, claudeConfig: claudeConfig)
        let vm = APIProviderSwitcherViewModel(store: store)

        await vm.reload(keyStorageMode: .json)
        await vm.addProvider(keyStorageMode: .json)
        vm.draftName = "Gateway"
        vm.draftBaseURL = "https://gateway.example"
        vm.draftAPIKey = "sk-gateway"
        vm.draftModel = "gateway-model"

        await vm.enableSelectedProvider(rawMode: false, keyStorageMode: .json)

        let active = try #require(vm.activeProvider(for: .claude))
        #expect(active.name == "Gateway")
        #expect(vm.latestApplyResult != nil)
        if let backup = vm.latestApplyResult?.backupDirectory {
            #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("manifest.json").path))
        }
        let settings = try readJSONObject(claudeConfig.appendingPathComponent("settings.json"))
        let env = try #require(settings["env"] as? [String: Any])
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "https://gateway.example")
    }

    @Test("Universal provider generates Claude child provider")
    func universalProviderGeneratesChildren() throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = makeStore(temp: temp)
        let (universal, initialChildren) = store.makeUniversalProvider(keyStorageMode: .json)
        #expect(Set(initialChildren.map(\.cli)) == Set(APIProviderCLI.allCases))

        let saved = try store.universalBySavingDraft(
            existing: universal,
            editedCLI: .claude,
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            apiKey: "sk-universal",
            model: "anthropic/claude-compatible",
            keyStorageMode: .json
        )
        let children = store.childProviders(for: saved, keyStorageMode: .json)
        let claude = try #require(children.first { $0.cli == .claude })
        #expect(claude.name == "OpenRouter")
        #expect(claude.baseURL == "https://openrouter.ai/api/v1")
        #expect(claude.model == "anthropic/claude-compatible")
        #expect(claude.apiKey == .inline("sk-universal"))
    }

    @Test("JSON and Keychain API key storage resolve the same key")
    func apiKeyStorageModesResolveKeys() throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let secretStore = InMemoryAPIProviderSecretStore()
        let store = makeStore(temp: temp, secretStore: secretStore)
        let existing = CLIAPIProvider(id: "provider", cli: .claude, name: "Provider")

        let jsonProvider = try store.providerBySavingDraft(
            existing: existing,
            name: "Provider",
            category: .custom,
            baseURL: "https://json.example",
            apiKey: "sk-json",
            model: "json-model",
            rawConfig: "",
            rawMode: false,
            keyStorageMode: .json
        )
        let keychainProvider = try store.providerBySavingDraft(
            existing: existing,
            name: "Provider",
            category: .custom,
            baseURL: "https://keychain.example",
            apiKey: "sk-keychain",
            model: "keychain-model",
            rawConfig: "",
            rawMode: false,
            keyStorageMode: .keychain
        )

        #expect(jsonProvider.apiKey == .inline("sk-json"))
        if case .keychain(let account) = keychainProvider.apiKey {
            #expect(secretStore.readAPIKey(account: account) == "sk-keychain")
        } else {
            Issue.record("Expected keychain provider secret")
        }
        #expect(store.resolvedAPIKey(for: jsonProvider.apiKey) == "sk-json")
        #expect(store.resolvedAPIKey(for: keychainProvider.apiKey) == "sk-keychain")
    }

    @MainActor
    @Test("Deleting a Keychain provider removes its stored key")
    func deletingKeychainProviderRemovesStoredKey() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let secretStore = InMemoryAPIProviderSecretStore()
        secretStore.saveAPIKey("sk-old", account: "claude-provider")
        let store = makeStore(temp: temp, secretStore: secretStore)
        let provider = CLIAPIProvider(
            id: "provider",
            cli: .claude,
            origin: .appSpecific,
            name: "Provider",
            apiKey: .keychain(account: "claude-provider")
        )
        try await store.saveLibrary(ConfigurationProviderLibrary(cliProviders: [provider]))
        let vm = APIProviderSwitcherViewModel(store: store)

        await vm.reload(keyStorageMode: .keychain)
        let loadedProvider = try #require(vm.providers(for: .claude).first { $0.id == "provider" })
        vm.selectProvider(loadedProvider, keyStorageMode: .keychain)

        await vm.deleteSelectedProvider(keyStorageMode: .keychain)

        #expect(secretStore.readAPIKey(account: "claude-provider") == nil)
        #expect(vm.providers(for: .claude).contains { $0.id == "provider" } == false)
    }

    @MainActor
    @Test("Provider list cache invalidates after library mutation")
    func providerListCacheInvalidatesAfterMutation() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = makeStore(temp: temp)
        let vm = APIProviderSwitcherViewModel(store: store)

        await vm.reload(keyStorageMode: .json)
        let initial = vm.providers(for: .claude)
        #expect(vm.providers(for: .claude).map(\.id) == initial.map(\.id))

        await vm.addProvider(keyStorageMode: .json)

        let selectedID = try #require(vm.selectedProviderID)
        let updated = vm.providers(for: .claude)
        #expect(updated.count == initial.count + 1)
        #expect(updated.contains { $0.id == selectedID })
    }

    @MainActor
    @Test("Switching a provider away from Keychain removes the old stored key")
    func switchingProviderAwayFromKeychainRemovesOldStoredKey() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let secretStore = InMemoryAPIProviderSecretStore()
        secretStore.saveAPIKey("sk-old", account: "claude-provider")
        let store = makeStore(temp: temp, secretStore: secretStore)
        let provider = CLIAPIProvider(
            id: "provider",
            cli: .claude,
            origin: .appSpecific,
            name: "Provider",
            apiKey: .keychain(account: "claude-provider")
        )
        try await store.saveLibrary(ConfigurationProviderLibrary(cliProviders: [provider]))
        let vm = APIProviderSwitcherViewModel(store: store)

        await vm.reload(keyStorageMode: .keychain)
        let loadedProvider = try #require(vm.providers(for: .claude).first { $0.id == "provider" })
        vm.selectProvider(loadedProvider, keyStorageMode: .keychain)
        vm.draftAPIKey = "sk-json"

        let saved = await vm.saveDraft(rawMode: false, keyStorageMode: .json)

        let updatedProvider = try #require(vm.providers(for: .claude).first { $0.id == "provider" })
        #expect(saved)
        #expect(updatedProvider.apiKey == .inline("sk-json"))
        #expect(secretStore.readAPIKey(account: "claude-provider") == nil)
    }

    @Test("Provider library persists CLI-keyed maps as string dictionaries")
    func providerLibraryPersistsCLIMaps() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let store = makeStore(temp: temp)
        let universal = UniversalAPIProvider(
            id: "u",
            name: "Universal",
            modelOverrides: [.claude: "claude-model"]
        )
        let library = ConfigurationProviderLibrary(
            universalProviders: [universal],
            activeProviderIDs: [.claude: "default"]
        )

        try await store.saveLibrary(library)

        let raw = try String(
            contentsOf: temp
                .appendingPathComponent("ProviderLibrary", isDirectory: true)
                .appendingPathComponent("providers.json", isDirectory: false),
            encoding: .utf8
        )
        #expect(raw.contains(#""claude" : "default""#))
        #expect(raw.contains(#""claude" : "claude-model""#))

        let loaded = try await store.loadLibrary()
        #expect(loaded.activeProviderIDs[.claude] == "default")
        #expect(loaded.universalProviders.first?.modelOverrides[.claude] == "claude-model")
    }

    @Test("Provider library skips persisted unsupported CLIs")
    func providerLibrarySkipsPersistedUnsupportedCLIs() async throws {
        let temp = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: temp) }

        let root = temp.appendingPathComponent("ProviderLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TempDir.write(
            """
            {
              "cliProviders" : [
                {
                  "id" : "claude-default",
                  "cli" : "claude",
                  "origin" : { "kind" : "importedDefault" },
                  "name" : "Claude Default",
                  "category" : "imported",
                  "baseURL" : "https://claude.example",
                  "apiKey" : { "kind" : "none" },
                  "model" : "claude-sonnet",
                  "rawConfig" : "{}",
                  "createdAt" : "2026-01-01T00:00:00Z",
                  "updatedAt" : "2026-01-01T00:00:00Z"
                },
                {
                  "id" : "codex-default",
                  "cli" : "codex",
                  "origin" : { "kind" : "importedDefault" },
                  "name" : "Codex Default",
                  "category" : "imported",
                  "baseURL" : "https://openai.example",
                  "apiKey" : { "kind" : "none" },
                  "model" : "gpt-5-codex",
                  "rawConfig" : "",
                  "createdAt" : "2026-01-01T00:00:00Z",
                  "updatedAt" : "2026-01-01T00:00:00Z"
                }
              ],
              "universalProviders" : [
                {
                  "id" : "universal",
                  "name" : "Universal",
                  "baseURL" : "https://gateway.example",
                  "apiKey" : { "kind" : "none" },
                  "modelOverrides" : {
                    "claude" : "claude-compatible",
                    "codex" : "gpt-compatible"
                  },
                  "enabledCLIs" : ["claude", "codex"],
                  "createdAt" : "2026-01-01T00:00:00Z",
                  "updatedAt" : "2026-01-01T00:00:00Z"
                }
              ],
              "activeProviderIDs" : {
                "claude" : "claude-default",
                "codex" : "codex-default"
              },
              "commonConfigByCLI" : {
                "claude" : "keep",
                "codex" : "drop"
              }
            }
            """,
            to: root.appendingPathComponent("providers.json", isDirectory: false)
        )

        let loaded = try await makeStore(temp: temp).loadLibrary()

        #expect(loaded.cliProviders.map(\.id) == ["claude-default"])
        #expect(loaded.universalProviders.map(\.id) == ["universal"])
        #expect(loaded.universalProviders.first?.enabledCLIs == [.claude])
        #expect(loaded.universalProviders.first?.modelOverrides == [.claude: "claude-compatible"])
        #expect(loaded.activeProviderIDs == [.claude: "claude-default"])
        #expect(loaded.commonConfigByCLI == [.claude: "keep"])
    }

    private func makeStore(
        temp: URL,
        claudeConfig: URL? = nil,
        secretStore: any APIProviderSecretStoring = InMemoryAPIProviderSecretStore()
    ) -> ConfigurationProviderStore {
        ConfigurationProviderStore(
            rootDirectory: temp.appendingPathComponent("ProviderLibrary", isDirectory: true),
            claudePaths: ClaudePaths(configDirectory: claudeConfig ?? temp.appendingPathComponent("Claude", isDirectory: true)),
            secretStore: secretStore
        )
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
