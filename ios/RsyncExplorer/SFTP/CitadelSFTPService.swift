import Foundation
import Citadel
import Crypto
import NIOCore

enum SFTPError: Error { case notConnected, missingSize }

/// Surfaced to the UI so a changed/untrusted NAS host key gets a clear message
/// instead of an opaque handshake failure.
enum SFTPConnectError: Error, Equatable {
    case hostKeyMismatch
    case timedOut

    var userMessage: String {
        switch self {
        case .hostKeyMismatch:
            return "The NAS host key has changed since you last connected.\n\n" +
                   "If you reinstalled or reset the NAS, tap “Forget saved connection” and reconnect to trust the new key. " +
                   "Otherwise this could indicate a security problem on your network."
        case .timedOut:
            return "Couldn’t reach the NAS — the connection timed out.\n\n" +
                   "Check the address and port, that your device is on the same network, and that the NAS is powered on."
        }
    }
}

/// Real SFTP service backed by Citadel (SwiftNIO SSH). Read-only.
///
/// Citadel multiplexes every request over a single SSH channel. Swift `actor`
/// isolation alone does NOT make that safe: as soon as a method suspends on an
/// `await`, the actor admits another call, and two operations then interleave
/// their reads/writes on the one channel — Citadel desyncs and all later ops
/// fail (the UI shows empty folders). `lock` serializes whole operations end to
/// end so only one ever touches the channel; `withReconnect` re-opens the
/// channel once and retries when a dropped connection surfaces as an error.
actor CitadelSFTPService: SFTPService {
    enum SFTPAuth {
        case password(String)
        case ed25519(Curve25519.Signing.PrivateKey)   // Crypto (swift-crypto) key
    }

    private let config: ServerConfig
    private let auth: SFTPAuth
    private var client: SSHClient?
    private var sftp: SFTPClient?
    /// Serializes access to the single SFTP channel (see type doc).
    private let lock = AsyncSemaphore(value: 1)
    private let hostKeyStore = HostKeyStore()

    init(config: ServerConfig, auth: SFTPAuth) {
        self.config = config
        self.auth = auth
    }

    /// Bridges a stored secret (password text or unencrypted ed25519 PEM) to an auth value.
    static func makeAuth(for config: ServerConfig, secret: String) throws -> SFTPAuth {
        switch config.authMethod {
        case .password:
            return .password(secret)
        case .ed25519Key:
            let seed = try OpenSSHKey.ed25519Seed(fromPEM: secret)
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
        }
    }

    func connect() async throws {
        await lock.acquire()
        defer { Task { await lock.release() } }
        try await connectClient()
    }

    func disconnect() async {
        await lock.acquire()
        defer { Task { await lock.release() } }
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }

    func listDirectory(_ path: String) async throws -> [RemoteEntry] {
        try await withReconnect { sftp in
            let names = try await sftp.listDirectory(atPath: path)
            return names.flatMap { $0.components }.compactMap { Self.entry(from: $0, parent: path) }
        }
    }

    func resolveLatestSnapshot(under path: String) async throws -> String {
        // Delegates to listDirectory, which already takes the lock — do NOT lock
        // here too or we'd deadlock on the non-recursive semaphore.
        try await defaultResolveLatestSnapshot(under: path)
    }

    func download(_ path: String, to localURL: URL,
                  progress: @escaping (Double) -> Void) async throws {
        try await withReconnect { sftp in
            let file = try await sftp.openFile(filePath: path, flags: .read)
            do {
                let attrs = try await file.readAttributes()
                guard let size = attrs.size else { throw SFTPError.missingSize }
                FileManager.default.createFile(atPath: localURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: localURL)
                defer { try? handle.close() }
                var offset: UInt64 = 0
                let chunk: UInt32 = 256 * 1024
                while offset < size {
                    let want = UInt32(min(UInt64(chunk), size - offset))
                    let buf = try await file.read(from: offset, length: want)
                    let bytes = Data(buf.readableBytesView)
                    if bytes.isEmpty { break }
                    try handle.write(contentsOf: bytes)
                    offset += UInt64(bytes.count)
                    progress(min(1.0, Double(offset) / Double(size)))
                }
                try? await file.close()
                progress(1.0)
            } catch {
                try? await file.close()
                try? FileManager.default.removeItem(at: localURL)
                throw error
            }
        }
    }

    func read(at path: String, offset: UInt64, length: UInt32) async throws -> Data {
        try await withReconnect { sftp in
            let file = try await sftp.openFile(filePath: path, flags: .read)
            do {
                let buf = try await file.read(from: offset, length: length)
                let data = Data(buf.readableBytesView)
                try? await file.close()   // close INSIDE the lock — a detached close races the next op on the shared channel
                return data
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    /// Reads up to `maxBytes` from the start of a file in a single locked operation
    /// (one open, chunked reads, one close) — for header/thumbnail extraction without
    /// the per-chunk reopen + lock churn that starves directory listings.
    func readHeader(_ path: String, maxBytes: Int) async throws -> Data {
        try await withReconnect { sftp in
            let file = try await sftp.openFile(filePath: path, flags: .read)
            do {
                var data = Data()
                var offset: UInt64 = 0
                let chunk = 64 * 1024
                while data.count < maxBytes {
                    let want = UInt32(min(chunk, maxBytes - data.count))
                    let bytes = Data(try await file.read(from: offset, length: want).readableBytesView)
                    if bytes.isEmpty { break }
                    data.append(bytes)
                    offset += UInt64(bytes.count)
                    if bytes.count < Int(want) { break }   // short read → EOF or server cap
                }
                try? await file.close()
                return data
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    /// Runs `command` on the server via a dedicated SSH exec channel (separate from
    /// the multiplexed SFTP channel) and returns its stdout. The lock is held only
    /// briefly to fetch (or reconnect) the client — the command itself runs OFF the
    /// lock, so a long one (e.g. `du` on a big folder) doesn't block SFTP listings or
    /// thumbnail reads on the shared channel. stderr is dropped (mergeStreams: false)
    /// and the response is capped so a runaway command can't exhaust memory.
    func runCommand(_ command: String) async throws -> String {
        let client = try await lockedClient(reconnect: false)
        do {
            return try await Self.exec(command, on: client)
        } catch {
            guard Self.isConnectionError(error) else { throw error }
            return try await Self.exec(command, on: lockedClient(reconnect: true))
        }
    }

    /// Briefly takes the lock to return the live SSH client (optionally reconnecting
    /// first), then releases it so the caller can use the client off-lock.
    private func lockedClient(reconnect: Bool) async throws -> SSHClient {
        await lock.acquire()
        defer { Task { await lock.release() } }
        if reconnect { try await connectClient() }
        return try await ensureClient()
    }

    private static func exec(_ command: String, on client: SSHClient) async throws -> String {
        let buffer = try await client.executeCommand(
            command, maxResponseSize: 8 * 1024 * 1024, mergeStreams: false)
        return String(buffer: buffer)
    }

    // MARK: - Connection management

    /// Opens (or re-opens) the SSH + SFTP channel. Assumes `lock` is held.
    private func connectClient() async throws {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil

        let method: SSHAuthenticationMethod
        switch auth {
        case .password(let p):
            method = .passwordBased(username: config.username, password: p)
        case .ed25519(let key):
            method = .ed25519(username: config.username, privateKey: key)
        }
        // Trust-on-first-use host-key pinning: pin the key on the first connection,
        // then require it to match on every later connection.
        let outcome = HostKeyOutcome()
        let validator = SSHHostKeyValidator.custom(
            TOFUHostKeyValidator(host: config.host, port: config.port,
                                 store: hostKeyStore, outcome: outcome))
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: method,
                hostKeyValidator: validator,
                reconnect: .never
            )
        } catch {
            if outcome.mismatch { throw SFTPConnectError.hostKeyMismatch }
            throw error
        }
        self.client = client
        self.sftp = try await client.openSFTP()
    }

    /// Returns a live SFTP client, opening one if needed. Assumes `lock` is held.
    private func ensureConnected() async throws -> SFTPClient {
        if let sftp { return sftp }
        try await connectClient()
        guard let sftp else { throw SFTPError.notConnected }
        return sftp
    }

    /// Returns a live SSH client, opening one if needed. Assumes `lock` is held.
    private func ensureClient() async throws -> SSHClient {
        if let client { return client }
        try await connectClient()
        guard let client else { throw SFTPError.notConnected }
        return client
    }

    /// Runs one SFTP operation under the serialization lock. If it fails with a
    /// connection-class error, re-opens the connection once and retries a single
    /// time. Benign errors (e.g. a missing file) are rethrown WITHOUT reconnecting
    /// — otherwise a missing `.lrc` or a snapshot folder lacking a subpath would
    /// needlessly tear down the live channel (and any in-flight playback stream).
    private func withReconnect<T>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        await lock.acquire()
        defer { Task { await lock.release() } }
        do {
            let sftp = try await ensureConnected()
            return try await body(sftp)
        } catch {
            guard Self.isConnectionError(error) else { throw error }
            try await connectClient()
            let sftp = try await ensureConnected()
            return try await body(sftp)
        }
    }

    /// Whether an error means the channel is gone (reconnect) vs. the server simply
    /// answered with a non-OK status like "no such file" (channel healthy, rethrow).
    private static func isConnectionError(_ error: Error) -> Bool {
        // NB: `Citadel.SFTPError` is qualified because this file also declares its
        // own `SFTPError` (notConnected/missingSize), which would otherwise shadow it.
        if let sftp = error as? Citadel.SFTPError {
            switch sftp {
            case .errorStatus:
                return false   // server replied (missing file, permission denied, …) — channel is fine
            default:
                return true    // connectionClosed / missingResponse / invalidResponse / … — channel suspect
            }
        }
        // Transport/SSH errors (NIO ChannelError, IOError, SSHClientError, …) — treat as a dropped connection.
        return true
    }

    private static func entry(from name: SFTPPathComponent, parent: String) -> RemoteEntry? {
        let filename = name.filename
        if filename == "." || filename == ".." { return nil }
        let attrs = name.attributes
        let isDir: Bool = {
            if let perms = attrs.permissions { return (perms & 0o170000) == 0o040000 }
            return name.longname.first == "d"
        }()
        let full = parent.hasSuffix("/") ? parent + filename : parent + "/" + filename
        return RemoteEntry(
            name: filename,
            path: full,
            isDirectory: isDir,
            size: Int64(attrs.size ?? 0),
            modificationDate: attrs.accessModificationTime?.modificationTime
        )
    }
}
