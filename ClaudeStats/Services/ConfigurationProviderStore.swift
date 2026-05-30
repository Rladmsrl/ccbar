import Foundation

enum ConfigurationProviderStoreError: LocalizedError, Sendable {
    case unsupportedCLI
    case invalidClaudeJSON
    case providerNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedCLI:
            "Only Claude Code is supported in this switcher."
        case .invalidClaudeJSON:
            "Claude provider raw config must be a JSON object."
        case .providerNotFound:
            "The selected API provider could not be found."
        }
    }
}

struct ConfigurationProviderApplyResult: Sendable, Hashable {
    let backupDirectory: URL
    let appliedAt: Date
}

struct ConfigurationProviderStore: Sendable {
    let rootDirectory: URL
    let claudePaths: ClaudePaths
    let secretStore: any APIProviderSecretStoring

    private var libraryURL: URL {
        rootDirectory.appendingPathComponent("providers.json", isDirectory: false)
    }

    private var backupsDirectory: URL {
        rootDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    private var claudeSettingsURL: URL {
        claudePaths.configDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    init(
        rootDirectory: URL = Self.defaultRootDirectory(),
        claudePaths: ClaudePaths = .default,
        secretStore: any APIProviderSecretStoring = APIProviderKeychainStore.shared
    ) {
        self.rootDirectory = rootDirectory
        self.claudePaths = claudePaths
        self.secretStore = secretStore
    }

    static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("CCBar", isDirectory: true)
            .appendingPathComponent("APIProviders", isDirectory: true)
    }

    func loadLibrary() async throws -> ConfigurationProviderLibrary {
        let url = libraryURL
        return try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return ConfigurationProviderLibrary()
            }
            let data = try Data(contentsOf: url)
            return try JSONDecoder.apiProviderDecoder.decode(ConfigurationProviderLibrary.self, from: data)
        }.value
    }

    func saveLibrary(_ library: ConfigurationProviderLibrary) async throws {
        let rootDirectory = rootDirectory
        let url = libraryURL
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder.apiProviderEncoder.encode(library)
            try data.write(to: url, options: .atomic)
            // May hold inline API keys — keep it owner-readable only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }.value
    }

    func deleteStoredSecrets(_ secrets: [APIProviderSecret], retainedIn library: ConfigurationProviderLibrary) {
        let retainedAccounts = Self.keychainAccounts(in: library)
        let accounts = Set(secrets.compactMap(\.keychainAccount))
        for account in accounts where !retainedAccounts.contains(account) {
            secretStore.deleteAPIKey(account: account)
        }
    }

    func ensureSystemProviders(
        in library: ConfigurationProviderLibrary,
        keyStorageMode: APIProviderKeyStorageMode
    ) async throws -> ConfigurationProviderLibrary {
        var updated = library
        for cli in APIProviderCLI.allCases {
            if !updated.cliProviders.contains(where: { $0.cli == cli && $0.id == "official" }) {
                updated.cliProviders.append(Self.officialProvider(for: cli))
            }
            if !updated.cliProviders.contains(where: { $0.cli == cli && $0.id == "default" }) {
                if let imported = try? await importCurrentProvider(cli: cli, name: "Default", id: "default", keyStorageMode: keyStorageMode) {
                    updated.cliProviders.append(imported)
                    updated.activeProviderIDs[cli] = imported.id
                }
            }
        }
        return updated
    }

    func importCurrentProvider(
        cli: APIProviderCLI,
        name: String,
        id: String = UUID().uuidString,
        keyStorageMode: APIProviderKeyStorageMode
    ) async throws -> CLIAPIProvider {
        let live = try await readClaudeSettingsText()
        return try providerFromClaudeRaw(
            id: id,
            name: name,
            origin: .importedDefault,
            category: .imported,
            rawConfig: live,
            keyStorageMode: keyStorageMode,
            createdAt: .now
        )
    }

    func providerBySavingDraft(
        existing: CLIAPIProvider,
        name: String,
        category: APIProviderCategory,
        baseURL: String,
        apiKey: String,
        model: String,
        rawConfig: String,
        rawMode: Bool,
        keyStorageMode: APIProviderKeyStorageMode
    ) throws -> CLIAPIProvider {
        let savedAt = Date()
        if rawMode {
            var provider = try providerFromClaudeRaw(
                id: existing.id,
                name: name,
                origin: existing.origin,
                category: category,
                rawConfig: rawConfig,
                keyStorageMode: keyStorageMode,
                createdAt: existing.createdAt,
                updatedAt: savedAt
            )
            provider.iconName = existing.iconName
            provider.iconColorHex = existing.iconColorHex
            return provider
        }

        var provider = existing
        provider.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? existing.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.category = category
        provider.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.apiKey = try storedSecret(rawKey: apiKey, cli: existing.cli, providerID: existing.id, keyStorageMode: keyStorageMode)
        provider.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.rawConfig = storedRawConfig(for: provider, keyStorageMode: keyStorageMode)
        provider.updatedAt = savedAt
        return provider
    }

    func makeCustomProvider(cli: APIProviderCLI, keyStorageMode: APIProviderKeyStorageMode) -> CLIAPIProvider {
        let id = UUID().uuidString
        var provider = CLIAPIProvider(
            id: id,
            cli: cli,
            origin: .appSpecific,
            name: "New Provider",
            category: .custom,
            baseURL: "",
            apiKey: .none,
            model: defaultModel(for: cli),
            iconName: cli.providerKind.monochromeAssetName
        )
        provider.rawConfig = storedRawConfig(for: provider, keyStorageMode: keyStorageMode)
        return provider
    }

    func makeUniversalProvider(keyStorageMode: APIProviderKeyStorageMode) -> (UniversalAPIProvider, [CLIAPIProvider]) {
        let universal = UniversalAPIProvider(
            name: "Universal Provider",
            baseURL: "",
            apiKey: .none,
            modelOverrides: [.claude: defaultModel(for: .claude)],
            iconName: "network"
        )
        return (universal, childProviders(for: universal, keyStorageMode: keyStorageMode))
    }

    func universalBySavingDraft(
        existing: UniversalAPIProvider,
        editedCLI: APIProviderCLI,
        name: String,
        baseURL: String,
        apiKey: String,
        model: String,
        keyStorageMode: APIProviderKeyStorageMode
    ) throws -> UniversalAPIProvider {
        var provider = existing
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.name = trimmedName.isEmpty ? existing.name : trimmedName
        provider.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.apiKey = try storedSecret(
            rawKey: apiKey,
            cli: editedCLI,
            providerID: existing.id,
            keyStorageMode: keyStorageMode
        )
        provider.modelOverrides[editedCLI] = model.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.updatedAt = .now
        return provider
    }

    func childProviders(for universal: UniversalAPIProvider, keyStorageMode: APIProviderKeyStorageMode) -> [CLIAPIProvider] {
        APIProviderCLI.allCases.compactMap { cli in
            guard universal.enabledCLIs.contains(cli) else { return nil }
            let id = Self.universalChildID(universalID: universal.id, cli: cli)
            var provider = CLIAPIProvider(
                id: id,
                cli: cli,
                origin: .universal(universal.id),
                name: universal.name,
                category: .universal,
                baseURL: universal.baseURL,
                apiKey: universal.apiKey,
                model: universal.modelOverrides[cli] ?? defaultModel(for: cli),
                iconName: universal.iconName,
                iconColorHex: universal.iconColorHex,
                createdAt: universal.createdAt,
                updatedAt: universal.updatedAt
            )
            provider.rawConfig = storedRawConfig(for: provider, keyStorageMode: keyStorageMode)
            return provider
        }
    }

    func apply(
        provider: CLIAPIProvider,
        currentActive: CLIAPIProvider?,
        keyStorageMode: APIProviderKeyStorageMode
    ) async throws -> (ConfigurationProviderApplyResult, CLIAPIProvider?) {
        let backfilled: CLIAPIProvider?
        if let currentActive, currentActive.id != provider.id {
            backfilled = try await backfilledProvider(currentActive, keyStorageMode: keyStorageMode)
        } else {
            backfilled = nil
        }

        let backupDirectory = try await backupLiveFiles(for: provider.cli, providerID: provider.id)
        try await writeLiveConfig(for: provider)
        return (
            ConfigurationProviderApplyResult(backupDirectory: backupDirectory, appliedAt: .now),
            backfilled
        )
    }

    func resolvedAPIKey(for secret: APIProviderSecret) -> String {
        switch secret {
        case .none:
            return ""
        case .inline(let value):
            return value
        case .keychain(let account):
            return secretStore.readAPIKey(account: account) ?? ""
        }
    }

    func renderRawConfig(for provider: CLIAPIProvider) -> String {
        renderClaudeRaw(provider: provider, apiKey: resolvedAPIKey(for: provider.apiKey))
    }

    static func officialProvider(for cli: APIProviderCLI) -> CLIAPIProvider {
        var provider = CLIAPIProvider(
            id: "official",
            cli: cli,
            origin: .official,
            name: "Claude Official",
            category: .official,
            baseURL: "",
            apiKey: .none,
            model: "",
            iconName: "anthropic",
            iconColorHex: "#D4915D"
        )
        provider.rawConfig = "{\n  \"env\" : {\n\n  }\n}"
        return provider
    }

    static func universalChildID(universalID: String, cli: APIProviderCLI) -> String {
        "universal-\(cli.rawValue)-\(universalID)"
    }

    private static func keychainAccounts(in library: ConfigurationProviderLibrary) -> Set<String> {
        var accounts = Set<String>()
        for provider in library.cliProviders {
            if let account = provider.apiKey.keychainAccount {
                accounts.insert(account)
            }
        }
        for provider in library.universalProviders {
            if let account = provider.apiKey.keychainAccount {
                accounts.insert(account)
            }
        }
        return accounts
    }

    private func readClaudeSettingsText() async throws -> String {
        let url = claudeSettingsURL
        return try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return "{\n  \"env\" : {\n\n  }\n}"
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    private func writeLiveConfig(for provider: CLIAPIProvider) async throws {
        let target = renderClaudeRaw(provider: provider, apiKey: resolvedAPIKey(for: provider.apiKey))
        let url = claudeSettingsURL
        try await Task.detached(priority: .utility) {
            try Self.writeClaudeSettings(providerFragment: target, to: url)
        }.value
    }

    private func backupLiveFiles(for cli: APIProviderCLI, providerID: String) async throws -> URL {
        let backupsDirectory = backupsDirectory
        let sources: [URL] = [claudeSettingsURL]
        return try await Task.detached(priority: .utility) {
            let date = Date()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
            let directory = backupsDirectory.appendingPathComponent("\(stamp)-\(cli.rawValue)-\(providerID)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var entries: [[String: Any]] = []
            for (index, source) in sources.enumerated() {
                let exists = FileManager.default.fileExists(atPath: source.path)
                if exists {
                    let backup = directory.appendingPathComponent("\(index)-\(source.lastPathComponent)", isDirectory: false)
                    try FileManager.default.copyItem(at: source, to: backup)
                    entries.append(["targetPath": source.path, "backupPath": backup.path, "existed": true])
                } else {
                    entries.append(["targetPath": source.path, "existed": false])
                }
            }

            let manifest: [String: Any] = [
                "providerID": providerID,
                "cli": cli.rawValue,
                "createdAt": ISO8601DateFormatter().string(from: date),
                "files": entries,
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("manifest.json", isDirectory: false), options: .atomic)
            return directory
        }.value
    }

    private func backfilledProvider(_ provider: CLIAPIProvider, keyStorageMode: APIProviderKeyStorageMode) async throws -> CLIAPIProvider {
        let raw = try await readClaudeSettingsText()
        var updated = try providerFromClaudeRaw(
            id: provider.id,
            name: provider.name,
            origin: provider.origin,
            category: provider.category,
            rawConfig: raw,
            keyStorageMode: keyStorageMode,
            createdAt: provider.createdAt
        )
        updated.iconName = provider.iconName
        updated.iconColorHex = provider.iconColorHex
        updated.updatedAt = .now
        return updated
    }

    private func providerFromClaudeRaw(
        id: String,
        name: String,
        origin: APIProviderOrigin,
        category: APIProviderCategory,
        rawConfig: String,
        keyStorageMode: APIProviderKeyStorageMode,
        createdAt: Date,
        updatedAt: Date = .now
    ) throws -> CLIAPIProvider {
        guard let data = rawConfig.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationProviderStoreError.invalidClaudeJSON
        }
        let env = object["env"] as? [String: Any] ?? [:]
        let apiKey = (env["ANTHROPIC_AUTH_TOKEN"] as? String) ?? (env["ANTHROPIC_API_KEY"] as? String) ?? ""
        let baseURL = env["ANTHROPIC_BASE_URL"] as? String ?? ""
        let model = env["ANTHROPIC_MODEL"] as? String ?? ""
        var provider = CLIAPIProvider(
            id: id,
            cli: .claude,
            origin: origin,
            name: name,
            category: category,
            baseURL: baseURL,
            apiKey: try storedSecret(rawKey: apiKey, cli: .claude, providerID: id, keyStorageMode: keyStorageMode),
            model: model,
            rawConfig: rawConfig,
            iconName: "anthropic",
            iconColorHex: "#D4915D",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        provider.rawConfig = storedRawConfig(for: provider, keyStorageMode: keyStorageMode)
        return provider
    }

    private func storedSecret(
        rawKey: String,
        cli: APIProviderCLI,
        providerID: String,
        keyStorageMode: APIProviderKeyStorageMode
    ) throws -> APIProviderSecret {
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        switch keyStorageMode {
        case .json:
            return .inline(trimmed)
        case .keychain:
            let account = "\(cli.rawValue)-\(providerID)"
            try secretStore.saveAPIKey(trimmed, account: account)
            return .keychain(account: account)
        }
    }

    private func storedRawConfig(for provider: CLIAPIProvider, keyStorageMode: APIProviderKeyStorageMode) -> String {
        let key = keyStorageMode == .json ? resolvedAPIKey(for: provider.apiKey) : ""
        return renderClaudeRaw(provider: provider, apiKey: key)
    }

    private func renderClaudeRaw(provider: CLIAPIProvider, apiKey: String) -> String {
        var env: [String: String] = [:]
        if !provider.baseURL.isEmpty { env["ANTHROPIC_BASE_URL"] = provider.baseURL }
        if !apiKey.isEmpty { env["ANTHROPIC_AUTH_TOKEN"] = apiKey }
        if !provider.model.isEmpty {
            env["ANTHROPIC_MODEL"] = provider.model
            env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = provider.model
            env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = provider.model
            env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = provider.model
        }
        let object: [String: Any] = ["env": env]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let raw = String(data: data, encoding: .utf8) else {
            return "{\n  \"env\" : {\n\n  }\n}"
        }
        return raw
    }

    private func defaultModel(for cli: APIProviderCLI) -> String { "" }

    private static func writeClaudeSettings(providerFragment: String, to url: URL) throws {
        let target = try jsonObject(from: providerFragment)
        let targetEnv = target["env"] as? [String: Any] ?? [:]
        let existing: [String: Any]
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = object
        } else {
            existing = [:]
        }

        var merged = existing
        var env = merged["env"] as? [String: Any] ?? [:]
        for key in claudeManagedEnvKeys {
            env.removeValue(forKey: key)
        }
        for (key, value) in targetEnv {
            if let string = value as? String, string.isEmpty { continue }
            env[key] = value
        }
        if env.isEmpty {
            merged.removeValue(forKey: "env")
        } else {
            merged["env"] = env
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func jsonObject(from raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationProviderStoreError.invalidClaudeJSON
        }
        return object
    }

    private static let claudeManagedEnvKeys: Set<String> = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "API_TIMEOUT_MS",
    ]
}

private extension JSONEncoder {
    static var apiProviderEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var apiProviderDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
