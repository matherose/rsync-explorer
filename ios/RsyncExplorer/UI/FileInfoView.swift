import SwiftUI

struct FileInfoView: View {
    let item: SnapshotMerge.Item
    var snapshotRoots: [String] = []
    @Environment(\.dismiss) private var dismiss

    private var snapshotName: String? {
        SnapshotResolver.snapshotName(forPath: item.entry.path, roots: snapshotRoots)
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Name", value: item.entry.name)
                LabeledContent("Type", value: typeLabel)
                if !item.entry.isDirectory {
                    LabeledContent("Size", value: ByteCountFormatter.string(
                        fromByteCount: item.entry.size, countStyle: .file))
                }
                if let d = item.entry.modificationDate {
                    LabeledContent("Modified", value: d.formatted(date: .abbreviated, time: .shortened))
                }
                Section("Snapshot") {
                    if let snapshotName {
                        LabeledContent(item.isDeleted ? "Last seen in" : "From", value: snapshotName)
                    }
                    LabeledContent("Status",
                                   value: item.isDeleted ? "Deleted in latest snapshot" : "In latest snapshot")
                }
                Section("Path") {
                    Text(item.entry.path).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var typeLabel: String {
        switch item.entry.kind {
        case .folder: "Folder"
        case .image: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .other: "File"
        }
    }
}
