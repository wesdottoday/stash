import Foundation

enum URLDetector {
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    struct Match {
        let url: URL
        let range: NSRange
        let raw: String
    }

    static func matches(in text: String) -> [Match] {
        guard let d = detector else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let results = d.matches(in: text, range: range)
        var out: [Match] = []
        for r in results {
            guard let url = r.url else { continue }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            guard let host = url.host, !host.isEmpty else { continue }
            out.append(Match(url: url, range: r.range, raw: ns.substring(with: r.range)))
        }
        return out
    }

    static func firstURL(in text: String) -> Match? { matches(in: text).first }

    /// True iff `text` (trimmed) is exactly a single URL — nothing else.
    static func isPureURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let m = firstURL(in: trimmed),
              m.range.location == 0,
              m.range.length == (trimmed as NSString).length
        else { return false }
        return true
    }

    /// Wrap raw URLs in the body with `[url](url)` markdown links — but skip
    /// URLs that are already inside an existing markdown link `](URL)`.
    static func wrapURLsAsMarkdownLinks(in body: String) -> String {
        let ms = matches(in: body)
        guard !ms.isEmpty else { return body }
        let ns = body as NSString
        var out = ""
        var cursor = 0
        for m in ms {
            // Skip URL if it's already inside an existing `](url)` construct.
            let start = m.range.location
            if start >= 2 {
                let prefix = ns.substring(with: NSRange(location: start - 2, length: 2))
                if prefix == "](" { continue }
            }
            out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
            out += "[\(m.raw)](\(m.raw))"
            cursor = start + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}
