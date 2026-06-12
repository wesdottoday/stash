import Foundation

/// A finalized transcript segment with its audio time range, in seconds.
///
/// Ported verbatim from stash-ios so the emitted WebVTT is byte-identical to an
/// iOS capture (the macOS hub and iOS produce the same two-file vault output).
struct TranscriptCue: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Builds a WebVTT document (with timed cues) from transcript segments.
///
/// Example output:
///
///     WEBVTT
///
///     00:00:00.000 --> 00:00:03.480
///     This is the first thing I said.
///
///     00:00:03.480 --> 00:00:07.900
///     And this is the second.
enum VTTWriter {
    static func document(from cues: [TranscriptCue]) -> String {
        var out = "WEBVTT\n\n"
        for (index, cue) in cues.enumerated() {
            let start = timestamp(cue.start)
            // Guard against zero/negative-length cues so players don't choke.
            let end = timestamp(max(cue.end, cue.start + 0.001))
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            out += "\(index + 1)\n"
            out += "\(start) --> \(end)\n"
            out += "\(text)\n\n"
        }
        return out
    }

    /// Formats seconds as `HH:MM:SS.mmm` per the WebVTT spec.
    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - total.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
    }
}
