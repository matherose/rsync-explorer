import Foundation

struct RemoteEntry: Identifiable, Equatable, Hashable {
    var id: String { path }
    let name: String
    let path: String          // absolute remote path
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    var kind: FileKind { FileKind.from(name: name, isDirectory: isDirectory) }
}
