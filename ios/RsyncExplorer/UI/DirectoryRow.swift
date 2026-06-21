import SwiftUI

struct DirectoryRow: View {
    let entry: RemoteEntry
    let isDeleted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isDeleted {
                Circle().fill(.red).frame(width: 9, height: 9)
            }
        }
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch entry.kind {
        case .folder: return "folder.fill"
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .other: return "doc"
        }
    }

    private var subtitle: String {
        entry.isDirectory ? "Folder"
            : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
    }
}
