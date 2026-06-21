import SwiftUI

struct TreeNodeView: View {
    @ObservedObject var node: TreeNode
    let service: SFTPService
    let siblingImages: [RemoteEntry]
    let onOpenImage: (RemoteEntry, [RemoteEntry]) -> Void
    let onOpenVideo: (RemoteEntry) -> Void
    let onOpenOther: (RemoteEntry) -> Void

    var body: some View {
        if node.entry.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                if node.isLoading {
                    HStack(spacing: 8) { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else {
                    ForEach(node.children) { child in
                        TreeNodeView(node: child,
                                     service: service,
                                     siblingImages: node.imageChildren,
                                     onOpenImage: onOpenImage,
                                     onOpenVideo: onOpenVideo,
                                     onOpenOther: onOpenOther)
                    }
                }
            } label: {
                DirectoryRow(entry: node.entry, isDeleted: node.isDeleted)
            }
            .onChange(of: node.isExpanded) { _, expanded in
                if expanded { Task { await node.loadIfNeeded(service: service) } }
            }
        } else {
            Button(action: open) {
                DirectoryRow(entry: node.entry, isDeleted: node.isDeleted)
            }
            .buttonStyle(.plain)
        }
    }

    private func open() {
        switch node.entry.kind {
        case .image: onOpenImage(node.entry, siblingImages)
        case .video: onOpenVideo(node.entry)
        default: onOpenOther(node.entry)
        }
    }
}
