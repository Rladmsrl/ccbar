import Foundation
import Testing
@testable import ClaudeStats

/// The permission server listens on loopback, but loopback binding does NOT
/// stop a web page in the user's own browser from POSTing to 127.0.0.1
/// (classic localhost CSRF / DNS-rebinding). Claude Code's hooks are curl /
/// URLSession callers that never attach an `Origin` header and always send a
/// loopback `Host`; a browser does the opposite. `isTrustedHookRequest`
/// encodes that distinction.
@Suite("Permission server CSRF guard")
struct PermissionHTTPServerCSRFTests {

    @Test("Trusts a Claude Code hook request: no Origin, loopback Host")
    func trustsCurlHook() {
        let headers = ["host": "127.0.0.1:23333"]
        #expect(PermissionHTTPServer.isTrustedHookRequest(headers: headers))
    }

    @Test("Rejects any request carrying an Origin header (browser CSRF)")
    func rejectsOrigin() {
        let headers = ["origin": "http://evil.example", "host": "127.0.0.1:23333"]
        #expect(PermissionHTTPServer.isTrustedHookRequest(headers: headers) == false)
    }

    @Test("Rejects a non-loopback Host (DNS rebinding)")
    func rejectsNonLoopbackHost() {
        let headers = ["host": "attacker.example:23333"]
        #expect(PermissionHTTPServer.isTrustedHookRequest(headers: headers) == false)
    }

    @Test("Rejects a request with no Host header")
    func rejectsMissingHost() {
        #expect(PermissionHTTPServer.isTrustedHookRequest(headers: [:]) == false)
    }

    @Test("Trusts loopback Host aliases (localhost, IPv6 ::1)")
    func trustsLoopbackAliases() {
        #expect(PermissionHTTPServer.isTrustedHookRequest(headers: ["host": "localhost:23333"]))
        #expect(PermissionHTTPServer.isTrustedHookRequest(headers: ["host": "[::1]:23333"]))
    }
}
