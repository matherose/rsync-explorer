import Foundation
import NIOCore
import NIOSSH
import Crypto

/// Captures whether the most recent connection attempt failed specifically because
/// the host key didn't match the pinned one (so the UI can show a clear message).
final class HostKeyOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _mismatch = false
    var mismatch: Bool { lock.lock(); defer { lock.unlock() }; return _mismatch }
    func flagMismatch() { lock.lock(); _mismatch = true; lock.unlock() }
}

struct HostKeyMismatchError: Error {}

/// Trust-on-first-use host-key validation: the first key seen for a host is pinned
/// and trusted; later connections must present the same key, otherwise the
/// connection is refused (possible MITM, or the NAS host key genuinely changed).
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let store: HostKeyStore
    private let outcome: HostKeyOutcome

    init(host: String, port: Int, store: HostKeyStore, outcome: HostKeyOutcome) {
        self.host = host
        self.port = port
        self.store = store
        self.outcome = outcome
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = Self.fingerprint(of: hostKey)
        if let pinned = store.fingerprint(host: host, port: port) {
            if pinned == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                outcome.flagMismatch()
                validationCompletePromise.fail(HostKeyMismatchError())
            }
        } else {
            store.save(fingerprint: fingerprint, host: host, port: port)   // trust on first use
            validationCompletePromise.succeed(())
        }
    }

    /// SHA-256 over the SSH wire encoding of the public key.
    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = key.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
