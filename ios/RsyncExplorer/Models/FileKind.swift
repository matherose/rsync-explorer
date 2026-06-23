import Foundation

enum FileKind: Equatable {
    case folder, image, video, audio, other

    private static let imageExt: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "avif", "jp2"]
    private static let videoExt: Set<String> =
        ["mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "m2ts", "mts", "flv", "wmv",
         "mpg", "mpeg", "mpe", "ogv", "3gp", "3g2", "vob", "divx", "rm", "rmvb",
         "asf", "f4v", "mxf", "dv", "qt", "ogm"]
    private static let audioExt: Set<String> =
        ["mp3", "aac", "m4a", "flac", "wav", "aiff", "aif", "ogg", "oga", "opus",
         "wma", "alac", "ape", "ac3", "dts", "amr", "mka", "caf", "wv", "tta"]

    static func from(name: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExt.contains(ext) { return .image }
        if videoExt.contains(ext) { return .video }
        if audioExt.contains(ext) { return .audio }
        return .other
    }

    /// True for kinds shown in the swipeable media carousel.
    var isMedia: Bool { self == .image || self == .video || self == .audio }
}
