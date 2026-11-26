import SwiftUI
import PhotosUI
import UIKit

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.minimumZoomScale = 0.1
        sv.maximumZoomScale = 20
        sv.delegate = context.coordinator
        sv.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.layer.magnificationFilter = .nearest
        sv.addSubview(iv)
        context.coordinator.imageView = iv
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        guard let iv = context.coordinator.imageView else { return }
        if iv.image !== image {
            iv.image = image
            context.coordinator.fitted = false
        }
        DispatchQueue.main.async { context.coordinator.fit(in: sv) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var fitted = false

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func fit(in sv: UIScrollView) {
            guard !fitted, let iv = imageView, let img = iv.image, sv.bounds.width > 0 else { return }
            fitted = true
            iv.frame = CGRect(origin: .zero, size: img.size)
            sv.contentSize = img.size
            let scale = min(sv.bounds.width / max(img.size.width, 1), sv.bounds.height / max(img.size.height, 1), 4)
            sv.zoomScale = scale
            center(sv)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { center(scrollView) }

        private func center(_ sv: UIScrollView) {
            guard let iv = imageView else { return }
            let dx = max(0, (sv.bounds.width - iv.frame.width) / 2)
            let dy = max(0, (sv.bounds.height - iv.frame.height) / 2)
            sv.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        }
    }
}

struct ImageViewer: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var status: String?
    @State private var checker = false

    var body: some View {
        Group {
            if let image = image {
                ZoomableImage(image: image)
                    .background(checker ? AnyView(Checkerboard()) : AnyView(Color(.systemBackground)))
            } else if failed {
                ViewerError(message: "This image couldn't be decoded.")
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let image = image {
                Text(status ?? "\(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale)) px · \(fileSize)")
                    .font(.caption).padding(6).frame(maxWidth: .infinity).background(.thinMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Replace from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { importing = true } label: { Label("Replace from Files", systemImage: "folder") }
                    Toggle("Checkerboard background", isOn: $checker)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case .success(let picked) = result else { return }
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: picked) { replace(with: data) }
        }
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    replace(with: data)
                }
                photoItem = nil
            }
        }
        .onAppear(perform: load)
    }

    private var fileSize: String {
        ByteFormat.size(((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0)
    }

    private func load() {
        if let img = UIImage(contentsOfFile: url.path) {
            image = img
        } else {
            failed = true
        }
    }

    /// Re-encodes the picked image into this file's format so names and types stay valid.
    private func replace(with data: Data) {
        guard let newImage = UIImage(data: data) else {
            status = "That image couldn't be read."
            return
        }
        let ext = url.pathExtension.lowercased()
        let out: Data?
        switch ext {
        case "jpg", "jpeg": out = newImage.jpegData(compressionQuality: 0.95)
        case "png": out = newImage.pngData()
        default: out = data
        }
        guard let bytes = out else { status = "Couldn't encode the image."; return }
        do {
            try bytes.write(to: url)
            image = UIImage(data: bytes) ?? newImage
            failed = false
            status = "Replaced (\(ByteFormat.size(bytes.count)))"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
    }
}
