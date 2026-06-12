import CryptoKit
import Foundation

/// The relay item types (cleartext routing; the payload itself is opaque to the relay).
enum RelayItemType: String, Sendable {
    case text, url, image, file, voice
}

/// Capture-time fidelity carried *inside* the encrypted payload (zero-knowledge —
/// never a cleartext header). The consumer stamps `created`/filenames from this so a
/// laptop draining a stale backlog reconstructs the original wall-clock, not drain time.
struct CaptureMeta: Sendable {
    let capturedAt: Date
    let utcOffsetSeconds: Int
}

/// A decrypted, parsed relay payload, ready for the consumer to write into the vault.
enum RelayPayload: Sendable {
    /// `text`/`url`: raw text + optional source app. The Mac owns URL detection,
    /// markdown wrapping, hashtag extraction, and the filename.
    case markdown(text: String, sourceApp: String?, meta: CaptureMeta)
    /// `image`/`file`: the raw bytes + optional original filename/mime.
    case binary(type: RelayItemType, data: Data, filename: String?, mime: String?, meta: CaptureMeta)
    /// `voice`: the ALAC `.m4a` bytes + the WebVTT transcript.
    case voice(audio: Data, vtt: String, meta: CaptureMeta)
}

/// E2E envelope open + inner-payload parsing.
///
/// Pinned by `stash-relay/tests/crypto_roundtrip.rs` (the authoritative contract);
/// every detail below must match byte-for-byte or decrypt fails silently:
/// - **Cipher:** AES-256-GCM, CryptoKit `.combined` layout `nonce(12) ‖ ct(N) ‖ tag(16)`.
/// - **AAD:** the item id as its 36-char **lowercase** hyphenated UUID string, UTF-8.
///   For voice each part's AAD is `id_bytes ‖ role_byte`.
/// - **Voice container:** `[u32_LE audio_len][audio][u32_LE vtt_len][vtt][u32_LE meta_len][meta]`,
///   each part independently sealed with its role byte prepended to the plaintext.
/// - **Inner JSON:** `{schema_version, captured_at (epoch seconds), utc_offset_seconds, text?, source_app?, filename?, mime?}`.
/// - **image/file** frame the JSON + raw bytes as `[u32_LE json_len][json][bytes]` *inside* one seal.
enum Envelope {
    /// All envelope failures are **terminal** (poison): a wrong key, tampered ciphertext,
    /// or malformed framing can't be fixed by retrying, and acking would let the relay
    /// purge the evidence (see PLAN #3). The consumer poisons the item and surfaces it.
    enum EnvelopeError: Error, CustomStringConvertible {
        case authenticationFailure   // GCM tag mismatch (wrong key / tampered / AAD mismatch)
        case malformed(String)       // bad container framing or unparseable inner payload

        var description: String {
            switch self {
            case .authenticationFailure: return "decryption failed (wrong key, tampered, or AAD mismatch)"
            case .malformed(let why): return "malformed payload: \(why)"
            }
        }
    }

    // Voice part role bytes (pinned).
    private static let roleAudio: UInt8 = 0x01
    private static let roleVTT: UInt8 = 0x02
    private static let roleMeta: UInt8 = 0x03

    // MARK: - Seal (producer side, M5)
    //
    // The inverse of `decrypt`, used when this Mac posts a local capture to the
    // relay. Same pinned layout: a fresh random nonce per seal (CryptoKit's
    // default), `.combined` output, AAD = lowercase item id (‖ role for voice),
    // little-endian frame lengths, and the same inner JSON / framing.

    static func sealMarkdown(text: String, sourceApp: String?, meta: CaptureMeta, itemId: String, key: Data) -> Data {
        var obj: [String: Any] = [
            "schema_version": 1,
            "captured_at": Int(meta.capturedAt.timeIntervalSince1970),
            "utc_offset_seconds": meta.utcOffsetSeconds,
            "text": text,
        ]
        if let sourceApp, !sourceApp.isEmpty { obj["source_app"] = sourceApp }
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return sealOne(json, key: key, aad: Data(itemId.utf8))
    }

    static func sealBinary(data: Data, filename: String?, mime: String?, meta: CaptureMeta, itemId: String, key: Data) -> Data {
        var obj: [String: Any] = [
            "schema_version": 1,
            "captured_at": Int(meta.capturedAt.timeIntervalSince1970),
            "utc_offset_seconds": meta.utcOffsetSeconds,
        ]
        if let filename, !filename.isEmpty { obj["filename"] = filename }
        if let mime, !mime.isEmpty { obj["mime"] = mime }
        let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        var plain = Data()
        plain.append(u32LE(json.count))
        plain.append(json)
        plain.append(data)
        return sealOne(plain, key: key, aad: Data(itemId.utf8))
    }

    static func sealVoice(audio: Data, vtt: String, meta: CaptureMeta, itemId: String, key: Data) -> Data {
        let idBytes = Array(itemId.utf8)
        let metaObj: [String: Any] = [
            "schema_version": 1,
            "captured_at": Int(meta.capturedAt.timeIntervalSince1970),
            "utc_offset_seconds": meta.utcOffsetSeconds,
        ]
        let metaJSON = (try? JSONSerialization.data(withJSONObject: metaObj)) ?? Data()
        let parts = [
            sealVoicePart(role: roleAudio, content: audio, key: key, idBytes: idBytes),
            sealVoicePart(role: roleVTT, content: Data(vtt.utf8), key: key, idBytes: idBytes),
            sealVoicePart(role: roleMeta, content: metaJSON, key: key, idBytes: idBytes),
        ]
        var container = Data()
        for blob in parts {
            container.append(u32LE(blob.count))
            container.append(blob)
        }
        return container
    }

    private static func sealOne(_ plaintext: Data, key: Data, aad: Data) -> Data {
        // A 32-byte key + 12-byte default nonce always seals; `.combined` is non-nil.
        let box = try! AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        return box.combined!
    }

    private static func sealVoicePart(role: UInt8, content: Data, key: Data, idBytes: [UInt8]) -> Data {
        var msg = Data([role])
        msg.append(content)
        var aad = Data(idBytes)
        aad.append(role)
        return sealOne(msg, key: key, aad: aad)
    }

    private static func u32LE(_ n: Int) -> Data {
        var v = UInt32(n).littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }

    // MARK: - Decrypt (consumer side)

    /// Decrypt + parse a fetched blob into a vault-ready payload.
    static func decrypt(blob: Data, itemId: String, type: RelayItemType, key: Data) throws -> RelayPayload {
        let symKey = SymmetricKey(data: key)
        let aad = Data(itemId.utf8)   // itemId is already lowercase (relay enforces it)

        switch type {
        case .text, .url:
            let plaintext = try open(blob, key: symKey, aad: aad)
            let meta = try parseMeta(plaintext)
            let inner = try parseJSON(plaintext)
            let text = (inner["text"] as? String) ?? ""
            let sourceApp = inner["source_app"] as? String
            return .markdown(text: text, sourceApp: sourceApp, meta: meta)

        case .image, .file:
            let plaintext = try open(blob, key: symKey, aad: aad)
            let (jsonData, bytes) = try splitJSONAndBytes(plaintext)
            let meta = try parseMeta(jsonData)
            let inner = try parseJSON(jsonData)
            let filename = inner["filename"] as? String
            let mime = inner["mime"] as? String
            return .binary(type: type, data: bytes, filename: filename, mime: mime, meta: meta)

        case .voice:
            return try decryptVoice(container: blob, itemId: itemId, key: symKey)
        }
    }

    // MARK: - Voice

    private static func decryptVoice(container: Data, itemId: String, key: SymmetricKey) throws -> RelayPayload {
        let parts = try parseFrame(container, expecting: 3)
        let idBytes = Array(itemId.utf8)

        let audioPlain = try openVoicePart(parts[0], key: key, idBytes: idBytes, role: roleAudio)
        let vttPlain   = try openVoicePart(parts[1], key: key, idBytes: idBytes, role: roleVTT)
        let metaPlain  = try openVoicePart(parts[2], key: key, idBytes: idBytes, role: roleMeta)

        guard let vtt = String(data: vttPlain, encoding: .utf8) else {
            throw EnvelopeError.malformed("voice VTT is not UTF-8")
        }
        let meta = try parseMeta(metaPlain)
        return .voice(audio: audioPlain, vtt: vtt, meta: meta)
    }

    /// Open one voice part: AAD = id ‖ role, then strip the leading role byte
    /// (which must equal the expected role — guards against cross-part swaps).
    private static func openVoicePart(_ blob: Data, key: SymmetricKey, idBytes: [UInt8], role: UInt8) throws -> Data {
        var aad = idBytes
        aad.append(role)
        let withRole = try open(blob, key: key, aad: Data(aad))
        guard let first = withRole.first, first == role else {
            throw EnvelopeError.malformed("voice part role byte mismatch")
        }
        return withRole.dropFirst().withUnsafeBytes { Data($0) }
    }

    // MARK: - GCM open

    private static func open(_ blob: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: blob)
        } catch {
            // Wrong length / not a valid combined box.
            throw EnvelopeError.malformed("not a valid sealed box (\(blob.count) bytes)")
        }
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw EnvelopeError.authenticationFailure
        }
    }

    // MARK: - Framing

    /// Parse `[u32_LE len][bytes]` repeated `expecting` times, consuming the whole buffer.
    private static func parseFrame(_ data: Data, expecting: Int) throws -> [Data] {
        let bytes = [UInt8](data)
        var parts: [Data] = []
        var i = 0
        for _ in 0..<expecting {
            guard i + 4 <= bytes.count else { throw EnvelopeError.malformed("truncated length prefix") }
            let len = readU32LE(bytes, at: i)
            i += 4
            let end = i + Int(len)
            guard end <= bytes.count else { throw EnvelopeError.malformed("part length exceeds buffer") }
            parts.append(Data(bytes[i..<end]))
            i = end
        }
        guard i == bytes.count else { throw EnvelopeError.malformed("trailing bytes after frame") }
        return parts
    }

    /// `[u32_LE json_len][json][bytes]` — used for image/file plaintext.
    private static func splitJSONAndBytes(_ data: Data) throws -> (json: Data, bytes: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw EnvelopeError.malformed("missing json length prefix") }
        let jsonLen = Int(readU32LE(bytes, at: 0))
        let jsonStart = 4
        let jsonEnd = jsonStart + jsonLen
        guard jsonEnd <= bytes.count else { throw EnvelopeError.malformed("json length exceeds buffer") }
        return (Data(bytes[jsonStart..<jsonEnd]), Data(bytes[jsonEnd...]))
    }

    private static func readU32LE(_ bytes: [UInt8], at i: Int) -> UInt32 {
        UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
    }

    // MARK: - JSON

    private static func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnvelopeError.malformed("inner payload is not a JSON object")
        }
        return obj
    }

    private static func parseMeta(_ data: Data) throws -> CaptureMeta {
        let obj = try parseJSON(data)
        // captured_at is epoch seconds (int or float). Missing → treat as malformed
        // rather than silently stamping drain time (capture-time fidelity is the point).
        guard let capturedAt = (obj["captured_at"] as? NSNumber)?.doubleValue else {
            throw EnvelopeError.malformed("missing captured_at")
        }
        let offset = (obj["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0
        return CaptureMeta(capturedAt: Date(timeIntervalSince1970: capturedAt),
                           utcOffsetSeconds: offset)
    }
}
