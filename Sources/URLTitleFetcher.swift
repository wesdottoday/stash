import Foundation

enum URLTitleFetcher {
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 3
        cfg.timeoutIntervalForResource = 5
        cfg.httpAdditionalHeaders = [
            "User-Agent": "stash/1.0 (+https://github.com/wesdottoday/stash)"
        ]
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private static let maxBytes = 64 * 1024

    /// Fetch the page title for `url`. Silent on any failure.
    /// Completion is delivered on a background queue.
    static func fetchTitle(for url: URL, completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        let task = session.dataTask(with: req) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data = data, !data.isEmpty
            else { completion(nil); return }
            let capped = data.count > maxBytes ? data.prefix(maxBytes) : data.prefix(data.count)
            let text = decodeHTML(Data(capped), httpResponse: http)
            completion(parseTitle(from: text))
        }
        task.resume()
    }

    private static func decodeHTML(_ data: Data, httpResponse: HTTPURLResponse) -> String {
        // Try Content-Type charset
        if let ct = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           let charset = charset(from: ct),
           let s = String(data: data, encoding: charset) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func charset(from contentType: String) -> String.Encoding? {
        let parts = contentType.lowercased().split(separator: ";")
        for p in parts {
            let trimmed = p.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("charset=") {
                let cs = trimmed.dropFirst("charset=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                switch cs {
                case "utf-8", "utf8":         return .utf8
                case "iso-8859-1", "latin1":  return .isoLatin1
                case "windows-1252", "cp1252":return .windowsCP1252
                case "ascii", "us-ascii":     return .ascii
                default: return nil
                }
            }
        }
        return nil
    }

    private static func parseTitle(from html: String) -> String? {
        let pattern = #"<title[^>]*>([\s\S]*?)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              match.range(at: 1).location != NSNotFound
        else { return nil }
        var title = ns.substring(with: match.range(at: 1))
        title = decodeEntities(title)
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let pairs: [(String, String)] = [
            ("&amp;",  "&"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;",  "'"),
            ("&nbsp;", " "),
        ]
        for (k, v) in pairs { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities
        let numeric = try? NSRegularExpression(pattern: #"&#(\d+);"#)
        if let regex = numeric {
            let ns = out as NSString
            var result = ""
            var cursor = 0
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let r = m.range(at: 0)
                let numStr = ns.substring(with: m.range(at: 1))
                result += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                if let code = Int(numStr), let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                }
                cursor = r.location + r.length
            }
            result += ns.substring(from: cursor)
            out = result
        }
        return out
    }
}
