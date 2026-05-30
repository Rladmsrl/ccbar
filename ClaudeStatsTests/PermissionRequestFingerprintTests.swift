import Foundation
import Testing
@testable import ClaudeStats

@Suite("PermissionRequest.fingerprint")
struct PermissionRequestFingerprintTests {

    // MARK: - Regression guard (commit 1d6eb9c)
    //
    // Scalar/null top-level values must NOT be fed to
    // `JSONSerialization.data(withJSONObject:)` — it throws an Obj-C
    // NSInvalidArgumentException ("Invalid top-level type in JSON write")
    // that Swift's `try?` cannot catch. The exception unwinds across the
    // PermissionHTTPServer's async task boundary, corrupts Swift 6's
    // `swift_task_isCurrentExecutor` thread-local, and SIGBUSes the main
    // thread on the next @MainActor executor probe.
    //
    // fingerprint(of:) must return nil for these cases instead of calling
    // JSONSerialization.

    @Test(".null returns nil")
    func nullReturnsNil() {
        #expect(PermissionRequest.fingerprint(of: .null) == nil)
    }

    @Test(".bool returns nil")
    func boolReturnsNil() {
        #expect(PermissionRequest.fingerprint(of: .bool(true)) == nil)
        #expect(PermissionRequest.fingerprint(of: .bool(false)) == nil)
    }

    @Test(".number returns nil")
    func numberReturnsNil() {
        #expect(PermissionRequest.fingerprint(of: .number(0)) == nil)
        #expect(PermissionRequest.fingerprint(of: .number(1.5)) == nil)
        #expect(PermissionRequest.fingerprint(of: .number(-42)) == nil)
    }

    @Test(".string returns nil")
    func stringReturnsNil() {
        #expect(PermissionRequest.fingerprint(of: .string("")) == nil)
        #expect(PermissionRequest.fingerprint(of: .string("hi")) == nil)
    }

    // MARK: - Happy path

    @Test(".object returns a 40-char SHA1 hex digest")
    func objectReturnsSHA1Hex() {
        let fp = PermissionRequest.fingerprint(
            of: .object(["command": .string("ls -la")])
        )
        #expect(fp != nil)
        #expect(fp?.count == 40)
        #expect(fp?.allSatisfy { $0.isHexDigit } == true)
    }

    @Test(".array returns a 40-char SHA1 hex digest")
    func arrayReturnsSHA1Hex() {
        let fp = PermissionRequest.fingerprint(
            of: .array([.string("a"), .number(1)])
        )
        #expect(fp != nil)
        #expect(fp?.count == 40)
        #expect(fp?.allSatisfy { $0.isHexDigit } == true)
    }

    // MARK: - Stability

    @Test("Identical inputs produce identical fingerprints")
    func identicalInputsHashSame() {
        let input: PermissionJSONValue = .object([
            "command": .string("git status"),
            "cwd": .string("/tmp"),
        ])
        let first = PermissionRequest.fingerprint(of: input)
        let second = PermissionRequest.fingerprint(of: input)
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("Object key order does not affect fingerprint (sortedKeys)")
    func keyOrderIndependent() {
        let abOrder: PermissionJSONValue = .object([
            "a": .number(1),
            "b": .number(2),
        ])
        let baOrder: PermissionJSONValue = .object([
            "b": .number(2),
            "a": .number(1),
        ])
        let abFp = PermissionRequest.fingerprint(of: abOrder)
        let baFp = PermissionRequest.fingerprint(of: baOrder)
        #expect(abFp != nil)
        #expect(abFp == baFp)
    }

    @Test("Different payloads produce different fingerprints")
    func differentInputsHashDifferently() {
        let lsFp = PermissionRequest.fingerprint(of: .object(["command": .string("ls")]))
        let rmFp = PermissionRequest.fingerprint(of: .object(["command": .string("rm")]))
        #expect(lsFp != nil)
        #expect(rmFp != nil)
        #expect(lsFp != rmFp)
    }
}
