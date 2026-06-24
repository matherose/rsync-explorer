import Foundation
import Citadel
import Crypto
import NIOCore

enum SFTPError: Error { case notConnected, missingSize }

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
            defer { Task { try? await file.close() } }
            let buf = try await file.read(from: offset, length: length)
            return Data(buf.readableBytesView)
        }
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
        // TODO(Phase E): replace .acceptAnything() with TOFU host-key pinning.
        let client = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: method,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
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

    /// Runs one SFTP operation under the serialization lock. If it fails (e.g. the
    /// channel dropped), re-opens the connection once and retries a single time.
    private func withReconnect<T>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        await lock.acquire()
        defer { Task { await lock.release() } }
        do {
            let sftp = try await ensureConnected()
            return try await body(sftp)
        } catch {
            try await connectClient()
            let sftp = try await ensureConnected()
            return try await body(sftp)
        }
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
