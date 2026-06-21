import Foundation
import CryptoKit

enum CacheKey {
    static func make(path: String, size: Int64, mtime: TimeInterval) -> String {
        let seed = "\(path)|\(size)|\(Int(mtime))"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
