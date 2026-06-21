import XCTest
import CryptoKit
@testable import RsyncExplorer

final class OpenSSHKeyTests: XCTestCase {
    // Throwaway fixture generated with: ssh-keygen -t ed25519 -N "" -f /tmp/rsx_test_key
    static let fixturePEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACDXPNDSqjUv77grcb7taCGouzX2irn+lcI0wYibQmb1qwAAAJBmB+Y6Zgfm
    OgAAAAtzc2gtZWQyNTUxOQAAACDXPNDSqjUv77grcb7taCGouzX2irn+lcI0wYibQmb1qw
    AAAEALc1A/ykAnaqITXR8Gaq+/dEsoWou6M900caMfaDmc8dc80NKqNS/vuCtxvu1oIai7
    NfaKuf6VwjTBiJtCZvWrAAAACHJzeC10ZXN0AQIDBAU=
    -----END OPENSSH PRIVATE KEY-----
    """
    static let expectedPubB64 = "AAAAC3NzaC1lZDI1NTE5AAAAINc80NKqNS/vuCtxvu1oIai7NfaKuf6VwjTBiJtCZvWr"

    func test_parses_ed25519_and_matches_public_key() throws {
        let key = try OpenSSHKey.ed25519PrivateKey(fromPEM: Self.fixturePEM)
        let raw = key.publicKey.rawRepresentation
        func sshString(_ d: Data) -> Data {
            var out = Data()
            var len = UInt32(d.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(d)
            return out
        }
        var blob = Data()
        blob.append(sshString(Data("ssh-ed25519".utf8)))
        blob.append(sshString(raw))
        XCTAssertEqual(blob.base64EncodedString(), Self.expectedPubB64)
    }

    func test_rejects_garbage_key() {
        let enc = "-----BEGIN OPENSSH PRIVATE KEY-----\nGARBAGE\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertThrowsError(try OpenSSHKey.ed25519PrivateKey(fromPEM: enc))
    }
}
