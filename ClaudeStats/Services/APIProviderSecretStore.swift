import Foundation
import Security

protocol APIProviderSecretStoring: Sendable {
    func readAPIKey(account: String) -> String?
    func saveAPIKey(_ apiKey: String, account: String) throws
    func deleteAPIKey(account: String)
}

struct APIProviderKeychainStore: APIProviderSecretStoring {
    static let shared = APIProviderKeychainStore()

    private let service = "com.rladmsrl.api-providers"

    func readAPIKey(account: String) -> String? {
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
            Log.app.error("API provider Keychain read failed: OSStatus \(status, privacy: .public)")
            return nil
        }
    }

    func saveAPIKey(_ apiKey: String, account: String) throws {
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

    func deleteAPIKey(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.app.error("API provider Keychain delete failed: OSStatus \(status, privacy: .public)")
        }
    }

    enum KeychainError: Error, Sendable {
        case invalidAPIKey
        case osStatus(OSStatus)
    }
}

final class InMemoryAPIProviderSecretStore: APIProviderSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readAPIKey(account: String) -> String? {
        lock.withLock { values[account] }
    }

    func saveAPIKey(_ apiKey: String, account: String) {
        lock.withLock { values[account] = apiKey }
    }

    func deleteAPIKey(account: String) {
        lock.withLock { _ = values.removeValue(forKey: account) }
    }
}
