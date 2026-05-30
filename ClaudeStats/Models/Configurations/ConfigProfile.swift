import Foundation

private struct LossyConfigProfileArray: Decodable {
    var profiles: [ConfigProfile]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var profiles: [ConfigProfile] = []
        while !container.isAtEnd {
            if let decoded = try container.decode(LossyConfigProfile.self).profile {
                profiles.append(decoded)
            }
        }
        self.profiles = profiles
    }
}

private struct LossyConfigProfile: Decodable {
    var profile: ConfigProfile?

    init(from decoder: Decoder) throws {
        profile = try? ConfigProfile(from: decoder)
    }
}

struct ConfigProfile: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var provider: ProviderKind
    var scope: ConfigProfileScope
    var name: String
    var files: [ConfigFileSnapshot]
    var createdAt: Date
    var updatedAt: Date
    var lastAppliedAt: Date?

    init(
        id: UUID = UUID(),
        provider: ProviderKind,
        scope: ConfigProfileScope,
        name: String,
        files: [ConfigFileSnapshot],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastAppliedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.scope = scope
        self.name = name
        self.files = files
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAppliedAt = lastAppliedAt
    }
}

struct ConfigurationProfileLibrary: Codable, Sendable, Equatable {
    var profiles: [ConfigProfile]
    var activeProfileIDsByProvider: [ProviderKind: UUID]
    var latestBackupDirectoryByProfileID: [UUID: String]

    init(
        profiles: [ConfigProfile] = [],
        activeProfileIDsByProvider: [ProviderKind: UUID] = [:],
        latestBackupDirectoryByProfileID: [UUID: String] = [:]
    ) {
        self.profiles = profiles
        self.activeProfileIDsByProvider = activeProfileIDsByProvider
        self.latestBackupDirectoryByProfileID = latestBackupDirectoryByProfileID
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
        case activeProfileIDsByProvider
        case latestBackupDirectoryByProfileID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode(LossyConfigProfileArray.self, forKey: .profiles).profiles

        let activeRaw = try container.decodeIfPresent([String: UUID].self, forKey: .activeProfileIDsByProvider) ?? [:]
        activeProfileIDsByProvider = Dictionary(
            uniqueKeysWithValues: activeRaw.compactMap { key, value in
                guard let provider = ProviderKind(rawValue: key) else { return nil }
                return (provider, value)
            }
        )

        let backupRaw = try container.decodeIfPresent([String: String].self, forKey: .latestBackupDirectoryByProfileID) ?? [:]
        latestBackupDirectoryByProfileID = Dictionary(
            uniqueKeysWithValues: backupRaw.compactMap { key, value in
                guard let id = UUID(uuidString: key) else { return nil }
                return (id, value)
            }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(
            Dictionary(uniqueKeysWithValues: activeProfileIDsByProvider.map { ($0.key.rawValue, $0.value) }),
            forKey: .activeProfileIDsByProvider
        )
        try container.encode(
            Dictionary(uniqueKeysWithValues: latestBackupDirectoryByProfileID.map { ($0.key.uuidString, $0.value) }),
            forKey: .latestBackupDirectoryByProfileID
        )
    }
}
