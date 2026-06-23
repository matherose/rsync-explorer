import SwiftUI

struct FileInfoView: View {
    let item: SnapshotMerge.Item
    @Environment(\.dismiss) private var dismiss

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
                LabeledContent("Status",
                               value: item.isDeleted ? "Deleted since previous snapshot" : "In latest snapshot")
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
