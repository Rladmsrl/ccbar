import CryptoKit
import Foundation

struct GitRepoStatsCache: Sendable {
    static let currentSchemaVersion = 1

    struct Key: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let repoRootHash: String
        let scope: GitStatsScope
        let headHash: String
        let runtimeSignature: String

        var digest: String {
            Self.sha256([
                "\(schemaVersion)",
                repoRootHash,
                scope.rawValue,
                headHash,
                runtimeSignature,
            ].joined(separator: "|"))
        }

        private static func sha256(_ value: String) -> String {
            let digest = SHA256.hash(data: Data(value.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private enum Bucket: String {
        case base
        case ownership
    }

    private struct Envelope<Payload: Codable>: Codable {
        let key: Key
        let savedAt: Date
        let payload: Payload
    }

    private let directory: URL
    private let schemaVersion: Int

    init(directory: URL? = nil, schemaVersion: Int = Self.currentSchemaVersion) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let bundleID = Bundle.main.bundleIdentifier ?? "com.rladmsrl.ClaudeStats"
            self.directory = caches
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("git-repo-stats", isDirectory: true)
                .appendingPathComponent("v\(schemaVersion)", isDirectory: true)
        }
        self.schemaVersion = schemaVersion
    }

    func key(
        repoRoot: String,
        scope: GitStatsScope,
        headHash: String,
        runtimeSignature: GitStatsRuntimeSignature
    ) -> Key {
        Key(
            schemaVersion: schemaVersion,
            repoRootHash: Self.sha256(repoRoot),
            scope: scope,
            headHash: headHash,
            runtimeSignature: runtimeSignature.value
        )
    }

    func readBase(for key: Key) -> GitRepoInspectorBaseStats? {
        read(GitRepoInspectorBaseStats.self, bucket: .base, key: key)
    }

    func writeBase(_ stats: GitRepoInspectorBaseStats, for key: Key) {
        write(stats, bucket: .base, key: key)
    }

    func readOwnership(for key: Key) -> GitRepoCodeOwnershipStats? {
        read(GitRepoCodeOwnershipStats.self, bucket: .ownership, key: key)
    }

    func writeOwnership(_ stats: GitRepoCodeOwnershipStats, for key: Key) {
        write(stats, bucket: .ownership, key: key)
    }

    private func read<Payload: Codable>(_ type: Payload.Type, bucket: Bucket, key: Key) -> Payload? {
        let url = fileURL(bucket: bucket, key: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope<Payload>.self, from: data)
            guard envelope.key == key, envelope.key.schemaVersion == schemaVersion else { return nil }
            return envelope.payload
        } catch {
            Log.git.error("Git stats cache decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func write<Payload: Codable>(_ payload: Payload, bucket: Bucket, key: Key) {
        do {
            let bucketDirectory = directory.appendingPathComponent(bucket.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: bucketDirectory, withIntermediateDirectories: true)
            let envelope = Envelope(key: key, savedAt: .now, payload: payload)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(envelope)
            try data.write(to: fileURL(bucket: bucket, key: key), options: .atomic)
        } catch {
            Log.git.error("Git stats cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileURL(bucket: Bucket, key: Key) -> URL {
        directory
            .appendingPathComponent(bucket.rawValue, isDirectory: true)
            .appendingPathComponent(key.digest)
            .appendingPathExtension("json")
    }

    private static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
