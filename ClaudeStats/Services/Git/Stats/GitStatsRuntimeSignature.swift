import Foundation

struct GitStatsRuntimeSignature: Codable, Sendable, Equatable {
    let value: String

    static func current(bundle: Bundle = .main) -> GitStatsRuntimeSignature {
        guard let url = manifestURL(in: bundle),
              let data = try? Data(contentsOf: url),
              let value = parseManifest(data) else {
            return GitStatsRuntimeSignature(value: "manifest:missing")
        }
        return GitStatsRuntimeSignature(value: value)
    }

    static func parseManifest(_ data: Data) -> String? {
        guard let manifest = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        let fields = manifest
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        return "manifest:\(fields)"
    }

    private static func manifestURL(in bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: "GitTools") {
            return url
        }
        return bundle.resourceURL?
            .appendingPathComponent("GitTools", isDirectory: true)
            .appendingPathComponent("manifest.json")
    }
}
