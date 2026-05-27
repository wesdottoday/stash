import Foundation

enum FrontMatterType: String { case text, url }

enum FrontMatter {
    static func build(type: FrontMatterType,
                      created: Date = Date(),
                      sourceApp: String?,
                      tags: [String]) -> String
    {
        var lines: [String] = ["---"]
        lines.append("created: \(iso8601(created))")
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

    static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
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
