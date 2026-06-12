import Foundation
import os

/// Posts local Mac captures to the relay so other clients stay current (M5).
///
/// The local write into `_inbox/` is the system of record and always happens
/// first; relaying is **best-effort** (the Mac is the hub — a failed POST only
/// means a *viewer* client misses an update, never data loss). Each capture gets
/// a fresh lowercase UUID, is sealed under the E2E key, and is POSTed with the
/// `X-Stash-Item-*` headers.
///
/// **Self-loop guard:** the id is recorded self-originated **before** the POST so
/// that when the relay echoes it back over this Mac's own SSE stream, the
/// consumer skips the (duplicate) write but still advances the cursor + acks
/// (PLAN M5 — else a permanent cursor hole / relay leak). If the POST ultimately
/// fails (no echo will ever come), the marker is removed so it doesn't leak.
final class RelayProducer: @unchecked Sendable {
    private let log = Logger(subsystem: "com.wesdottoday.stash", category: "relay.producer")
    private let client = RelayClient()
    private let store: SyncStore

    /// Don't read very large files into memory just to relay them; the local
    /// copy is authoritative and the relay enforces a max body anyway.
    private let maxRelayBytes = 50 * 1024 * 1024

    init(store: SyncStore) { self.store = store }

    // MARK: - Public publish entry points

    func publishText(_ text: String, sourceApp: String?, capturedAt: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let type: RelayItemType = (URLDetector.firstURL(in: text) != nil) ? .url : .text
        publish(type: type) { id, key in
            Envelope.sealMarkdown(text: text, sourceApp: sourceApp,
                                  meta: Self.meta(capturedAt), itemId: id, key: key)
        }
    }

    func publishImage(_ data: Data, filename: String? = nil, mime: String? = nil, capturedAt: Date = Date()) {
        guard !data.isEmpty, data.count <= maxRelayBytes else { return }
        publish(type: .image) { id, key in
            Envelope.sealBinary(data: data, filename: filename, mime: mime,
                                meta: Self.meta(capturedAt), itemId: id, key: key)
        }
    }

    func publishFile(_ data: Data, filename: String?, mime: String? = nil, capturedAt: Date = Date()) {
        guard !data.isEmpty, data.count <= maxRelayBytes else { return }
        publish(type: .file) { id, key in
            Envelope.sealBinary(data: data, filename: filename, mime: mime,
                                meta: Self.meta(capturedAt), itemId: id, key: key)
        }
    }

    func publishVoice(audio: Data, vtt: String, capturedAt: Date) {
        guard !audio.isEmpty, audio.count <= maxRelayBytes else { return }
        publish(type: .voice) { id, key in
            Envelope.sealVoice(audio: audio, vtt: vtt, meta: Self.meta(capturedAt), itemId: id, key: key)
        }
    }

    // MARK: - Plumbing

    private static func meta(_ capturedAt: Date) -> CaptureMeta {
        CaptureMeta(capturedAt: capturedAt,
                    utcOffsetSeconds: TimeZone.current.secondsFromGMT(for: capturedAt))
    }

    private func publish(type: RelayItemType, build: @escaping @Sendable (_ id: String, _ key: Data) -> Data) {
        // Best-effort: skip silently if not enrolled or the key isn't available.
        guard RelayCredentials.isEnrolled else { return }
        let key: Data
        do {
            guard let k = try RelayCredentials.e2eKey() else { return }
            key = k
        } catch {
            return   // keychain locked / unavailable — skip this relay copy
        }

        let id = UUID().uuidString.lowercased()
        // Record BEFORE posting so the echo can't beat the guard into place.
        store.recordSelfOriginated(id: id)

        // Seal off the caller's thread (this is on the capture dismiss path for
        // window captures; a large file's seal must not block it).
        Task { [weak self] in
            let body = build(id, key)
            await self?.post(id: id, type: type, body: body)
        }
    }

    private func post(id: String, type: RelayItemType, body: Data) async {
        var attempt = 0
        while attempt < 5 {
            do {
                _ = try await client.postItem(id: id, type: type.rawValue, body: body)
                return   // success — the relay has it; the echo will clear the marker
            } catch let e as RelayClient.RelayClientError where e.isTransient {
                attempt += 1
                let delay = min(30.0, pow(2.0, Double(attempt)))
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 0.5...delay) * 1_000_000_000))
            } catch {
                break   // terminal (413, 4xx, etc.)
            }
        }
        // Gave up: no echo will arrive, so drop the self-originated marker.
        store.removeSelfOriginated(id: id)
        log.error("relay publish failed for \(type.rawValue, privacy: .public) item")
    }
}
