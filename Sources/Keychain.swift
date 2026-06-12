import Foundation
import Security

/// Thin wrapper over the macOS Keychain for the relay's daemon-read secrets
/// (device API key, E2E content key, device id).
///
/// Everything is stored `kSecAttrAccessibleAfterFirstUnlock` (resilience #4):
/// the consumer must be able to read these while the screen is locked (a
/// laptop spends most of its "awake" time locked, and a `didWake`-while-locked
/// reconnect needs the keys). The one state that can't be served while locked
/// is *before the first unlock after boot* — `getData` reports that distinctly
/// (`.interactionNotAllowed`) so callers treat it as **retry-later**, never as
/// "no key" or "decrypt failed."
enum Keychain {
    enum KeychainError: Error, CustomStringConvertible {
        /// No item is stored for this account.
        case notFound
        /// The item exists but can't be read right now (pre-first-unlock or
        /// locked under a stricter policy). Retry later — do NOT treat as
        /// missing.
        case interactionNotAllowed
        /// Any other `OSStatus` failure.
        case unexpected(OSStatus)

        var description: String {
            switch self {
            case .notFound: return "keychain: item not found"
            case .interactionNotAllowed: return "keychain: locked (retry later)"
            case .unexpected(let status): return "keychain: OSStatus \(status)"
            }
        }
    }

    /// The Keychain service all relay secrets share.
    static let service = "com.wesdottoday.stash.relay"

    // MARK: - Data

    /// Store `data` for `account`, replacing any existing value. Written with
    /// `kSecAttrAccessibleAfterFirstUnlock`.
    static func setData(_ data: Data, account: String, service: String = service) throws {
        // Replace semantics: delete then add. (SecItemUpdate can't change the
        // accessibility attribute cleanly, and a fresh add is simplest.)
        try? delete(account: account, service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpected(status) }
    }

    /// Read the data for `account`. Throws `.notFound` if absent and
    /// `.interactionNotAllowed` if the Keychain is locked (retry later).
    static func getData(account: String, service: String = service) throws -> Data {
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
            guard let data = item as? Data else { throw KeychainError.unexpected(status) }
            return data
        case errSecItemNotFound:
            throw KeychainError.notFound
        case errSecInteractionNotAllowed:
            throw KeychainError.interactionNotAllowed
        default:
            throw KeychainError.unexpected(status)
        }
    }

    /// Delete the item for `account` if present (a missing item is success).
    static func delete(account: String, service: String = service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }

    // MARK: - String convenience

    static func setString(_ string: String, account: String, service: String = service) throws {
        try setData(Data(string.utf8), account: account, service: service)
    }

    static func getString(account: String, service: String = service) throws -> String {
        let data = try getData(account: account, service: service)
        guard let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpected(errSecDecode)
        }
        return s
    }
}
