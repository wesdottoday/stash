import Foundation
import CryptoKit

enum ContentHash {
    static func short(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var out = ""
        out.reserveCapacity(6)
        for (i, b) in digest.enumerated() {
            if i >= 3 { break }
            out += String(format: "%02x", b)
        }
        return out
    }

    static func short(_ string: String) -> String {
        short(Data(string.utf8))
    }
}
