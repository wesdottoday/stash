import Foundation

enum HashtagExtractor {
    /// Extract `#tags` from body. Slashed tags (`#nvidia/dgx`) are one tag.
    /// Excludes tags inside fenced code blocks and URLs.
    static func tags(from body: String) -> [String] {
        // Strip fenced code blocks ```...```
        var stripped = body.replacingOccurrences(
            of: #"```[\s\S]*?```"#,
            with: "",
            options: .regularExpression
        )
        // Strip inline code `...`
        stripped = stripped.replacingOccurrences(
            of: "`[^`\n]+`",
            with: "",
            options: .regularExpression
        )
        // Strip URLs
        stripped = stripped.replacingOccurrences(
            of: #"https?://[^\s)]+"#,
            with: "",
            options: .regularExpression
        )

        let pattern = #"(?:^|[^\w/])#([A-Za-z][A-Za-z0-9_/\-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = stripped as NSString
        let matches = regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var out: [String] = []
        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { continue }
            var tag = ns.substring(with: r)
            // Trim trailing slashes/hyphens so "#foo/" becomes "foo"
            while let last = tag.last, last == "/" || last == "-" {
                tag.removeLast()
            }
            guard !tag.isEmpty else { continue }
            if !seen.contains(tag) {
                seen.insert(tag)
                out.append(tag)
            }
        }
        return out
    }
}
