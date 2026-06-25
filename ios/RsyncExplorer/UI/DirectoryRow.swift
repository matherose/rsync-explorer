import SwiftUI

struct DirectoryRow: View {
    let entry: RemoteEntry
    let isDeleted: Bool
    let thumbnails: ThumbnailService
    var folderSize: FolderSize? = nil  // computed on demand for directories
    var calculating: Bool = false

    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbView
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
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
            if let folderSize { parts.append(Self.sizeText(folderSize)) }
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

    // The folder icon already conveys "folder", so the subtitle carries only size
    // info: a file's size, a folder's computed size, "Calculating…", or nothing.
    private var subtitle: String? {
        guard entry.isDirectory else {
            return ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        }
        if calculating { return "Calculating…" }
        return folderSize.map(Self.sizeText)
    }

    /// Complete -> exact size; partial (du couldn't fully read) -> "≥ X", or "—" when
    /// it couldn't read anything, so a permission-denied folder isn't shown as empty.
    static func sizeText(_ size: FolderSize) -> String {
        switch size {
        case .complete(let n):
            return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
        case .partial(let n):
            return n > 0 ? "≥ " + ByteCountFormatter.string(fromByteCount: n, countStyle: .file) : "—"
        }
    }
}
