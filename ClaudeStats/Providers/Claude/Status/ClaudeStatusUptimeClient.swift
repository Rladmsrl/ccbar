import Foundation

protocol ClaudeStatusUptimeFetching: Sendable {
    func fetchUptimeHistories(now: Date) async throws -> ClaudeStatusUptimeSnapshot
}

struct ClaudeStatusUptimeClient: ClaudeStatusUptimeFetching {
    private let endpoint: URL

    init(endpoint: URL = URL(string: "https://status.claude.com/")!) {
        self.endpoint = endpoint
    }

    func fetchUptimeHistories(now: Date = .now) async throws -> ClaudeStatusUptimeSnapshot {
        var request = URLRequest(url: endpoint)
        request.setValue(ClaudeStatusClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw ClaudeStatusClient.ClientError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeStatusClient.ClientError.http(status: -1)
        }
        Log.network.notice("Claude Status uptime fetch \(http.statusCode, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000))ms")

        guard (200...299).contains(http.statusCode) else {
            throw ClaudeStatusClient.ClientError.http(status: http.statusCode)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ClaudeStatusClient.ClientError.decoding("invalid HTML encoding")
        }

        do {
            return try ClaudeStatusUptimeHTMLParser.parse(html, fetchedAt: now)
        } catch {
            throw ClaudeStatusClient.ClientError.decoding(String(describing: error))
        }
    }
}
