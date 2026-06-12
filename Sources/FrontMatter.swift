import Foundation

enum FrontMatterType: String { case text, url }

enum FrontMatter {
    /// Build YAML front matter.
    ///
    /// `utcOffsetSeconds` controls the timezone of the `created` timestamp: nil
    /// (the local-capture path) uses the Mac's current zone; a value (the relay
    /// consumer path) reconstructs the *original* capture offset so a laptop
    /// draining a stale backlog records capture-time wall-clock, not drain-time.
    static func build(type: FrontMatterType,
                      created: Date = Date(),
                      utcOffsetSeconds: Int? = nil,
                      sourceApp: String?,
                      tags: [String]) -> String
    {
        var lines: [String] = ["---"]
        lines.append("created: \(iso8601(created, utcOffsetSeconds: utcOffsetSeconds))")
        lines.append("type: \(type.rawValue)")
        if let s = sourceApp, !s.isEmpty {
            lines.append("source_app: \(yamlScalar(s))")
        }
        if !tags.isEmpty {
            let inner = tags.map { yamlScalar($0) }.joined(separator: ", ")
            lines.append("tags: [\(inner)]")
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    static func iso8601(_ date: Date, utcOffsetSeconds: Int? = nil) -> String {
        guard let offset = utcOffsetSeconds, let tz = TimeZone(secondsFromGMT: offset) else {
            return isoFormatter.string(from: date)
        }
        // ISO8601DateFormatter isn't thread-safe to mutate the shared instance,
        // so use a fresh one when a specific offset is requested.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = tz
        return f.string(from: date)
    }

    /// YAML scalar — quote if it contains any character that needs escaping
    /// in flow context, otherwise emit bare.
    private static func yamlScalar(_ s: String) -> String {
        let special: Set<Character> = [":", "#", ",", "[", "]", "{", "}", "&",
                                       "*", "!", "|", ">", "'", "\"", "%",
                                       "@", "`"]
        let needsQuote = s.isEmpty
            || s.first == " " || s.last == " "
            || s.contains(where: { $0.isNewline || special.contains($0) })
        if !needsQuote { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
