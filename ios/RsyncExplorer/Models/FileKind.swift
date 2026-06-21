import Foundation

enum FileKind: Equatable {
    case folder, image, video, other

    private static let imageExt: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff"]
    private static let videoExt: Set<String> =
        ["mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "flv", "wmv", "mpg", "mpeg"]

    static func from(name: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExt.contains(ext) { return .image }
        if videoExt.contains(ext) { return .video }
        return .other
    }
}
