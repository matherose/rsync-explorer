import SwiftUI

struct DirectoryRow: View {
    let entry: RemoteEntry
    let isDeleted: Bool
    let thumbnails: ThumbnailService
    var folderSize: Int64? = nil       // computed on demand for directories
    var calculating: Bool = false

    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbView
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .task(id: entry.id) {
            guard thumb == nil, entry.kind == .image || entry.kind == .video else { return }
            thumb = await thumbnails.thumbnail(for: entry)
        }
        // (audio shows the music icon; no thumbnail)
    }

    /// One spoken phrase per row: name, kind, size (when known), and deleted status.
    private var accessibilityLabel: String {
        var parts = [entry.name, kindLabel]
        if entry.isDirectory {
            if let folderSize {
                parts.append(ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file))
            }
        } else {
            parts.append(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
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

    @ViewBuilder private var thumbView: some View {
        ZStack {
            if let thumb {
                Image(uiImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 44, height: 44)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .bottomTrailing) {
            if entry.kind == .video {
                Image(systemName: "play.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .padding(2)
            }
        }
    }

    private var icon: String {
        switch entry.kind {
        case .folder: return "folder.fill"
        case .image: return "photo"
        case .video: return "play.rectangle.fill"
        case .audio: return "music.note"
        case .other: return "doc"
        }
    }

    private var subtitle: String {
        guard entry.isDirectory else {
            return ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        }
        if calculating { return "Folder · calculating…" }
        if let folderSize {
            return "Folder · " + ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file)
        }
        return "Folder"
    }
}
