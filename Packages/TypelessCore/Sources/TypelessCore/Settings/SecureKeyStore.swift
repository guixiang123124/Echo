import Foundation
import Security

/// Secure storage for API keys using the iOS/macOS Keychain
public struct SecureKeyStore: Sendable {
    private let serviceName: String

    public init(serviceName: String = "com.typeless.apikeys") {
        self.serviceName = serviceName
    }

    /// Store an API key securely
    public func store(key: String, for provider: String) throws {
        let data = Data(key.utf8)

        // Delete existing entry first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.storeFailed(status: status)
        }
    }

    /// Retrieve an API key
    public func retrieve(for provider: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeyStoreError.retrieveFailed(status: status)
        }
    }

    /// Delete an API key
    public func delete(for provider: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.deleteFailed(status: status)
        }
    }

    /// Check if an API key exists for a provider
    public func hasKey(for provider: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

/// Errors from keychain operations
public enum KeyStoreError: Error, Sendable {
    case storeFailed(status: OSStatus)
    case retrieveFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    public var localizedDescription: String {
        switch self {
        case .storeFailed(let status):
            return "Failed to store key: OSStatus \(status)"
        case .retrieveFailed(let status):
            return "Failed to retrieve key: OSStatus \(status)"
        case .deleteFailed(let status):
            return "Failed to delete key: OSStatus \(status)"
        }
    }
}
