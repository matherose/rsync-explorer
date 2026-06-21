import Foundation
import CryptoKit

enum OpenSSHKeyError: Error { case badFormat, encryptedUnsupported, notEd25519 }

enum OpenSSHKey {
    /// Parses an unencrypted OpenSSH ed25519 private key PEM into a Curve25519 signing key.
    /// Encrypted keys (cipher != "none") are unsupported in v1.
    static func ed25519PrivateKey(fromPEM pem: String) throws -> Curve25519.Signing.PrivateKey {
        let b64 = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let blob = Data(base64Encoded: b64) else { throw OpenSSHKeyError.badFormat }

        var r = ByteReader(blob)
        guard r.readBytes(15) == Data("openssh-key-v1\0".utf8) else { throw OpenSSHKeyError.badFormat }
        let cipher = try r.readSSHString()
        _ = try r.readSSHString()                       // kdfname
        _ = try r.readSSHString()                       // kdfoptions
        guard String(data: cipher, encoding: .utf8) == "none" else {
            throw OpenSSHKeyError.encryptedUnsupported
        }
        guard r.readUInt32() == 1 else { throw OpenSSHKeyError.badFormat }   // key count
        _ = try r.readSSHString()                       // public key blob
        let privSection = try r.readSSHString()          // private section (unencrypted)

        var p = ByteReader(privSection)
        _ = p.readUInt32(); _ = p.readUInt32()           // two checkints (ignored)
        let keyType = try p.readSSHString()
        guard String(data: keyType, encoding: .utf8) == "ssh-ed25519" else {
            throw OpenSSHKeyError.notEd25519
        }
        _ = try p.readSSHString()                        // public key (32 bytes)
        let priv = try p.readSSHString()                 // 64 bytes: seed(32) + pub(32)
        guard priv.count == 64 else { throw OpenSSHKeyError.badFormat }
        let seed = Data(priv.prefix(32))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}

private struct ByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = Data(data); self.offset = 0 }
    mutating func readBytes(_ n: Int) -> Data {
        let end = min(offset + n, data.count)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }
    mutating func readUInt32() -> UInt32 {
        readBytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func readSSHString() throws -> Data {
        let len = Int(readUInt32())
        guard offset + len <= data.count else { throw OpenSSHKeyError.badFormat }
        return readBytes(len)
    }
}
