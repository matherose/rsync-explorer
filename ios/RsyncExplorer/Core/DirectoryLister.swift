import Foundation

/// Lists one folder across all snapshot roots, preferring the one-shot server-side
/// `find` (RemoteListing) and falling back to per-root SFTP. Reports completeness so the
/// caller only caches an authoritative result — a transient read failure yields a
/// listing the UI can show but won't bake into the cache.
enum DirectoryLister {
    static func load(roots: [String], rel: String, service: SFTPService) async -> LoadedListing? {
        guard !roots.isEmpty else { return nil }

        // Fast path: one `find` across every snapshot (it carries its own completeness).
        if let server = await RemoteListing.run(roots: roots, rel: rel, service: service) {
            return server
        }

        // Fallback: list each snapshot over SFTP, classifying per-root failures so a
        // dropped read can't masquerade as "this snapshot has nothing here".
        var listings: [[RemoteEntry]] = []
        var complete = true
        var anyRead = false
        for root in roots {
            let folder = rel.isEmpty ? root : root + "/" + rel
            switch await service.listDirectoryOutcome(folder) {
            case .listed(let entries): listings.append(entries); anyRead = true
            case .absent:              listings.append([]); anyRead = true
            case .failed:              listings.append([]); complete = false
            }
        }
        // Nothing could be read at all -> a total failure: surface it (so the UI shows
        // Retry) rather than returning an empty listing that would look like an empty folder.
        guard anyRead else { return nil }
        return LoadedListing(listings: listings, complete: complete)
    }
}
