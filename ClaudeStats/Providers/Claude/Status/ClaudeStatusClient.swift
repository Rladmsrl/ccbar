import Foundation

protocol ClaudeStatusFetching: Sendable {
    func fetchSummary(now: Date) async throws -> ClaudeStatusSnapshot
}

struct ClaudeStatusClient: ClaudeStatusFetching {
    enum ClientError: Error, Sendable, CustomStringConvertible, Equatable {
        case http(status: Int)
        case network(String)
        case decoding(String)

        var description: String {
            switch self {
            case .http(let status): "Claude Status returned HTTP \(status)."
            case .network: "Claude Status is unreachable."
            case .decoding: "Claude Status returned an unexpected response."
            }
        }
    }

    private let endpoint: URL

    init(endpoint: URL = URL(string: "https://status.claude.com/api/v2/summary.json")!) {
        self.endpoint = endpoint
    }

    func fetchSummary(now: Date = .now) async throws -> ClaudeStatusSnapshot {
        var request = URLRequest(url: endpoint)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw ClientError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(status: -1)
        }
        Log.network.notice("Claude Status fetch \(http.statusCode, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000))ms")

        guard (200...299).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode)
        }
        return try Self.decodeSummary(data, now: now)
    }

    static func decodeSummary(_ data: Data, now: Date = .now) throws -> ClaudeStatusSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        do {
            let response = try decoder.decode(StatusPageSummaryResponse.self, from: data)
            return response.snapshot(fetchedAt: now)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) {
            return date
        }
        throw ClientError.decoding("invalid date: \(raw)")
    }

    static let userAgent: String = {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        return "CCBar/\(version)"
    }()
}

private struct StatusPageSummaryResponse: Decodable {
    let page: Page
    let components: [Component]
    let incidents: [Incident]
    let scheduledMaintenances: [Maintenance]
    let status: Status

    enum CodingKeys: String, CodingKey {
        case page
        case components
        case incidents
        case scheduledMaintenances = "scheduled_maintenances"
        case status
    }

    func snapshot(fetchedAt: Date) -> ClaudeStatusSnapshot {
        ClaudeStatusSnapshot(
            pageName: page.name,
            pageUpdatedAt: page.updatedAt,
            rollup: ClaudeStatusRollup(
                severity: ClaudeStatusSeverity(indicator: status.indicator),
                description: status.description
            ),
            components: components
                .map(\.model)
                .sorted { lhs, rhs in
                    if lhs.position == rhs.position { return lhs.name < rhs.name }
                    return lhs.position < rhs.position
                },
            incidents: incidents.map(\.model),
            scheduledMaintenances: scheduledMaintenances.map(\.model),
            fetchedAt: fetchedAt
        )
    }

    struct Page: Decodable {
        let name: String
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case name
            case updatedAt = "updated_at"
        }
    }

    struct Status: Decodable {
        let indicator: String
        let description: String
    }

    struct Component: Decodable {
        let id: String
        let name: String
        let status: String
        let updatedAt: Date?
        let position: Int

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case status
            case updatedAt = "updated_at"
            case position
        }

        var model: ClaudeStatusComponent {
            ClaudeStatusComponent(
                id: id,
                name: name,
                status: ClaudeStatusSeverity(componentStatus: status),
                updatedAt: updatedAt,
                position: position
            )
        }
    }

    struct Incident: Decodable {
        let id: String
        let name: String
        let status: String
        let impact: String?
        let shortlink: URL?
        let startedAt: Date?
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case status
            case impact
            case shortlink
            case startedAt = "started_at"
            case updatedAt = "updated_at"
        }

        var model: ClaudeStatusIncident {
            ClaudeStatusIncident(
                id: id,
                name: name,
                status: status,
                impact: ClaudeStatusSeverity(indicator: impact ?? "none"),
                shortlink: shortlink,
                startedAt: startedAt,
                updatedAt: updatedAt
            )
        }
    }

    struct Maintenance: Decodable {
        let id: String
        let name: String
        let status: String
        let impact: String?
        let shortlink: URL?
        let scheduledFor: Date?
        let scheduledUntil: Date?
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case status
            case impact
            case shortlink
            case scheduledFor = "scheduled_for"
            case scheduledUntil = "scheduled_until"
            case updatedAt = "updated_at"
        }

        var model: ClaudeStatusMaintenance {
            ClaudeStatusMaintenance(
                id: id,
                name: name,
                status: status,
                impact: ClaudeStatusSeverity(indicator: impact ?? "none"),
                shortlink: shortlink,
                scheduledFor: scheduledFor,
                scheduledUntil: scheduledUntil,
                updatedAt: updatedAt
            )
        }
    }
}
