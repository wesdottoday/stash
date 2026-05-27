import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String {
    case png, jpg, tiff, gif, bmp, webp, heic, unknown

    var fileExtension: String {
        switch self {
        case .png:   return "png"
        case .jpg:   return "jpg"
        case .tiff:  return "tiff"
        case .gif:   return "gif"
        case .bmp:   return "bmp"
        case .webp:  return "webp"
        case .heic:  return "heic"
        case .unknown: return "bin"
        }
    }
}

enum ImageNormalizer {
    /// Inspect the leading bytes of `data` to identify the raster format.
    static func detectFormat(_ data: Data) -> ImageFormat {
        guard data.count >= 12 else { return .unknown }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpg }
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00) ||
           (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return .tiff }
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return .gif }
        if b[0] == 0x42, b[1] == 0x4D { return .bmp }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return .webp }
        // HEIC: ftyp box at offset 4 — best-effort
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            return .heic
        }
        return .unknown
    }

    /// Convert any non-PNG/JPEG bytes to PNG using CoreGraphics / ImageIO.
    /// Returns the original data unchanged if already PNG/JPEG (or if conversion fails).
    static func normalizeToPNGIfNeeded(_ data: Data) -> (data: Data, format: ImageFormat) {
        let fmt = detectFormat(data)
        if fmt == .png || fmt == .jpg { return (data, fmt) }
        if let png = convertToPNG(data) { return (png, .png) }
        return (data, fmt)
    }

    static func convertToPNG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }

    /// Apply filename normalization: spaces -> hyphens, strip control chars.
    static func normalizeFilename(_ name: String) -> String {
        var out = ""
        out.reserveCapacity(name.count)
        for ch in name {
            if ch.isWhitespace { out.append("-") }
            else if ch.isASCII && (ch.asciiValue ?? 0) < 0x20 { continue }
            else { out.append(ch) }
        }
        return out
    }
}
