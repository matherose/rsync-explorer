/**
 * EngineBridge.swift
 * Thin Swift wrappers around the C engine API.
 * Uses C accessor functions (rsyncx_source_name, etc.) to avoid
 * the Swift/C char-array impedance mismatch (char[128] → unnamed tuple).
 */

import Foundation
import engine

// MARK: - Swift value types

enum SourceType: UInt32 {
    case local = 0
    case remote = 1
}

enum FileClass: UInt32 {
    case unchanged = 0
    case modified  = 1
    case isNew     = 2
    case deleted   = 3
    case delNew    = 4
}

struct Source: Identifiable {
    let id: String
    let name: String
    let type: SourceType
    let dest: String
    let host: String
    let user: String
    let sshKey: String
}

struct Snapshot: Identifiable {
    let id: String
    let name: String
    let fullPath: String
    let dateEpoch: Date
    let index: Int
}

struct FileEntry: Identifiable {
    let id: String
    let relPath: String
    let classification: FileClass
    let mode: UInt32
    let user: String
    let group: String
    let size: UInt64
    let mtime: Date
    let firstBackup: Date
    let lastBackup: Date
    let deletedIn: Date?
    let lastRealPath: String
    let isDir: Bool
    let nlink: UInt32
}

struct DirEntry: Identifiable {
    let id: String
    let name: String
    let existsInLatest: Bool
}

// MARK: - Engine bridge

class EngineBridge {

    static func parseConfig(at path: String) -> [Source]? {
        var out: UnsafeMutablePointer<source_t>?
        var count: Int32 = 0

        guard rsyncx_parse_config(path, &out, &count) == 0,
              let ptr = out else { return nil }
        defer { rsyncx_free(ptr) }

        var result: [Source] = []
        for i in 0..<Int(count) {
            let cs = ptr + i
            let src = Source(
                id: String(cString: rsyncx_source_name(cs)),
                name: String(cString: rsyncx_source_name(cs)),
                type: SourceType(rawValue: cs.pointee.type.rawValue) ?? .local,
                dest: String(cString: rsyncx_source_dest(cs)),
                host: String(cString: rsyncx_source_host(cs)),
                user: String(cString: rsyncx_source_user(cs)),
                sshKey: String(cString: rsyncx_source_ssh_key(cs))
            )
            result.append(src)
        }
        return result
    }

    static func discover(source: Source) -> [Snapshot]? {
        let cSource = source.toC()
        var cSourceCopy = cSource
        var out: UnsafeMutablePointer<snapshot_t>?
        var count: Int32 = 0

        guard rsyncx_discover(&cSourceCopy, &out, &count) == 0,
              let ptr = out else { return nil }
        defer { rsyncx_free(ptr) }

        var result: [Snapshot] = []
        for i in 0..<Int(count) {
            let cs = ptr + i
            let snap = Snapshot(
                id: String(cString: rsyncx_snapshot_name(cs)),
                name: String(cString: rsyncx_snapshot_name(cs)),
                fullPath: String(cString: rsyncx_snapshot_full_path(cs)),
                dateEpoch: Date(timeIntervalSince1970: TimeInterval(cs.pointee.date_epoch)),
                index: i
            )
            result.append(snap)
        }
        return result
    }

    static func scanDir(source: Source, snapshots: [Snapshot],
                        relPath: String, fromIdx: Int, toIdx: Int) -> [FileEntry]? {
        let cSource = source.toC()
        var cSourceCopy = cSource
        let cSnaps = snapshots.map { $0.toC() }

        var out: UnsafeMutablePointer<lifecycle_t>?
        var count: Int32 = 0

        guard rsyncx_scan_dir(&cSourceCopy, cSnaps, Int32(snapshots.count),
                              relPath, Int32(fromIdx), Int32(toIdx),
                              &out, &count) == 0,
              let ptr = out else { return nil }
        defer { rsyncx_free(ptr) }

        var result: [FileEntry] = []
        for i in 0..<Int(count) {
            let lc = ptr + i
            let entry = makeFileEntry(lc)
            result.append(entry)
        }
        return result
    }

    static func expandTree(source: Source, snapshots: [Snapshot],
                           relPath: String, fromIdx: Int, toIdx: Int) -> [DirEntry]? {
        let cSource = source.toC()
        var cSourceCopy = cSource
        let cSnaps = snapshots.map { $0.toC() }

        var out: UnsafeMutablePointer<dir_entry_t>?
        var count: Int32 = 0

        guard rsyncx_expand_tree(&cSourceCopy, cSnaps, Int32(snapshots.count),
                                 relPath, Int32(fromIdx), Int32(toIdx),
                                 &out, &count) == 0,
              let ptr = out else { return nil }
        defer { rsyncx_free(ptr) }

        var result: [DirEntry] = []
        for i in 0..<Int(count) {
            let d = ptr + i
            let entry = DirEntry(
                id: String(cString: rsyncx_dir_name(d)),
                name: String(cString: rsyncx_dir_name(d)),
                existsInLatest: d.pointee.exists_in_latest != 0
            )
            result.append(entry)
        }
        return result
    }

    static func search(source: Source, snapshots: [Snapshot],
                       query: String, fromIdx: Int, toIdx: Int) -> [FileEntry]? {
        let cSource = source.toC()
        var cSourceCopy = cSource
        let cSnaps = snapshots.map { $0.toC() }

        var out: UnsafeMutablePointer<lifecycle_t>?
        var count: Int32 = 0

        guard rsyncx_search(&cSourceCopy, cSnaps, Int32(snapshots.count),
                            query, Int32(fromIdx), Int32(toIdx),
                            &out, &count) == 0,
              let ptr = out else { return nil }
        defer { rsyncx_free(ptr) }

        var result: [FileEntry] = []
        for i in 0..<Int(count) {
            let lc = ptr + i
            let entry = makeFileEntry(lc)
            result.append(entry)
        }
        return result
    }

    // MARK: - In-memory index

    /// Box that carries a Swift progress closure across the C callback boundary.
    private final class ProgressBox {
        let cb: (Int, Int, Int) -> Void
        init(_ cb: @escaping (Int, Int, Int) -> Void) { self.cb = cb }
    }

    /// Build the whole-backup index. `progress(done, total, files)` is invoked on
    /// the calling (background) thread. Returns an opaque index handle or nil.
    static func buildIndex(source: Source, snapshots: [Snapshot],
                           fromIdx: Int, toIdx: Int,
                           progress: @escaping (Int, Int, Int) -> Void) -> OpaquePointer? {
        var cSourceCopy = source.toC()
        let cSnaps = snapshots.map { $0.toC() }

        let box = ProgressBox(progress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ProgressBox>.fromOpaque(ctx).release() }

        let cb: @convention(c) (Int32, Int32, Int, UnsafeMutableRawPointer?) -> Void = {
            done, total, files, ctx in
            guard let ctx = ctx else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            box.cb(Int(done), Int(total), files)
        }

        return rsyncx_build_index(&cSourceCopy, cSnaps, Int32(snapshots.count),
                                  Int32(fromIdx), Int32(toIdx), cb, ctx)
    }

    static func freeIndex(_ idx: OpaquePointer) {
        rsyncx_index_free(idx)
    }

    @discardableResult
    static func setRange(_ idx: OpaquePointer, fromIdx: Int, toIdx: Int) -> Bool {
        return rsyncx_index_set_range(idx, Int32(fromIdx), Int32(toIdx)) == 0
    }

    static func indexChildren(_ idx: OpaquePointer, relPath: String) -> [FileEntry] {
        var out: UnsafeMutablePointer<lifecycle_t>?
        var count: Int32 = 0
        guard rsyncx_index_children(idx, relPath, &out, &count) == 0,
              let ptr = out else { return [] }
        defer { rsyncx_free(ptr) }
        return (0..<Int(count)).map { makeFileEntry(ptr + $0) }
    }

    static func indexDirs(_ idx: OpaquePointer, relPath: String) -> [DirEntry] {
        var out: UnsafeMutablePointer<dir_entry_t>?
        var count: Int32 = 0
        guard rsyncx_index_dirs(idx, relPath, &out, &count) == 0,
              let ptr = out else { return [] }
        defer { rsyncx_free(ptr) }
        return (0..<Int(count)).map { i -> DirEntry in
            let d = ptr + i
            return DirEntry(id: String(cString: rsyncx_dir_name(d)),
                            name: String(cString: rsyncx_dir_name(d)),
                            existsInLatest: d.pointee.exists_in_latest != 0)
        }
    }

    static func indexSearch(_ idx: OpaquePointer, query: String) -> [FileEntry] {
        var out: UnsafeMutablePointer<lifecycle_t>?
        var count: Int32 = 0
        guard rsyncx_index_search(idx, query, &out, &count) == 0,
              let ptr = out else { return [] }
        defer { rsyncx_free(ptr) }
        return (0..<Int(count)).map { makeFileEntry(ptr + $0) }
    }

    // MARK: - Private helpers

    private static func makeFileEntry(_ lc: UnsafeMutablePointer<lifecycle_t>) -> FileEntry {
        let p = lc.pointee
        return FileEntry(
            id: String(cString: rsyncx_lc_rel_path(lc)),
            relPath: String(cString: rsyncx_lc_rel_path(lc)),
            classification: FileClass(rawValue: p.class.rawValue) ?? .unchanged,
            mode: p.mode,
            user: String(cString: rsyncx_lc_user(lc)),
            group: String(cString: rsyncx_lc_group(lc)),
            size: p.size,
            mtime: Date(timeIntervalSince1970: TimeInterval(p.mtime)),
            firstBackup: Date(timeIntervalSince1970: TimeInterval(p.first_backup)),
            lastBackup: Date(timeIntervalSince1970: TimeInterval(p.last_backup)),
            deletedIn: p.deleted_in >= 0
                ? Date(timeIntervalSince1970: TimeInterval(p.deleted_in))
                : nil,
            lastRealPath: String(cString: rsyncx_lc_last_real_path(lc)),
            isDir: p.is_dir != 0,
            nlink: p.nlink
        )
    }
}

// MARK: - C struct conversion using rsyncx_make_* helpers

extension Source {
    func toC() -> source_t {
        return rsyncx_make_source(
            name, Int32(type.rawValue),
            dest, host, user, sshKey
        )
    }
}

extension Snapshot {
    func toC() -> snapshot_t {
        return rsyncx_make_snapshot(
            name, fullPath,
            Int64(dateEpoch.timeIntervalSince1970)
        )
    }
}
