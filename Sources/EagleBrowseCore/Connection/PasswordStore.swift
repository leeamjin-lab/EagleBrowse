import Foundation
import Security

public protocol PasswordStore: Sendable {
    func readPassword(for connectionID: UUID) throws -> String?
    func savePassword(_ password: String, for connectionID: UUID) throws
    func deletePassword(for connectionID: UUID) throws
}

public final class KeychainPasswordStore: PasswordStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.zekui.eaglebrowse") {
        self.service = service
    }

    public func readPassword(for connectionID: UUID) throws -> String? {
        var query = baseQuery(for: connectionID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
        return String(data: data, encoding: .utf8)
    }

    public func savePassword(_ password: String, for connectionID: UUID) throws {
        let data = Data(password.utf8)
        let query = baseQuery(for: connectionID)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    public func deletePassword(for connectionID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: connectionID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for connectionID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString
        ]
    }
}

public struct KeychainError: Error, LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        "Keychain 操作失败（OSStatus \(status)）"
    }
}
