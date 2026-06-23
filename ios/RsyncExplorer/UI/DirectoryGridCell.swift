import SwiftUI

struct DirectoryGridCell: View {
    let entry: RemoteEntry
    let isDeleted: Bool
    let thumbnails: ThumbnailService
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
        }
        .task(id: entry.id) {
            guard thumb == nil, entry.kind == .image || entry.kind == .video else { return }
            thumb = await thumbnails.thumbnail(for: entry)
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
