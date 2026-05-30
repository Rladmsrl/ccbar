import Foundation
import Testing
@testable import ClaudeStats

@Suite("Claude usage-limit bridge installer")
struct ClaudeUsageLimitBridgeInstallerTests {
    @Test("Bridge preserves the highest same-window value for at most one minute")
    func bridgePreservesHighestSameWindowValueForOneMinute() throws {
        let root = try TempDir.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("bridge.sh")
        let cache = root.appendingPathComponent("claude-rate-limits.json")
        let installer = ClaudeUsageLimitBridgeInstaller(
            paths: ClaudePaths(configDirectory: root),
            scriptURL: script,
            cacheURL: cache
        )
        _ = try installer.install()
        let resetAt = 1_768_100_000
        try TempDir.write(#"{"five_hour":{"used_percentage":55,"resets_at":\#(resetAt)},"seven_day":{"used_percentage":10,"resets_at":\#(resetAt)}}"#, to: cache)

        try runBridge(script: script, input: #"{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":\#(resetAt)},"seven_day":{"used_percentage":12,"resets_at":\#(resetAt)}}}"#)
        var snapshot = try readCache(cache)
        #expect(snapshot.fiveHourUsedPercent == 55)
        #expect(snapshot.sevenDayUsedPercent == 12)

        try expireHighWaterCapture(in: cache, keys: ["five_hour", "seven_day"])
        try runBridge(script: script, input: #"{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":\#(resetAt)},"seven_day":{"used_percentage":8,"resets_at":\#(resetAt)}}}"#)
        snapshot = try readCache(cache)
        #expect(snapshot.fiveHourUsedPercent == 30)
        #expect(snapshot.sevenDayUsedPercent == 8)
    }

    private func runBridge(script: URL, input: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]

        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BridgeTestError.failed(status: process.terminationStatus, stderr: error)
        }
    }

    private func readCache(_ url: URL) throws -> CacheSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CacheSnapshot.self, from: data)
    }

    private func expireHighWaterCapture(in url: URL, keys: [String]) throws {
        let data = try Data(contentsOf: url)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expiredAt = Int(Date().timeIntervalSince1970) - 61
        for key in keys {
            var window = try #require(object[key] as? [String: Any])
            window["_ccbar_high_water_captured_at"] = expiredAt
            object[key] = window
        }
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try updated.write(to: url, options: .atomic)
    }
}

private struct CacheSnapshot: Decodable {
    let fiveHour: Window
    let sevenDay: Window

    var fiveHourUsedPercent: Double { fiveHour.usedPercentage }
    var sevenDayUsedPercent: Double { sevenDay.usedPercentage }

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    struct Window: Decodable {
        let usedPercentage: Double

        private enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
        }
    }
}

private enum BridgeTestError: Error {
    case failed(status: Int32, stderr: String)
}
