import Foundation

/// The relay identity + secrets for this device, and the typed view of "what
/// state are we in" that the consumer pipeline keys off (resilience #3/#4).
///
/// Storage split:
/// - **Keychain** (`AfterFirstUnlock`): `deviceId`, `apiKey`, `e2eKey` — the
///   API key and E2E key are secrets; `deviceId` lives here too so it's
///   readable while locked (the self-loop guard needs it).
/// - **UserDefaults** (via `Preferences`): `baseURL` — non-secret, always
///   readable.
enum RelayCredentials {
    private enum Account {
        static let deviceId = "deviceId"
        static let apiKey = "apiKey"
        static let e2eKey = "e2eKey"
    }

    /// E2E content key length — AES-256 ⇒ 32 bytes.
    static let e2eKeyLength = 32

    // MARK: - Base URL (non-secret)

    static var baseURL: URL? {
        guard let s = Preferences.shared.relayBaseURL,
              let url = URL(string: s) else { return nil }
        return url
    }

    static func setBaseURL(_ url: String) {
        Preferences.shared.relayBaseURL = url
    }

    // MARK: - Device id + API key

    static func storeDeviceCredentials(deviceId: String, apiKey: String) throws {
        try Keychain.setString(deviceId, account: Account.deviceId)
        try Keychain.setString(apiKey, account: Account.apiKey)
    }

    /// The device id, or nil if not present. Throws only when the Keychain is
    /// temporarily locked (`.interactionNotAllowed`) so callers can retry.
    static func deviceId() throws -> String? {
        try optionalString(Account.deviceId)
    }

    static func apiKey() throws -> String? {
        try optionalString(Account.apiKey)
    }

    // MARK: - E2E content key

    static func storeE2EKey(_ key: Data) throws {
        precondition(key.count == e2eKeyLength, "E2E key must be \(e2eKeyLength) bytes")
        try Keychain.setData(key, account: Account.e2eKey)
    }

    /// The E2E key, or nil if not present. Throws `.interactionNotAllowed` while
    /// the Keychain is locked (retry-later, distinct from "no key").
    static func e2eKey() throws -> Data? {
        do {
            return try Keychain.getData(account: Account.e2eKey)
        } catch Keychain.KeychainError.notFound {
            return nil
        }
    }

    // MARK: - State

    /// True when the device has a relay URL + API key (enrolled). E2E-key
    /// presence is a separate gate (the consumer pauses when it's missing).
    static var isEnrolled: Bool {
        guard baseURL != nil else { return false }
        return (try? apiKey()) ?? nil != nil
    }

    /// Forget all relay credentials (un-enroll).
    static func clear() {
        try? Keychain.delete(account: Account.deviceId)
        try? Keychain.delete(account: Account.apiKey)
        try? Keychain.delete(account: Account.e2eKey)
        Preferences.shared.relayBaseURL = nil
    }

    // MARK: - Helpers

    private static func optionalString(_ account: String) throws -> String? {
        do {
            return try Keychain.getString(account: account)
        } catch Keychain.KeychainError.notFound {
            return nil
        }
    }
}
