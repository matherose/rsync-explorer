import Foundation

/// Server-side recursive search. Asks the NAS to find matching names with the
/// fastest available tool (fd / fdfind / plocate / find), then resolves only the
/// parent folders that contained matches through the same `SnapshotMerge` the
/// browser uses — so each `SearchHit` carries accurate metadata + `isDeleted` and
/// duplicates across snapshots are unioned, exactly like the in-app walk but
/// without traversing the whole tree.
///
/// Returns `nil` when the host has no usable tool or any remote command fails, so
/// the caller can fall back to `RecursiveSearch`. An empty (non-nil) array means
/// "searched server-side, genuinely no matches".
enum RemoteSearch {
    static func run(query: String,
                    baseRel: String,
                    roots: [String],
                    service: SFTPService,
                    rawLimit: Int = 5000,
                    maxResults: Int = 500) async -> [SearchHit]? {
        guard !query.isEmpty, !roots.isEmpty else { return nil }
        do {
            // 1. Probe for the fastest available backend (one tiny command).
            let probe = try await service.runCommand(RemoteSearchCommand.probeCommand)
            guard let tool = RemoteSearchCommand.tool(fromProbeOutput: probe) else { return nil }

            // 2. Run the search, scoped to the current subtree of every snapshot root.
            let searchRoots = roots.map { baseRel.isEmpty ? $0 : $0 + "/" + baseRel }
            var paths = try await matchingPaths(tool: tool, query: query, roots: searchRoots,
                                                rawLimit: rawLimit, service: service)
            // plocate's index can be stale/empty — fall back to find if it found nothing.
            if paths.isEmpty, tool == .plocate {
                paths = try await matchingPaths(tool: .find, query: query, roots: searchRoots,
                                                rawLimit: rawLimit, service: service)
            }
            if paths.isEmpty { return [] }

            // 3. Resolve to union SearchHits via parent-folder listings + SnapshotMerge.
            return try await resolveHits(paths: paths, roots: roots, query: query,
                                         maxResults: maxResults, service: service)
        } catch {
            return nil   // unsupported / connection / exec error → caller falls back
        }
    }

    private static func matchingPaths(tool: RemoteSearchTool, query: String, roots: [String],
                                      rawLimit: Int, service: SFTPService) async throws -> [String] {
        let cmd = RemoteSearchCommand.command(tool: tool, term: query, roots: roots, limit: rawLimit)
        let out = try await service.runCommand(cmd)
        return RemoteSearchCommand.parseResults(out, term: query, roots: roots)
    }

    /// Turns the flat list of matching paths into union `SearchHit`s: collect the
    /// distinct parent folders, list each across every snapshot root, merge, and keep
    /// the children that match — so metadata and `isDeleted` come from the same merge
    /// the browser shows, and the same name across snapshots collapses to one hit.
    private static func resolveHits(paths: [String], roots: [String], query: String,
                                    maxResults: Int, service: SFTPService) async throws -> [SearchHit] {
        var parents = [String]()            // first-seen order
        var seenParent = Set<String>()
        for p in paths {
            guard let rel = relativePath(of: p, roots: roots) else { continue }
            let parent = (rel as NSString).deletingLastPathComponent
            if seenParent.insert(parent).inserted { parents.append(parent) }
        }

        var hits = [SearchHit]()
        var seenHit = Set<String>()
        for parent in parents {
            if hits.count >= maxResults { break }
            var listings = [[RemoteEntry]]()
            for root in roots {
                let folder = parent.isEmpty ? root : root + "/" + parent
                listings.append((try? await service.listDirectory(folder)) ?? [])
            }
            for item in SnapshotMerge.merge(listings)
            where item.entry.name.localizedCaseInsensitiveContains(query) {
                let childRel = parent.isEmpty ? item.entry.name : parent + "/" + item.entry.name
                let key = (item.entry.isDirectory ? "d:" : "f:") + childRel
                if seenHit.insert(key).inserted {
                    hits.append(SearchHit(entry: item.entry, relPath: childRel, isDeleted: item.isDeleted))
                }
            }
        }
        return hits.sorted {
            $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
        }
    }

    /// Path relative to whichever root contains it ("" if it *is* a root), else nil.
    /// Prefix-collision-safe (`/b/latest2` is not under `/b/latest`).
    static func relativePath(of path: String, roots: [String]) -> String? {
        for root in roots {
            let r = root.hasSuffix("/") ? String(root.dropLast()) : root
            if path == r { return "" }
            if path.hasPrefix(r + "/") { return String(path.dropFirst(r.count + 1)) }
        }
        return nil
    }
}
