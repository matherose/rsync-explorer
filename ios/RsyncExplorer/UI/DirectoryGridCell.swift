import SwiftUI

struct DirectoryGridCell: View {
    let entry: RemoteEntry
    let isDeleted: Bool
    let thumbnails: ThumbnailService
    var folderSize: Int64? = nil       // computed on demand for directories
    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground))
                if let thumb {
                    Image(uiImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: icon).font(.title).foregroundStyle(Color.accentColor)
                }
                if entry.kind == .video {
                    Image(systemName: "play.circle.fill").foregroundStyle(.white).shadow(radius: 1)
                }
                if isDeleted {
                    VStack {
                        HStack { Spacer(); Circle().fill(.red).frame(width: 9, height: 9).padding(5) }
                        Spacer()
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(entry.name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let folderSize {
                Text(ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .task(id: entry.id) {
            guard thumb == nil, entry.kind == .image || entry.kind == .video else { return }
            thumb = await thumbnails.thumbnail(for: entry)
        }
    }

    /// One spoken phrase per cell: name, kind, size (when known), and deleted status.
    private var accessibilityLabel: String {
        var parts = [entry.name, kindLabel]
        if let folderSize {
            parts.append(ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file))
        }
        if isDeleted { parts.append("deleted") }
        return parts.joined(separator: ", ")
    }

    private var kindLabel: String {
        switch entry.kind {
        case .folder: return "Folder"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .other: return "File"
        }
    }

    private var icon: String {
        switch entry.kind {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "play.rectangle.fill"
        case .audio: "music.note"
        case .other: "doc"
        }
    }
}
