import Foundation
import Security

/// Where provider API keys live. Keychain in production, in-memory in tests.
/// Keys are NEVER stored in SQLite or UserDefaults (FR-A7).
public protocol SecretStoring: Sendable {
    func save(providerId: String, secret: String) throws
    func load(providerId: String) throws -> String?
    func delete(providerId: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case osStatus(OSStatus)
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(providerId: String, secret: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[providerId] = secret
    }

    public func load(providerId: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[providerId]
    }

    public func delete(providerId: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[providerId] = nil
    }
}

/// macOS Keychain implementation: `kSecClassGenericPassword`,
/// service "AINotebook", account = provider id (FR-A7).
public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "AINotebook") {
        self.service = service
    }

    private func baseQuery(providerId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId
        ]
    }

    public func save(providerId: String, secret: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(providerId: providerId)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.osStatus(addStatus) }
        } else {
            guard status == errSecSuccess else { throw SecretStoreError.osStatus(status) }
        }
    }

    public func load(providerId: String) throws -> String? {
        var query = baseQuery(providerId: providerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError.osStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(providerId: String) throws {
        let status = SecItemDelete(baseQuery(providerId: providerId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.osStatus(status)
        }
    }
}
