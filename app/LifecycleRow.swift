/**
 * LifecycleRow.swift
 * Plain table row. Lifecycle is now conveyed by a leading dot / red name
 * in the Name cell (see FileListViewController), not by row background color.
 */

import Cocoa

class LifecycleRow: NSTableRowView {

    var classification: FileClass = .unchanged

    override var isEmphasized: Bool {
        get { return false }
        set { }
    }
}
