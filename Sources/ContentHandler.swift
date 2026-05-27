import AppKit
import Foundation

struct CapturePayload {
    var text: String
    var pastedImageData: Data?
    var pastedFileURL: URL?
    var sourceApp: String?
}

enum CaptureResult {
    case saved
    case fileTooLarge
    case empty
    case destinationMissing
    case error
}

enum ContentHandler {
    private static let maxFileSize: Int64 = 100 * 1024 * 1024
    private static let fm = FileManager.default

    /// Save the capture. Returns the result so the caller can react (e.g. show
    /// the destination picker if the folder is missing/unwritable).
    @discardableResult
    static func save(_ payload: CapturePayload,
                     to destination: URL,
                     prefs: Preferences = .shared) -> CaptureResult
    {
        let trimmed = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let hasImage = payload.pastedImageData != nil
        let hasFile = payload.pastedFileURL != nil

        if !hasText && !hasImage && !hasFile {
            return .empty
        }

        guard ensureDirectory(destination) else { return .destinationMissing }

        let now = Date()
        let timestamp = filenameTimestamp(now)

        // Bare file drop (no text)
        if !hasText && hasFile, let src = payload.pastedFileURL, !hasImage {
            return copyFile(from: src, destination: destination, prefs: prefs)
        }

        // Bare image drop (no text)
        if !hasText && hasImage, let imageData = payload.pastedImageData {
            return writeBareImage(imageData,
                                  destination: destination,
                                  timestamp: timestamp,
                                  prefs: prefs)
        }

        // Markdown captures
        return writeMarkdown(payload,
                             trimmedText: trimmed,
                             destination: destination,
                             timestamp: timestamp,
                             when: now,
                             prefs: prefs)
    }

    // MARK: - Markdown captures -----------------------------------------------

    private static func writeMarkdown(_ payload: CapturePayload,
                                      trimmedText: String,
                                      destination: URL,
                                      timestamp: String,
                                      when: Date,
                                      prefs: Preferences) -> CaptureResult
    {
        var body = payload.text

        let urlMatch = URLDetector.firstURL(in: body)
        let pureURL  = URLDetector.isPureURL(payload.text)
        let type: FrontMatterType = (urlMatch != nil) ? .url : .text

        if pureURL, let m = urlMatch {
            body = "[\(m.raw)](\(m.raw))"
        } else if urlMatch != nil {
            body = URLDetector.wrapURLsAsMarkdownLinks(in: body)
        }

        // Attachments (image and/or file)
        var attachmentLines: [String] = []
        let attachmentsDir = destination.appendingPathComponent("attachments", isDirectory: true)

        if let imageData = payload.pastedImageData {
            if let line = saveImageAttachment(imageData,
                                              destination: destination,
                                              attachmentsDir: attachmentsDir,
                                              timestamp: timestamp,
                                              prefs: prefs)
            {
                attachmentLines.append(line)
            } else {
                attachmentLines.append("> _stash: failed to write image attachment_")
            }
        }

        if let fileURL = payload.pastedFileURL {
            switch copyFileForAttachment(from: fileURL,
                                         attachmentsDir: attachmentsDir,
                                         prefs: prefs)
            {
            case .ok(let name):
                attachmentLines.append("[\(name)](attachments/\(name))")
            case .tooLarge:
                attachmentLines.append("> _stash: file exceeded 100MB limit, not attached_")
            case .error:
                attachmentLines.append("> _stash: failed to attach file_")
            }
        }

        let tags = HashtagExtractor.tags(from: body)
        let fm = FrontMatter.build(type: type,
                                   created: when,
                                   sourceApp: payload.sourceApp,
                                   tags: tags)

        var fullBody = body
        if !attachmentLines.isEmpty {
            if !fullBody.hasSuffix("\n") { fullBody += "\n" }
            fullBody += "\n" + attachmentLines.joined(separator: "\n")
        }

        let document = fm + "\n\n" + fullBody + (fullBody.hasSuffix("\n") ? "" : "\n")
        let filename = markdownFilename(timestamp: timestamp, body: fullBody)
        let url = destination.appendingPathComponent(filename)

        do {
            try document.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return .error
        }

        // Fire-and-forget title fetch for URL captures
        if type == .url, let m = urlMatch {
            URLTitleFetcher.fetchTitle(for: m.url) { title in
                guard let title = title else { return }
                updateTitle(in: url, urlString: m.raw, title: title)
            }
        }

        return .saved
    }

    private static func updateTitle(in fileURL: URL, urlString: String, title: String) {
        guard let data = try? Data(contentsOf: fileURL),
              var contents = String(data: data, encoding: .utf8)
        else { return }
        let safeTitle = title
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
        let old = "[\(urlString)](\(urlString))"
        let new = "[\(safeTitle)](\(urlString))"
        guard contents.contains(old) else { return }
        contents = contents.replacingOccurrences(of: old, with: new)
        try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Image attachment ------------------------------------------------

    private static func writeBareImage(_ data: Data,
                                       destination: URL,
                                       timestamp: String,
                                       prefs: Preferences) -> CaptureResult
    {
        let (out, fmt) = prefs.imageNormalization
            ? ImageNormalizer.normalizeToPNGIfNeeded(data)
            : (data, ImageNormalizer.detectFormat(data))
        let ext = fmt.fileExtension
        let hash = ContentHash.short(out)
        let name = "\(timestamp)-\(hash).\(ext)"
        let url = destination.appendingPathComponent(name)
        do {
            try out.write(to: url, options: .atomic)
            return .saved
        } catch {
            return .error
        }
    }

    private static func saveImageAttachment(_ data: Data,
                                            destination: URL,
                                            attachmentsDir: URL,
                                            timestamp: String,
                                            prefs: Preferences) -> String?
    {
        guard ensureDirectory(attachmentsDir) else { return nil }
        let (out, fmt) = prefs.imageNormalization
            ? ImageNormalizer.normalizeToPNGIfNeeded(data)
            : (data, ImageNormalizer.detectFormat(data))
        let ext = fmt.fileExtension
        let hash = ContentHash.short(out)
        let name = "\(timestamp)-\(hash).\(ext)"
        let url = attachmentsDir.appendingPathComponent(name)
        do {
            try out.write(to: url, options: .atomic)
            return "![](attachments/\(name))"
        } catch {
            return nil
        }
    }

    // MARK: - File copies -----------------------------------------------------

    private enum AttachmentCopy {
        case ok(name: String)
        case tooLarge
        case error
    }

    private static func copyFile(from src: URL,
                                 destination: URL,
                                 prefs: Preferences) -> CaptureResult
    {
        if fileSize(src) ?? 0 > maxFileSize { return .fileTooLarge }
        let original = src.lastPathComponent
        let name = prefs.imageNormalization ? ImageNormalizer.normalizeFilename(original) : original
        let dst = uniqueDestination(in: destination, preferredName: name)
        do {
            try fm.copyItem(at: src, to: dst)
            return .saved
        } catch {
            return .error
        }
    }

    private static func copyFileForAttachment(from src: URL,
                                              attachmentsDir: URL,
                                              prefs: Preferences) -> AttachmentCopy
    {
        if fileSize(src) ?? 0 > maxFileSize { return .tooLarge }
        guard ensureDirectory(attachmentsDir) else { return .error }
        let original = src.lastPathComponent
        let name = prefs.imageNormalization ? ImageNormalizer.normalizeFilename(original) : original
        let dst = uniqueDestination(in: attachmentsDir, preferredName: name)
        do {
            try fm.copyItem(at: src, to: dst)
            return .ok(name: dst.lastPathComponent)
        } catch {
            return .error
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    private static func uniqueDestination(in dir: URL, preferredName: String) -> URL {
        let url = dir.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    // MARK: - Filenames -------------------------------------------------------

    private static func markdownFilename(timestamp: String, body: String) -> String {
        let hash = ContentHash.short(body)
        return "\(timestamp)-\(hash).md"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    static func filenameTimestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    // MARK: - Filesystem ------------------------------------------------------

    @discardableResult
    static func ensureDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                return fm.isWritableFile(atPath: url.path)
            }
            return false
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
