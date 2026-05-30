import Foundation

enum APIProviderCLI: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case claude

    var id: String { rawValue }

    var providerKind: ProviderKind { .claude }
    var displayName: String { "Claude Code" }
    var shortName: String { "Claude" }
    var assetName: String { providerKind.monochromeAssetName }
    var symbolName: String { providerKind.iconSystemName }
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let decoded = try container.decode(LossyElement<Element>.self).value {
                elements.append(decoded)
            }
        }
        self.elements = elements
    }
}

private struct LossyElement<Element: Decodable>: Decodable {
    var value: Element?

    init(from decoder: Decoder) throws {
        value = try? Element(from: decoder)
    }
}

enum APIProviderCategory: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case official
    case imported
    case aggregator
    case thirdParty
    case custom
    case universal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .official: "Official"
        case .imported: "Imported"
        case .aggregator: "Aggregator"
        case .thirdParty: "Third-party"
        case .custom: "Custom"
        case .universal: "Universal"
        }
    }
}

enum APIProviderOriginKind: String, Codable, Sendable, Hashable {
    case official
    case importedDefault
    case appSpecific
    case universal
}

struct APIProviderOrigin: Codable, Sendable, Hashable {
    var kind: APIProviderOriginKind
    var universalID: String?

    static let official = APIProviderOrigin(kind: .official)
    static let importedDefault = APIProviderOrigin(kind: .importedDefault)
    static let appSpecific = APIProviderOrigin(kind: .appSpecific)

    static func universal(_ id: String) -> APIProviderOrigin {
        APIProviderOrigin(kind: .universal, universalID: id)
    }

    var displayName: String {
        switch kind {
        case .official: "Official"
        case .importedDefault: "Default"
        case .appSpecific: "Provider"
        case .universal: "Universal"
        }
    }
}

enum APIProviderSecret: Codable, Sendable, Hashable {
    case none
    case inline(String)
    case keychain(account: String)

    var keychainAccount: String? {
        if case .keychain(let account) = self { account } else { nil }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case account
    }

    private enum Kind: String, Codable {
        case none
        case inline
        case keychain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .inline:
            self = .inline(try container.decode(String.self, forKey: .value))
        case .keychain:
            self = .keychain(account: try container.decode(String.self, forKey: .account))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .inline(let value):
            try container.encode(Kind.inline, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .keychain(let account):
            try container.encode(Kind.keychain, forKey: .kind)
            try container.encode(account, forKey: .account)
        }
    }
}

struct CLIAPIProvider: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var cli: APIProviderCLI
    var origin: APIProviderOrigin
    var name: String
    var category: APIProviderCategory
    var baseURL: String
    var apiKey: APIProviderSecret
    var model: String
    var rawConfig: String
    var iconName: String?
    var iconColorHex: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        cli: APIProviderCLI,
        origin: APIProviderOrigin = .appSpecific,
        name: String,
        category: APIProviderCategory = .custom,
        baseURL: String = "",
        apiKey: APIProviderSecret = .none,
        model: String = "",
        rawConfig: String = "",
        iconName: String? = nil,
        iconColorHex: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.cli = cli
        self.origin = origin
        self.name = name
        self.category = category
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.rawConfig = rawConfig
        self.iconName = iconName
        self.iconColorHex = iconColorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isSystemProvider: Bool {
        origin.kind == .official || origin.kind == .importedDefault
    }
}

struct UniversalAPIProvider: Codable, Identifiable, Sendable, Hashable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: APIProviderSecret
    var modelOverrides: [APIProviderCLI: String]
    var enabledCLIs: Set<APIProviderCLI>
    var iconName: String?
    var iconColorHex: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String = "",
        apiKey: APIProviderSecret = .none,
        modelOverrides: [APIProviderCLI: String] = [:],
        enabledCLIs: Set<APIProviderCLI> = Set(APIProviderCLI.allCases),
        iconName: String? = nil,
        iconColorHex: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.modelOverrides = modelOverrides
        self.enabledCLIs = enabledCLIs
        self.iconName = iconName
        self.iconColorHex = iconColorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case apiKey
        case modelOverrides
        case enabledCLIs
        case iconName
        case iconColorHex
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try container.decodeIfPresent(APIProviderSecret.self, forKey: .apiKey) ?? .none
        let rawOverrides = try container.decodeIfPresent([String: String].self, forKey: .modelOverrides) ?? [:]
        modelOverrides = rawOverrides.reduce(into: [:]) { partial, entry in
            if let cli = APIProviderCLI(rawValue: entry.key) {
                partial[cli] = entry.value
            }
        }
        if let rawCLIs = try container.decodeIfPresent([String].self, forKey: .enabledCLIs) {
            let decoded = Set(rawCLIs.compactMap(APIProviderCLI.init(rawValue:)))
            enabledCLIs = decoded.isEmpty ? Set(APIProviderCLI.allCases) : decoded
        } else {
            enabledCLIs = Set(APIProviderCLI.allCases)
        }
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        iconColorHex = try container.decodeIfPresent(String.self, forKey: .iconColorHex)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        let rawOverrides = Dictionary(uniqueKeysWithValues: modelOverrides.map { ($0.key.rawValue, $0.value) })
        try container.encode(rawOverrides, forKey: .modelOverrides)
        try container.encode(enabledCLIs, forKey: .enabledCLIs)
        try container.encodeIfPresent(iconName, forKey: .iconName)
        try container.encodeIfPresent(iconColorHex, forKey: .iconColorHex)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct ConfigurationProviderLibrary: Codable, Sendable, Equatable {
    var cliProviders: [CLIAPIProvider]
    var universalProviders: [UniversalAPIProvider]
    var activeProviderIDs: [APIProviderCLI: String]
    var commonConfigByCLI: [APIProviderCLI: String]

    init(
        cliProviders: [CLIAPIProvider] = [],
        universalProviders: [UniversalAPIProvider] = [],
        activeProviderIDs: [APIProviderCLI: String] = [:],
        commonConfigByCLI: [APIProviderCLI: String] = [:]
    ) {
        self.cliProviders = cliProviders
        self.universalProviders = universalProviders
        self.activeProviderIDs = activeProviderIDs
        self.commonConfigByCLI = commonConfigByCLI
    }

    private enum CodingKeys: String, CodingKey {
        case cliProviders
        case universalProviders
        case activeProviderIDs
        case commonConfigByCLI
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cliProviders = try container.decodeIfPresent(LossyDecodableArray<CLIAPIProvider>.self, forKey: .cliProviders)?.elements ?? []
        universalProviders = try container.decodeIfPresent(LossyDecodableArray<UniversalAPIProvider>.self, forKey: .universalProviders)?.elements ?? []
        activeProviderIDs = Self.decodeCLIMap(
            try container.decodeIfPresent([String: String].self, forKey: .activeProviderIDs) ?? [:]
        )
        commonConfigByCLI = Self.decodeCLIMap(
            try container.decodeIfPresent([String: String].self, forKey: .commonConfigByCLI) ?? [:]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cliProviders, forKey: .cliProviders)
        try container.encode(universalProviders, forKey: .universalProviders)
        try container.encode(Self.encodeCLIMap(activeProviderIDs), forKey: .activeProviderIDs)
        try container.encode(Self.encodeCLIMap(commonConfigByCLI), forKey: .commonConfigByCLI)
    }

    private static func decodeCLIMap(_ raw: [String: String]) -> [APIProviderCLI: String] {
        raw.reduce(into: [:]) { partial, entry in
            if let cli = APIProviderCLI(rawValue: entry.key) {
                partial[cli] = entry.value
            }
        }
    }

    private static func encodeCLIMap(_ map: [APIProviderCLI: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
    }
}
