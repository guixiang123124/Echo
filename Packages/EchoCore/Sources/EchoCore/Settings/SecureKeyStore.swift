import Foundation
import Security

/// Secure storage for API keys using the iOS/macOS Keychain
public struct SecureKeyStore: Sendable {
    private let serviceName: String
    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]

    public init(serviceName: String = "com.echo.apikeys") {
        self.serviceName = serviceName
    }

    /// Store an API key securely
    public func store(key: String, for provider: String) throws {
#if DEBUG
        // Dev path: keep UserDefaults fast-path, but also mirror to Keychain so
        // values are visible across processes (App <-> CLI benchmark tools).
        UserDefaults.standard.set(key, forKey: devDefaultsKey(for: provider))
        try storeInKeychain(key: key, for: provider)
        setCachedValue(key, for: provider)
        return
#else
        try storeInKeychain(key: key, for: provider)
        setCachedValue(key, for: provider)
#endif
    }

    /// Retrieve an API key
    public func retrieve(for provider: String) throws -> String? {
        if let cached = cachedValue(for: provider) {
            return cached
        }

#if DEBUG
        // Debug mode: prefer UserDefaults (no prompt), then fallback to Keychain
        // so CLI can still read keys entered by the app and vice versa.
        if let key = UserDefaults.standard.string(forKey: devDefaultsKey(for: provider)), !key.isEmpty {
            setCachedValue(key, for: provider)
            return key
        }
        if let key = try retrieveFromKeychain(for: provider), !key.isEmpty {
            setCachedValue(key, for: provider)
            // backfill defaults for future fast access
            UserDefaults.standard.set(key, forKey: devDefaultsKey(for: provider))
            return key
        }
        return nil
#else
        return try retrieveFromKeychain(for: provider)
#endif
    }

    /// Delete an API key
    public func delete(for provider: String) throws {
#if DEBUG
        UserDefaults.standard.removeObject(forKey: devDefaultsKey(for: provider))
        try deleteFromKeychain(for: provider)
        clearCachedValue(for: provider)
        return
#else
        try deleteFromKeychain(for: provider)
        clearCachedValue(for: provider)
#endif
    }

    /// Check if an API key exists for a provider
    public func hasKey(for provider: String) -> Bool {
        if let cached = cachedValue(for: provider), !cached.isEmpty {
            return true
        }

#if DEBUG
        if UserDefaults.standard.string(forKey: devDefaultsKey(for: provider))?.isEmpty == false {
            return true
        }
        return hasKeyInKeychain(for: provider)
#else
        return hasKeyInKeychain(for: provider)
#endif
    }

    // MARK: - Keychain primitives

    private func storeInKeychain(key: String, for provider: String) throws {
        let data = Data(key.utf8)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider
        ]
        SecItemDelete(deleteQuery as CFDictionary)

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

    private func retrieveFromKeychain(for provider: String) throws -> String? {
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

    private func deleteFromKeychain(for provider: String) throws {
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

    private func hasKeyInKeychain(for provider: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Cache

    private func cacheKey(for provider: String) -> String {
        "\(serviceName)::\(provider)"
    }

    private func devDefaultsKey(for provider: String) -> String {
        "\(serviceName).debug.\(provider)"
    }

    private func cachedValue(for provider: String) -> String? {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        return Self.cache[cacheKey(for: provider)]
    }

    private func setCachedValue(_ value: String, for provider: String) {
        Self.cacheLock.lock()
        Self.cache[cacheKey(for: provider)] = value
        Self.cacheLock.unlock()
    }

    private func clearCachedValue(for provider: String) {
        Self.cacheLock.lock()
        Self.cache.removeValue(forKey: cacheKey(for: provider))
        Self.cacheLock.unlock()
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
