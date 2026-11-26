import Foundation
import UIKit

/// Reads compiled asset catalogs (Assets.car) through Apple's private CoreUI framework.
/// This is read-only: compiled .car files can't be rebuilt on device.
final class AssetCatalog {
    struct Rendition: Identifiable {
        let id = UUID()
        let image: UIImage
        let scale: CGFloat
        let pixelSize: CGSize
        let detail: String
    }

    private let catalog: NSObject

    init(url: URL) throws {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)
        guard let cls: AnyClass = NSClassFromString("CUICatalog") else {
            throw SimpleError("CoreUI isn't available on this system.")
        }
        // Class objects are Objective-C objects; this lets us send +alloc.
        let classObject = unsafeBitCast(cls, to: NSObject.self)
        let initSel = NSSelectorFromString("initWithURL:error:")
        guard let allocated = classObject.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              allocated.responds(to: initSel),
              let obj = allocated.perform(initSel, with: url as NSURL, with: nil)?.takeUnretainedValue() as? NSObject
        else {
            throw SimpleError("This Assets.car couldn't be opened.")
        }
        catalog = obj
    }

    lazy var imageNames: [String] = {
        let sel = NSSelectorFromString("allImageNames")
        guard self.catalog.responds(to: sel),
              let names = self.catalog.perform(sel)?.takeUnretainedValue() as? [String] else { return [] }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    func renditions(named name: String) -> [Rendition] {
        let sel = NSSelectorFromString("imagesWithName:")
        guard catalog.responds(to: sel),
              let objects = catalog.perform(sel, with: name)?.takeUnretainedValue() as? [NSObject] else { return [] }
        var result: [Rendition] = []
        let imageSel = NSSelectorFromString("image")
        for obj in objects where obj.responds(to: imageSel) {
            guard let raw = obj.perform(imageSel)?.takeUnretainedValue() else { continue }
            guard CFGetTypeID(raw as CFTypeRef) == CGImage.typeID else { continue }
            let cg = unsafeBitCast(raw, to: CGImage.self)
            let scale = obj.responds(to: NSSelectorFromString("scale")) ? ((obj.value(forKey: "scale") as? CGFloat) ?? 1) : 1
            var parts = ["@\(Int(scale))x", "\(cg.width)×\(cg.height)"]
            if obj.responds(to: NSSelectorFromString("idiom")), let idiom = obj.value(forKey: "idiom") as? Int {
                let names = [0: "universal", 1: "iPhone", 2: "iPad", 3: "TV", 4: "CarPlay", 5: "Watch", 6: "Marketing"]
                parts.append(names[idiom] ?? "idiom \(idiom)")
            }
            if obj.responds(to: NSSelectorFromString("appearance")), let appearance = obj.value(forKey: "appearance") as? String,
               !appearance.isEmpty {
                parts.append(appearance)
            }
            let img = UIImage(cgImage: cg, scale: max(scale, 1), orientation: .up)
            result.append(Rendition(image: img, scale: scale, pixelSize: CGSize(width: cg.width, height: cg.height),
                                    detail: parts.joined(separator: " · ")))
        }
        return result.sorted { $0.pixelSize.width > $1.pixelSize.width }
    }

    func bestImage(named name: String) -> UIImage? {
        renditions(named: name).first?.image
    }

    /// Writes every image rendition as PNG into `folder`. Returns the number written.
    func exportAll(to folder: URL, progress: (Double) -> Void) throws -> Int {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = 0
        let names = imageNames
        for (i, name) in names.enumerated() {
            let safe = name.replacingOccurrences(of: "/", with: "_")
            for (j, r) in renditions(named: name).enumerated() {
                let suffix = j == 0 ? "" : "-\(j)"
                let file = folder.appendingPathComponent("\(safe)@\(Int(max(r.scale, 1)))x\(suffix).png")
                if let png = r.image.pngData() {
                    try png.write(to: file)
                    written += 1
                }
            }
            progress(Double(i + 1) / Double(max(names.count, 1)))
        }
        return written
    }
}
