import Foundation
import Security

protocol SkillsShCredentialStoring: Sendable {
    func readAPIKey() -> String?
    func saveAPIKey(_ apiKey: String) throws
    func deleteAPIKey()
}

struct SkillsShKeychainStore: SkillsShCredentialStoring {
    static let shared = SkillsShKeychainStore()

    private let service = "com.rladmsrl.skills-sh"
    private let account = "skills.sh"

    func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            Log.app.error("skills.sh Keychain read failed: OSStatus \(status, privacy: .public)")
            return nil
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw KeychainError.invalidAPIKey
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        default:
            throw KeychainError.osStatus(updateStatus)
        }
    }

    func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.app.error("skills.sh Keychain delete failed: OSStatus \(status, privacy: .public)")
        }
    }

    enum KeychainError: Error, Sendable {
        case invalidAPIKey
        case osStatus(OSStatus)
    }
}

final class InMemorySkillsShCredentialStore: SkillsShCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(apiKey: String? = nil) {
        value = apiKey
    }

    func readAPIKey() -> String? {
        lock.withLock { value }
    }

    func saveAPIKey(_ apiKey: String) {
        lock.withLock { value = apiKey }
    }

    func deleteAPIKey() {
        lock.withLock { value = nil }
    }
}
