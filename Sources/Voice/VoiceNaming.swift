import Foundation

/// File-naming rules for voice captures. Each recording produces two files that
/// share a timestamp base so they sort chronologically and pair cleanly:
///
///     2026-06-12_101634_audio.m4a
///     2026-06-12_101634_transcription.vtt
///
/// The base is local 24-hour time, `yyyy-MM-dd_HHmmss`. On the rare same-second
/// collision a `-2`, `-3`, … suffix is appended to the base.
///
/// Ported verbatim from stash-ios `Naming` so a macOS voice capture is
/// byte-symmetric with an iOS one. This is intentionally distinct from
/// `ContentHandler`'s markdown naming (`YYYY-MM-DD-HHMMSS-<hash>.md`): voice
/// captures are the two-file ALAC+VTT pair, not markdown.
enum VoiceNaming {
    static let audioSuffix = "_audio"
    static let transcriptSuffix = "_transcription"
    static let transcriptExtension = "vtt"

    /// Audio container extensions a voice capture may produce (ALAC m4a is the
    /// normal output; wav/caf are lossless fallbacks). Used to recognize our
    /// own files in a shared destination folder.
    static let audioExtensions: Set<String> = ["m4a", "wav", "caf"]

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    static func timestamp(for date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    static func audioFilename(base: String, ext: String) -> String {
        "\(base)\(audioSuffix).\(ext)"
    }

    static func transcriptFilename(base: String) -> String {
        "\(base)\(transcriptSuffix).\(transcriptExtension)"
    }

    /// Parses the capture date from a base. The optional `-N` collision suffix
    /// is ignored for date purposes.
    static func date(fromBase base: String) -> Date? {
        let stamp = base.split(separator: "-").count > 3
            ? String(base.prefix(17))   // "yyyy-MM-dd_HHmmss" is 17 chars
            : base
        return timestampFormatter.date(from: stamp)
    }

    /// Produces a collision-free base for `date`. `exists` is asked whether a
    /// given base is already taken.
    static func uniqueBase(for date: Date, exists: (String) -> Bool) -> String {
        let stamp = timestamp(for: date)
        if !exists(stamp) { return stamp }
        var n = 2
        while exists("\(stamp)-\(n)") { n += 1 }
        return "\(stamp)-\(n)"
    }
}
