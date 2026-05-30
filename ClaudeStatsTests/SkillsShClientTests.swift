import Foundation
import Testing
@testable import ClaudeStats

@Suite("skills.sh client")
struct SkillsShClientTests {
    @Test("Search sends bearer auth and decodes skill summaries")
    func searchDecodesSkills() async throws {
        let client = makeClient { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test")
            #expect(request.url?.path == "/api/v1/skills/search")
            #expect(request.url?.query?.contains("q=react") == true)
            return response(
                status: 200,
                body: """
                {
                  "data": [
                    {
                      "id": "expo/skills/react-native",
                      "slug": "react-native",
                      "name": "React Native",
                      "source": "expo/skills",
                      "installs": 3842,
                      "sourceType": "github",
                      "installUrl": "https://github.com/expo/skills",
                      "url": "https://skills.sh/expo/skills/react-native"
                    }
                  ],
                  "count": 1
                }
                """
            )
        }

        let skills = try await client.search(query: "react", apiKey: "sk_test", limit: 5)
        #expect(skills.count == 1)
        #expect(skills.first?.id == "expo/skills/react-native")
        #expect(skills.first?.installCommand == "npx skills add https://github.com/expo/skills")
    }

    @Test("Detail and audit decode file snapshots and partner results")
    func detailAndAuditDecode() async throws {
        let client = makeClient { request in
            if request.url?.path.contains("/audit/") == true {
                return response(
                    status: 200,
                    body: """
                    {
                      "id": "owner/repo/skill",
                      "source": "owner/repo",
                      "slug": "skill",
                      "audits": [
                        {
                          "provider": "Socket",
                          "slug": "socket",
                          "status": "pass",
                          "summary": "No alerts",
                          "auditedAt": "2026-04-15T12:05:00.000Z",
                          "riskLevel": "LOW"
                        }
                      ]
                    }
                    """
                )
            }
            return response(
                status: 200,
                body: """
                {
                  "id": "owner/repo/skill",
                  "source": "owner/repo",
                  "slug": "skill",
                  "installs": 12,
                  "hash": "abc",
                  "files": [
                    { "path": "SKILL.md", "contents": "---\\nname: Skill\\n---\\n" }
                  ]
                }
                """
            )
        }

        async let detailRequest = client.detail(id: "owner/repo/skill", apiKey: "sk_test")
        async let auditRequest = client.audit(id: "owner/repo/skill", apiKey: "sk_test")
        let (detail, audit) = try await (detailRequest, auditRequest)

        #expect(detail.hash == "abc")
        #expect(detail.skillMarkdown?.contains("name: Skill") == true)
        #expect(audit?.audits.first?.provider == "Socket")
        #expect(audit?.audits.first?.riskLevel == "LOW")
    }

    @Test("HTTP auth and rate limit failures map to typed errors")
    func errorMapping() async throws {
        let unauthorized = makeClient { _ in response(status: 401, body: #"{"message":"bad key"}"#) }
        await #expect(throws: SkillsShClient.ClientError.unauthorized) {
            try await unauthorized.curated(apiKey: "bad")
        }

        let rateLimited = makeClient { _ in response(status: 429, body: #"{"message":"slow down"}"#, headers: ["Retry-After": "60"]) }
        do {
            _ = try await rateLimited.leaderboard(apiKey: "sk_test", view: "hot", limit: 1)
            Issue.record("Expected rate limit error")
        } catch let error as SkillsShClient.ClientError {
            if case .rateLimited(let retryAfter) = error {
                #expect(retryAfter != nil)
            } else {
                Issue.record("Unexpected error \(error)")
            }
        }
    }

    private func makeClient(handler: @escaping @Sendable (URLRequest) throws -> MockSkillsResponse) -> SkillsShClient {
        MockSkillsURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSkillsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return SkillsShClient(baseURL: URL(string: "https://skills.sh")!, session: session)
    }

    private func response(status: Int, body: String, headers: [String: String] = [:]) -> MockSkillsResponse {
        MockSkillsResponse(status: status, headers: headers, data: Data(body.utf8))
    }
}

struct MockSkillsResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
}

final class MockSkillsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> MockSkillsResponse)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let mock = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: mock.status,
                httpVersion: nil,
                headerFields: mock.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: mock.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
