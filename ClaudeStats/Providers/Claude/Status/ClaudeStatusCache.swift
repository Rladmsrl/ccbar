import Foundation

protocol ClaudeStatusCaching: Sendable {
    func read(ttl: TimeInterval, now: Date) -> (snapshot: ClaudeStatusSnapshot, isStale: Bool)?
    func write(_ snapshot: ClaudeStatusSnapshot) throws
}

struct ClaudeStatusCache: ClaudeStatusCaching {
    static let defaultTTL: TimeInterval = 5 * 60

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let bundleID = Bundle.main.bundleIdentifier ?? "com.rladmsrl.ClaudeStats"
            self.fileURL = caches
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("claude-status", isDirectory: true)
                .appendingPathComponent("summary.json", isDirectory: false)
        }
    }

    func read(ttl: TimeInterval = Self.defaultTTL, now: Date = .now) -> (snapshot: ClaudeStatusSnapshot, isStale: Bool)? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let snapshot = try decoder.decode(ClaudeStatusSnapshot.self, from: data)
            return (snapshot, now.timeIntervalSince(snapshot.fetchedAt) > ttl)
        } catch {
            Log.app.error("Claude Status cache decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func write(_ snapshot: ClaudeStatusSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
