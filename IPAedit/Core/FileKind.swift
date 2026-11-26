import Foundation

enum FileKind: Equatable {
    case folder, appBundle, image, plist, text, machO, assetsCar, audio, video, pdf, provision, archive, binary

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .appBundle: return "app.badge"
        case .image: return "photo"
        case .plist: return "list.bullet.rectangle"
        case .text: return "doc.text"
        case .machO: return "cpu"
        case .assetsCar: return "square.stack.3d.up"
        case .audio: return "waveform"
        case .video: return "film"
        case .pdf: return "doc.richtext"
        case .provision: return "checkmark.seal"
        case .archive: return "doc.zipper"
        case .binary: return "doc"
        }
    }

    var defaultViewer: Viewer {
        switch self {
        case .folder, .appBundle: return .quickLook
        case .image: return .image
        case .plist: return .plist
        case .text: return .text
        case .machO: return .machO
        case .assetsCar: return .assets
        case .audio, .video: return .media
        case .pdf: return .pdf
        case .provision: return .provision
        case .archive, .binary: return .hex
        }
    }

    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "ico"]
    static let textExt: Set<String> = ["txt", "json", "xml", "html", "htm", "css", "js", "mjs", "ts", "md", "h", "hpp",
                                      "m", "mm", "c", "cc", "cpp", "swift", "sh", "py", "rb", "lua", "yml", "yaml",
                                      "csv", "log", "ini", "cfg", "conf", "strings", "storyboard", "xib",
                                      "svg", "plain", "properties", "toml", "lproj", "entitlements-xml", "jsbundle"]
    static let plistExt: Set<String> = ["plist", "stringsdict", "entitlements", "xcent"]
    static let audioExt: Set<String> = ["mp3", "wav", "m4a", "aac", "caf", "aif", "aiff", "flac", "ogg"]
    static let videoExt: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let archiveExt: Set<String> = ["zip", "ipa", "gz", "tar", "bz2", "xz", "7z", "rar", "deb"]

    static func detect(_ url: URL, isDirectory: Bool) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if isDirectory { return ext == "app" || ext == "appex" ? .appBundle : .folder }
        if imageExt.contains(ext) { return .image }
        if audioExt.contains(ext) { return .audio }
        if videoExt.contains(ext) { return .video }
        if archiveExt.contains(ext) { return .archive }
        if ext == "pdf" { return .pdf }
        if ext == "car" { return .assetsCar }
        if ext == "mobileprovision" || ext == "provisionprofile" { return .provision }
        if ext == "dylib" { return .machO }

        let head = (try? FileHandle(forReadingFrom: url)).flatMap { h -> Data? in
            defer { try? h.close() }
            return try? h.read(upToCount: 512)
        } ?? Data()

        if MachOFile.isMachO(head) { return .machO }
        if head.starts(with: Data("bplist00".utf8)) { return .plist }
        if plistExt.contains(ext) { return .plist }
        if let s = String(data: head.prefix(200), encoding: .utf8), s.contains("<plist") { return .plist }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8, 0xFF]) { return .image }
        if textExt.contains(ext) { return .text }
        if head.isEmpty { return .text }
        if looksLikeText(head) { return .text }
        return .binary
    }

    static func looksLikeText(_ data: Data) -> Bool {
        if data.contains(0) { return false }
        if String(data: data, encoding: .utf8) != nil { return true }
        // A multi-byte character may be cut at the 512-byte boundary.
        return String(data: data.dropLast(3), encoding: .utf8) != nil
    }
}

enum Viewer: String, CaseIterable, Identifiable, Hashable {
    case text, hex, plist, image, machO, strings, assets, media, pdf, provision, quickLook

    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Text Editor"
        case .hex: return "Hex Editor"
        case .plist: return "Plist Editor"
        case .image: return "Image Viewer"
        case .machO: return "Mach-O Info"
        case .strings: return "Strings Dump"
        case .assets: return "Assets.car Browser"
        case .media: return "Media Player"
        case .pdf: return "PDF Viewer"
        case .provision: return "Provisioning Profile"
        case .quickLook: return "Quick Look"
        }
    }
    var symbol: String {
        switch self {
        case .text: return "doc.text"
        case .hex: return "number"
        case .plist: return "list.bullet.indent"
        case .image: return "photo"
        case .machO: return "cpu"
        case .strings: return "text.magnifyingglass"
        case .assets: return "square.stack.3d.up"
        case .media: return "play.rectangle"
        case .pdf: return "doc.richtext"
        case .provision: return "checkmark.seal"
        case .quickLook: return "eye"
        }
    }
}
