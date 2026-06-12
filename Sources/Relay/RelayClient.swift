import Foundation

/// One item's cleartext metadata from `GET /items` (or an SSE notification).
struct RelayItemMeta: Sendable {
    let id: String
    let seq: Int64
    let type: String
    let size: Int64
}

/// REST client for the relay's item endpoints. Reads the base URL + API key fresh
/// on every call (credentials can change at runtime, and the Keychain may be
/// temporarily locked), and classifies failures as transient (retry) vs terminal so
/// the consumer's pipeline can react per PLAN #3.
final class RelayClient {
    enum RelayClientError: Error, CustomStringConvertible {
        case notConfigured                       // no base URL / API key
        case keychainLocked                      // API key temporarily unreadable (retry later)
        case unauthorized                        // 401/403 (revoked key etc.)
        case notFound                            // 404
        case rateLimited(retryAfter: TimeInterval?)
        case transient(String)                   // network / timeout / 5xx
        case http(Int)                           // other 4xx
        case badResponse

        var description: String {
            switch self {
            case .notConfigured: return "relay not configured"
            case .keychainLocked: return "keychain locked (retry later)"
            case .unauthorized: return "unauthorized (401/403)"
            case .notFound: return "not found (404)"
            case .rateLimited(let r): return "rate limited" + (r.map { " (retry after \($0)s)" } ?? "")
            case .transient(let m): return "transient: \(m)"
            case .http(let c): return "http \(c)"
            case .badResponse: return "bad response"
            }
        }

        /// Whether the consumer should retry after backoff rather than poison.
        var isTransient: Bool {
            switch self {
            case .keychainLocked, .rateLimited, .transient: return true
            case .notConfigured, .unauthorized, .notFound, .http, .badResponse: return false
            }
        }
    }

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300   // a voice blob can be multi-MB on a slow link
        cfg.waitsForConnectivity = false       // the consumer owns reconnect decisions
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "stash-macos/1.0"]
        session = URLSession(configuration: cfg)
    }

    // MARK: - Endpoints
    //
    // Note: there is intentionally no `GET /items?since=N` backlog pull. The
    // relay replays the full `seq > Last-Event-ID` backlog on every SSE connect
    // (see stash-relay sse.rs), so the SSE stream IS the catch-up path — a Mac
    // asleep for hours drains its backlog on reconnect with no separate logic.

    /// `GET /items/{id}` → the opaque encrypted blob.
    func fetchBlob(id: String) async throws -> Data {
        let (base, key) = try resolve()
        var req = URLRequest(url: base.appendingPathComponent("items/\(id)"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return try await perform(req)
    }

    /// `POST /items/{id}/ack` → mark persisted (eligible for purge). Idempotent.
    func ack(id: String) async throws {
        let (base, key) = try resolve()
        var req = URLRequest(url: base.appendingPathComponent("items/\(id)/ack"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        _ = try await perform(req)
    }

    /// `POST /items` (M5 producer) → returns the assigned seq.
    func postItem(id: String, type: String, body: Data) async throws -> Int64 {
        let (base, key) = try resolve()
        var req = URLRequest(url: base.appendingPathComponent("items"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue(id, forHTTPHeaderField: "X-Stash-Item-Id")
        req.setValue(type, forHTTPHeaderField: "X-Stash-Item-Type")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let data = try await perform(req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seq = (obj["seq"] as? NSNumber)?.int64Value else {
            throw RelayClientError.badResponse
        }
        return seq
    }

    // MARK: - Plumbing

    private func resolve() throws -> (URL, String) {
        guard let base = RelayCredentials.baseURL else { throw RelayClientError.notConfigured }
        let key: String?
        do {
            key = try RelayCredentials.apiKey()
        } catch Keychain.KeychainError.interactionNotAllowed {
            throw RelayClientError.keychainLocked
        } catch {
            throw RelayClientError.notConfigured
        }
        guard let key else { throw RelayClientError.notConfigured }
        return (base, key)
    }

    /// Run a request, mapping the response to data or a classified error.
    private func perform(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            throw RelayClientError.transient(urlError.localizedDescription)
        } catch {
            throw RelayClientError.transient(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.badResponse }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw RelayClientError.unauthorized
        case 404:
            throw RelayClientError.notFound
        case 429:
            throw RelayClientError.rateLimited(retryAfter: retryAfter(http))
        case 500...599:
            throw RelayClientError.transient("server \(http.statusCode)")
        default:
            throw RelayClientError.http(http.statusCode)
        }
    }

    private func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let value = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(value.trimmingCharacters(in: .whitespaces))
    }
}
