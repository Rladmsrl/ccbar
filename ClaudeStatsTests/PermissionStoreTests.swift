import Foundation
import Testing
@testable import ClaudeStats

@Suite("Permission store")
@MainActor
struct PermissionStoreTests {
    @Test("Passthrough tools are auto-allowed without queuing")
    func passthroughAutoAllows() {
        let store = PermissionStore()
        var decided: PermissionDecision?
        var dropped = false
        let request = Self.makeRequest(tool: "TaskCreate")

        let queued = store.submit(request) { d in decided = d } drop: { _ in dropped = true }

        #expect(queued == false)
        #expect(store.pending.isEmpty)
        #expect(dropped == false)
        if case .allow = decided {} else { Issue.record("expected .allow") }
    }

    @Test("Do-Not-Disturb drops the connection without responding")
    func dndDropsSilently() {
        let store = PermissionStore()
        store.doNotDisturb = true
        var decided: PermissionDecision?
        var dropReason: String?
        let request = Self.makeRequest(tool: "Bash")

        let queued = store.submit(request) { d in decided = d } drop: { reason in dropReason = reason }

        #expect(queued == false)
        #expect(decided == nil)
        #expect(dropReason == "do-not-disturb")
        #expect(store.pending.isEmpty)
    }

    @Test("Headless sessions auto-deny")
    func headlessAutoDeny() {
        let store = PermissionStore()
        var decided: PermissionDecision?
        let request = Self.makeRequest(tool: "Bash", isHeadless: true)

        let queued = store.submit(request) { d in decided = d } drop: { _ in }

        #expect(queued == false)
        if case .deny = decided {} else { Issue.record("expected .deny") }
    }

    @Test("Duplicate fingerprint within same session attaches to existing request")
    func duplicateFingerprintAttachesToExistingRequest() {
        let store = PermissionStore()
        var firstDecision: PermissionDecision?
        let request = Self.makeRequest(tool: "Bash", fingerprint: "abc")
        _ = store.submit(request) { decision in firstDecision = decision } drop: { _ in }
        #expect(store.pending.count == 1)

        var duplicateDecision: PermissionDecision?
        var droppedReason: String?
        let duplicate = Self.makeRequest(tool: "Bash", fingerprint: "abc")
        let queued = store.submit(duplicate) { decision in duplicateDecision = decision } drop: { reason in droppedReason = reason }

        #expect(queued == true)
        #expect(droppedReason == nil)
        #expect(store.pending.count == 1)
        store.resolve(request.id, decision: .allow(message: nil))
        if case .allow = firstDecision {} else { Issue.record("expected first .allow") }
        if case .allow = duplicateDecision {} else { Issue.record("expected duplicate .allow") }
    }

    @Test("resolve removes from pending and triggers the resolve closure")
    func resolveDispatches() {
        let store = PermissionStore()
        var decided: PermissionDecision?
        let request = Self.makeRequest(tool: "Bash")
        _ = store.submit(request) { d in decided = d } drop: { _ in }
        #expect(store.pending.count == 1)

        store.resolve(request.id, decision: .allow(message: nil))

        #expect(store.pending.isEmpty)
        if case .allow = decided {} else { Issue.record("expected .allow") }
    }

    @Test("dropAll closes every pending request without responding")
    func dropAllDrops() {
        let store = PermissionStore()
        var dropCount = 0
        for i in 0..<3 {
            _ = store.submit(Self.makeRequest(tool: "Bash", session: "s-\(i)", fingerprint: "fp-\(i)")) { _ in } drop: { _ in dropCount += 1 }
        }
        #expect(store.pending.count == 3)
        store.dropAll(reason: "test")
        #expect(store.pending.isEmpty)
        #expect(dropCount == 3)
    }

    private static func makeRequest(
        tool: String,
        session: String = "default",
        fingerprint: String? = nil,
        isHeadless: Bool = false
    ) -> PermissionRequest {
        PermissionRequest(
            agentId: "claude-code",
            sessionId: session,
            toolName: tool,
            toolInput: .object([:]),
            toolUseId: nil,
            toolInputFingerprint: fingerprint,
            suggestions: [],
            isHeadless: isHeadless,
            isElicitation: false
        )
    }
}
