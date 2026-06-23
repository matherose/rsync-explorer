import SwiftUI

struct DirectoryRow: View {
    let entry: RemoteEntry
    let isDeleted: Bool
    let thumbnails: ThumbnailService

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
        .task(id: entry.id) {
            guard thumb == nil, entry.kind == .image || entry.kind == .video else { return }
            thumb = await thumbnails.thumbnail(for: entry)
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
        case .other: return "doc"
        }
    }

    private var subtitle: String {
        entry.isDirectory ? "Folder"
            : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
    }
}
