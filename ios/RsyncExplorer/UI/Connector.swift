import Foundation

/// Builds and opens a BrowserSession from saved connection details (password auth).
/// Shared by the sign-in form and launch-time auto-connect.
enum Connector {
    static let defaultPointerName = "latest"

    static func connect(_ c: SavedConnection, password: String) async throws -> BrowserSession {
        let config = ServerConfig(name: "nas", host: c.host, port: c.port,
                                  username: c.username, remotePath: c.remotePath,
                                  authMethod: .password)
        let auth = try CitadelSFTPService.makeAuth(for: config, secret: password)
        let svc = CitadelSFTPService(config: config, auth: auth)
        try await svc.connect()

        let roots = await resolveRoots(snapshotsPath: c.remotePath,
                                       pointerName: pointerName(c.latestPointerName),
                                       via: svc)
        return BrowserSession(service: svc, snapshotRoots: roots)
    }

    /// The effective pointer name: the trimmed user value, or "latest" when blank.
    static func pointerName(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? defaultPointerName : trimmed
    }

    /// Resolves the snapshot roots (newest -> oldest). The latest-snapshot pointer,
    /// when present in the directory, is prepended as the authoritative newest root
    /// (so it drives both browsing order and deletion detection). All dated snapshot
    /// folders are unioned after it so files that exist only in older snapshots
    /// remain visible. Only prepends the pointer if it actually exists, so a wrong
    /// name can't make every file look deleted.
    static func resolveRoots(snapshotsPath: String, pointerName: String,
                             via svc: SFTPService) async -> [String] {
        let entries = (try? await svc.listDirectory(snapshotsPath)) ?? []
        var roots = SnapshotResolver.datedSnapshots(from: entries).map(\.path)

        if entries.contains(where: { $0.name == pointerName }) {
            let pointerPath = SnapshotResolver.join(snapshotsPath, pointerName)
            roots.removeAll { $0 == pointerPath }
            roots.insert(pointerPath, at: 0)
        }

        // Fallback: look one level up for dated snapshots if we found nothing.
        if roots.isEmpty {
            let parent = SnapshotResolver.parentPath(snapshotsPath)
            if parent != snapshotsPath {
                let parentEntries = (try? await svc.listDirectory(parent)) ?? []
                roots = SnapshotResolver.datedSnapshots(from: parentEntries).map(\.path)
            }
        }
        if roots.isEmpty { roots = [snapshotsPath] }
        return roots
    }
}
