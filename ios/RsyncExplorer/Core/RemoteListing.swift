import Foundation

/// Lists one folder across *every* snapshot root in a single server-side `find`,
/// instead of one SFTP round-trip per snapshot (which, with many `--link-dest`
/// snapshots, made each first-time folder open slow regardless of its contents).
///
/// One `find` over all the per-snapshot folder paths emits each immediate child as
/// `type\tsize\tmtime\tpath`; `parse` groups them back per root (newest first, for
/// `SnapshotMerge`). A trailing sentinel, gated on `find` existing, lets the parser
/// tell "genuinely empty" from "find unavailable" so the caller only falls back to
/// the per-root SFTP loop when the command truly couldn't run.
enum RemoteListing {
    static let sentinel = "@@RFEOK@@"

    static func run(roots: [String], rel: String, service: SFTPService) async -> LoadedListing? {
        guard !roots.isEmpty else { return nil }
        guard let out = try? await service.runCommand(command(roots: roots, rel: rel)) else { return nil }
        return parse(out, roots: roots)
    }

    static func command(roots: [String], rel: String) -> String {
        let folders = roots
            .map { rel.isEmpty ? $0 : $0 + "/" + rel }
            .map(shellQuote)
            .joined(separator: " ")
        // -H: dereference the start paths (the `latest` pointer symlink) but not entry
        // symlinks. -mindepth/-maxdepth 1: immediate children only. printf path LAST so
        // a tab in a name can't shift the fixed columns. Sentinel marks a real run.
        // LC_ALL=C: stable, English `find:` error strings to classify. 2>&1: route find's
        // per-path errors into the stream so a transient read failure is detectable
        // (vs. a snapshot that legitimately lacks the folder) — see `parse`.
        return "command -v find >/dev/null 2>&1 && { "
            + "LC_ALL=C find -H \(folders) -mindepth 1 -maxdepth 1 -printf '%y\\t%s\\t%T@\\t%p\\n' 2>&1; "
            + "printf '\(sentinel)\\n'; }"
    }

    /// Per-root listings in `roots` order with a completeness flag, or nil if the output
    /// lacks the sentinel (find unavailable / command failed → caller falls back to SFTP).
    static func parse(_ stdout: String, roots: [String]) -> LoadedListing? {
        guard stdout.contains(sentinel) else { return nil }
        let norm = roots.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var byRoot = [[RemoteEntry]](repeating: [], count: norm.count)
        var complete = true
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if raw == Substring(sentinel) { continue }
            // find writes per-path errors to stderr (merged into this stream). A snapshot
            // that legitimately lacks the folder (or can't be entered) is a definitive
            // answer; anything else (I/O error on a rebuilding array, …) means the result
            // is only partial, so the caller must not cache it.
            if raw.hasPrefix("find:") {
                if !isBenignFindError(raw) { complete = false }
                continue
            }
            let cols = raw.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard cols.count == 4 else { continue }
            let type = cols[0]
            let size = Int64(cols[1]) ?? 0
            let mtime = Double(cols[2])
            let path = String(cols[3])
            guard let ri = norm.firstIndex(where: { path.hasPrefix($0 + "/") }) else { continue }
            let name = (path as NSString).lastPathComponent
            if name.isEmpty || name == "." || name == ".." { continue }
            byRoot[ri].append(RemoteEntry(
                name: name, path: path, isDirectory: type == "d", size: size,
                modificationDate: mtime.map { Date(timeIntervalSince1970: $0) }))
        }
        return LoadedListing(listings: byRoot, complete: complete)
    }

    /// A find error that's a *definitive* answer (the folder isn't there, or we may not
    /// read it) rather than a transient failure worth distrusting the whole result over.
    /// LC_ALL=C in `command` keeps these strings stable/English.
    private static func isBenignFindError(_ line: Substring) -> Bool {
        line.contains("No such file or directory") || line.contains("Permission denied")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
