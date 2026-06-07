/**
 * ColumnConfig.swift
 * Manages visible/hidden columns, order, and width persistence via UserDefaults.
 */

import Cocoa

struct ColumnDef: Identifiable {
    let id: String           // unique key used in UserDefaults
    let title: String
    let minWidth: CGFloat
    let defaultVisible: Bool

    static let all: [ColumnDef] = [
        ColumnDef(id: "path",        title: "Name",          minWidth: 200, defaultVisible: true),
        ColumnDef(id: "size",        title: "Size",          minWidth: 70,  defaultVisible: true),
        ColumnDef(id: "mtime",       title: "Date Modified", minWidth: 130, defaultVisible: true),
        ColumnDef(id: "lastBackup",  title: "Last Backup",   minWidth: 110, defaultVisible: true),
        ColumnDef(id: "firstBackup", title: "First Backup",  minWidth: 110, defaultVisible: false),
        ColumnDef(id: "class",       title: "Class",         minWidth: 50,  defaultVisible: false),
        ColumnDef(id: "perm",        title: "Permissions",   minWidth: 95,  defaultVisible: false),
        ColumnDef(id: "user",        title: "User",          minWidth: 60,  defaultVisible: false),
        ColumnDef(id: "group",       title: "Group",         minWidth: 60,  defaultVisible: false),
        ColumnDef(id: "deletedIn",   title: "Deleted In",    minWidth: 130, defaultVisible: false),
        ColumnDef(id: "nlink",       title: "Hard Links",    minWidth: 70,  defaultVisible: false),
    ]
}

class ColumnConfig {

    private let defaults = UserDefaults.standard
    private let keyOrder    = "rsyncx.column.order.v2"
    private let keyVisible  = "rsyncx.column.visible.v2"
    private let keyWidth    = "rsyncx.column.width.v2"

    /// Ordered list of column IDs (may be a subset of all).
    var order: [String] {
        didSet { defaults.set(order, forKey: keyOrder) }
    }

    /// Set of visible column IDs.
    var visible: Set<String> {
        didSet { defaults.set(Array(visible), forKey: keyVisible) }
    }

    /// Column widths by ID.
    var widths: [String: CGFloat] {
        didSet { defaults.set(widths, forKey: keyWidth) }
    }

    init() {
        order   = defaults.stringArray(forKey: keyOrder)
                ?? ColumnDef.all.map { $0.id }
        visible = Set(defaults.stringArray(forKey: keyVisible)
                ?? ColumnDef.all.filter { $0.defaultVisible }.map { $0.id })
        widths  = (defaults.dictionary(forKey: keyWidth) as? [String: CGFloat])
                ?? [:]
    }

    /// Whether a column is visible.
    func isVisible(_ id: String) -> Bool {
        return visible.contains(id)
    }

    /// Toggle visibility.
    func toggle(_ id: String) {
        if visible.contains(id) { visible.remove(id) }
        else { visible.insert(id) }
    }

    /// Width for a column, or its default minimum.
    func width(_ id: String) -> CGFloat {
        return widths[id] ?? (ColumnDef.all.first { $0.id == id }?.minWidth ?? 80)
    }

    /// Save width for a column.
    func setWidth(_ w: CGFloat, for id: String) {
        widths[id] = w
    }

    /// Column definitions in current display order, filtered by visibility.
    func visibleColumns() -> [ColumnDef] {
        return order.compactMap { id in
            guard visible.contains(id) else { return nil }
            return ColumnDef.all.first { $0.id == id }
        }
    }

    /// All column definitions in current order (for right-click menu).
    func allColumnsOrdered() -> [ColumnDef] {
        return order.compactMap { id in ColumnDef.all.first { $0.id == id } }
    }
}
