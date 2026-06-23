import Foundation

/// Builds and opens a BrowserSession from saved connection details (password auth).
/// Shared by the sign-in form and launch-time auto-connect.
enum Connector {
    static func connect(_ c: SavedConnection, password: String) async throws -> BrowserSession {
        let config = ServerConfig(name: "nas", host: c.host, port: c.port,
                                  username: c.username, remotePath: c.remotePath,
                                  authMethod: .password)
        let auth = try CitadelSFTPService.makeAuth(for: config, secret: password)
        let svc = CitadelSFTPService(config: config, auth: auth)
        try await svc.connect()

        var roots = SnapshotResolver
            .datedSnapshots(from: try await svc.listDirectory(c.remotePath))
            .map(\.path)
        if roots.isEmpty {
            let parent = SnapshotResolver.parentPath(c.remotePath)
            if parent != c.remotePath {
                let parentEntries = (try? await svc.listDirectory(parent)) ?? []
                roots = SnapshotResolver.datedSnapshots(from: parentEntries).map(\.path)
            }
        }
        if roots.isEmpty { roots = [c.remotePath] }
        return BrowserSession(service: svc, snapshotRoots: roots)
    }
}
