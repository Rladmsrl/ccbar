import Foundation

protocol SkillsShClienting: Sendable {
    func leaderboard(apiKey: String, view: String, limit: Int) async throws -> [RemoteSkillSummary]
    func search(query: String, apiKey: String, limit: Int) async throws -> [RemoteSkillSummary]
    func curated(apiKey: String) async throws -> [SkillsShCuratedOwner]
    func detail(id: String, apiKey: String) async throws -> RemoteSkillDetail
    func audit(id: String, apiKey: String) async throws -> SkillsShAuditReport?
}

struct SkillsShClient: @unchecked Sendable, SkillsShClienting {
    enum ClientError: Error, Sendable, CustomStringConvertible, Equatable {
        case missingAPIKey
        case unauthorized
        case rateLimited(retryAfter: Date?)
        case notFound
        case http(status: Int, message: String?)
        case network(URLError)
        case decoding(String)

        var description: String {
            switch self {
            case .missingAPIKey:
                "Add a skills.sh API key to use Discover and Curated."
            case .unauthorized:
                "skills.sh rejected this API key."
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    "skills.sh rate limit hit. Try again \(Format.relativeDate(retryAfter))."
                } else {
                    "skills.sh rate limit hit. Try again later."
                }
            case .notFound:
                "Skill not found on skills.sh."
            case .http(let status, let message):
                message ?? "skills.sh returned HTTP \(status)."
            case .network:
                "skills.sh is offline or unreachable."
            case .decoding:
                "skills.sh returned an unexpected response shape."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://skills.sh")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func leaderboard(apiKey: String, view: String = "trending", limit: Int = 100) async throws -> [RemoteSkillSummary] {
        let request = try makeRequest(
            path: "/api/v1/skills",
            queryItems: [
                URLQueryItem(name: "view", value: view),
                URLQueryItem(name: "per_page", value: "\(limit)"),
            ],
            apiKey: apiKey
        )
        let response: SkillsListResponse = try await fetch(request)
        return response.data
    }

    func search(query: String, apiKey: String, limit: Int = 50) async throws -> [RemoteSkillSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let request = try makeRequest(
            path: "/api/v1/skills/search",
            queryItems: [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ],
            apiKey: apiKey
        )
        let response: SkillsListResponse = try await fetch(request)
        return response.data
    }

    func curated(apiKey: String) async throws -> [SkillsShCuratedOwner] {
        let request = try makeRequest(path: "/api/v1/skills/curated", apiKey: apiKey)
        let response: SkillsCuratedResponse = try await fetch(request)
        return response.data
    }

    func detail(id: String, apiKey: String) async throws -> RemoteSkillDetail {
        let request = try makeRequest(path: "/api/v1/skills/\(id)", apiKey: apiKey)
        return try await fetch(request)
    }

    func audit(id: String, apiKey: String) async throws -> SkillsShAuditReport? {
        let request = try makeRequest(path: "/api/v1/skills/audit/\(id)", apiKey: apiKey)
        do {
            return try await fetch(request)
        } catch ClientError.notFound {
            return nil
        }
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        apiKey: String
    ) throws -> URLRequest {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ClientError.missingAPIKey }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw ClientError.http(status: -1, message: "Could not build skills.sh URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ClientError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClientError.http(status: -1, message: nil)
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw ClientError.unauthorized
        case 404:
            throw ClientError.notFound
        case 429:
            throw ClientError.rateLimited(retryAfter: retryAfter(http: http))
        default:
            throw ClientError.http(status: http.statusCode, message: errorMessage(from: data))
        }

        do {
            let decoder = Self.makeDecoder()
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ClientError.decoding(String(describing: error))
        }
    }

    private func retryAfter(http: HTTPURLResponse) -> Date? {
        if let value = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(value) {
            return Date().addingTimeInterval(seconds)
        }
        if let value = http.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let seconds = TimeInterval(value) {
            return Date().addingTimeInterval(seconds)
        }
        return nil
    }

    private func errorMessage(from data: Data) -> String? {
        let decoder = Self.makeDecoder()
        guard let response = try? decoder.decode(SkillsErrorResponse.self, from: data) else {
            return nil
        }
        return response.message
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = Self.parseISO8601Date(value) {
                return date
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 date")
            )
        }
        return decoder
    }

    private static let userAgent: String = {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        return "CCBar/\(version)"
    }()

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct SkillsListResponse: Decodable {
    let data: [RemoteSkillSummary]
}

private struct SkillsCuratedResponse: Decodable {
    let data: [SkillsShCuratedOwner]
}

private struct SkillsErrorResponse: Decodable {
    let error: String?
    let message: String?
}
