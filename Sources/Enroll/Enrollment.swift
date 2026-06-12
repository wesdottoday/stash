import Foundation
import Security

/// Device enrollment + E2E-key custody for the relay.
///
/// Two flows:
/// - **Claim** (`handleDeepLink`): the Mac opens a `stash://enroll?relay=&token=[&k=]`
///   link (from the relay CLI's terminal QR, or another enrolled device). It POSTs
///   `/enroll/claim` for its `device_id`+`api_key`, then settles the E2E key: if the
///   link carries `k` it adopts it; otherwise — the Mac is **device #1** — it generates
///   a fresh 32-byte key and becomes the custodian. (This is the inverse of iOS, which
///   refuses custodianship on a key-less link.)
/// - **Link a device** (`createLinkURL`): POSTs `/enroll/create` for a one-time token,
///   then builds a `stash://enroll?…&k=<e2e>` URL carrying the E2E key
///   **device-to-device** (never through the relay) for iOS to scan.
enum Enrollment {

    /// What a successful claim produced, for the confirmation surface.
    struct Summary {
        let deviceId: String
        let relayHost: String
        let isCustodian: Bool   // true ⇒ this device generated the E2E key
    }

    enum EnrollError: Error, CustomStringConvertible {
        case malformedLink
        case notEnrolled
        case noBaseURL
        case http(Int, String)
        case network(String)
        case badResponse
        case keygenFailed
        case keychain(String)

        var description: String {
            switch self {
            case .malformedLink: return "That link wasn't a valid stash enrollment link."
            case .notEnrolled: return "This Mac isn't enrolled with a relay yet."
            case .noBaseURL: return "No relay is configured."
            case .http(let code, let msg):
                return "The relay rejected enrollment (HTTP \(code))." + (msg.isEmpty ? "" : " \(msg)")
            case .network(let msg): return "Couldn't reach the relay. \(msg)"
            case .badResponse: return "The relay returned an unexpected response."
            case .keygenFailed: return "Couldn't generate the encryption key."
            case .keychain(let msg): return "Couldn't save credentials to the Keychain. \(msg)"
            }
        }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = ["User-Agent": "stash-macos/1.0"]
        return URLSession(configuration: cfg)
    }()

    // MARK: - Claim (incoming deep link)

    static func handleDeepLink(_ url: URL) async -> Result<Summary, EnrollError> {
        guard let link = parse(url) else { return .failure(.malformedLink) }
        guard let base = URL(string: link.relayBase) else { return .failure(.malformedLink) }

        // Settle the E2E key BEFORE we claim, so a key-decode failure doesn't
        // leave us half-enrolled.
        let e2eKey: Data
        let isCustodian: Bool
        if let kRaw = link.kRaw {
            guard let decoded = base64URLDecode(kRaw), decoded.count == RelayCredentials.e2eKeyLength else {
                return .failure(.malformedLink)
            }
            e2eKey = decoded
            isCustodian = false
        } else if let existing = try? RelayCredentials.e2eKey() ?? nil {
            // Already a custodian (re-enrolling): keep the existing key so we
            // don't orphan items already committed under it.
            e2eKey = existing
            isCustodian = true
        } else {
            guard let generated = randomBytes(RelayCredentials.e2eKeyLength) else {
                return .failure(.keygenFailed)
            }
            e2eKey = generated
            isCustodian = true
        }

        let creds: (deviceId: String, apiKey: String)
        do {
            creds = try await claim(base: base, token: link.token)
        } catch let e as EnrollError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        do {
            RelayCredentials.setBaseURL(link.relayBase)
            try RelayCredentials.storeDeviceCredentials(deviceId: creds.deviceId, apiKey: creds.apiKey)
            try RelayCredentials.storeE2EKey(e2eKey)
        } catch {
            return .failure(.keychain("\(error)"))
        }

        return .success(Summary(deviceId: creds.deviceId,
                                relayHost: base.host ?? link.relayBase,
                                isCustodian: isCustodian))
    }

    private static func claim(base: URL, token: String) async throws -> (deviceId: String, apiKey: String) {
        var req = URLRequest(url: base.appendingPathComponent("enroll/claim"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw EnrollError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw EnrollError.http(http.statusCode, errorMessage(from: data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceId = obj["device_id"] as? String,
              let apiKey = obj["api_key"] as? String,
              !deviceId.isEmpty, !apiKey.isEmpty else {
            throw EnrollError.badResponse
        }
        return (deviceId, apiKey)
    }

    // MARK: - Link a device (outgoing QR)

    /// Mint a one-time token and build the device-to-device enrollment URL,
    /// carrying the E2E key in the `k` fragment.
    static func createLinkURL(deviceName: String? = nil) async -> Result<URL, EnrollError> {
        guard let rawBase = Preferences.shared.relayBaseURL, let base = URL(string: rawBase) else {
            return .failure(.noBaseURL)
        }
        let apiKey: String?
        let e2eKey: Data?
        do {
            apiKey = try RelayCredentials.apiKey()
            e2eKey = try RelayCredentials.e2eKey()
        } catch {
            return .failure(.keychain("\(error)"))
        }
        guard let apiKey, let e2eKey else { return .failure(.notEnrolled) }

        let token: String
        do {
            token = try await createToken(base: base, apiKey: apiKey,
                                          deviceName: deviceName ?? Host.current().localizedName)
        } catch let e as EnrollError {
            return .failure(e)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        // Reuse the raw stored base string for `relay=` so it matches what the
        // relay minted (no normalization/trailing-slash surprises).
        let k = base64URLEncode(e2eKey)
        let urlString = "stash://enroll?relay=\(rawBase)&token=\(token)&k=\(k)"
        guard let url = URL(string: urlString) else { return .failure(.malformedLink) }
        return .success(url)
    }

    private static func createToken(base: URL, apiKey: String, deviceName: String?) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("enroll/create"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let deviceName, !deviceName.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["device_name": deviceName])
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw EnrollError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw EnrollError.http(http.statusCode, errorMessage(from: data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else {
            throw EnrollError.badResponse
        }
        return token
    }

    // MARK: - Deep-link parsing

    private struct ParsedLink {
        let relayBase: String
        let token: String
        let kRaw: String?
    }

    /// Parse `stash://enroll?relay=<base>&token=<tok>[&k=<key>]`. We parse the
    /// query by hand because the relay embeds an *unencoded* `https://…` URL as
    /// the `relay` value, which round-trips poorly through `URLComponents`.
    private static func parse(_ url: URL) -> ParsedLink? {
        guard url.scheme?.lowercased() == "stash" else { return nil }
        let raw = url.absoluteString
        guard let q = raw.firstIndex(of: "?") else { return nil }
        let query = String(raw[raw.index(after: q)...])

        var params: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq])
            let rawVal = String(pair[pair.index(after: eq)...])
            params[key] = rawVal.removingPercentEncoding ?? rawVal
        }

        guard let relay = params["relay"], !relay.isEmpty,
              let token = params["token"], !token.isEmpty else { return nil }
        return ParsedLink(relayBase: relay, token: token, kRaw: params["k"])
    }

    /// True if `url` is a stash enrollment deep link this app should handle.
    static func isEnrollmentLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "stash" && url.absoluteString.contains("enroll")
    }

    // MARK: - Crypto helpers

    static func randomBytes(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return status == errSecSuccess ? Data(bytes) : nil
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    // MARK: - Misc

    /// Best-effort extraction of an `{"error":"…"}` message from a relay error body.
    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["error"] as? String else { return "" }
        return msg
    }
}
