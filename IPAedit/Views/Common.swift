import SwiftUI
import UIKit

struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct BusyOverlay: View {
    let info: BusyInfo
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(info.title).font(.headline).multilineTextAlignment(.center)
                ProgressView(value: min(max(info.progress, 0), 1))
                    .frame(width: 220)
                Text("\(Int(info.progress * 100))%").font(.caption.monospacedDigit())
                Text(info.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: 240)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

struct WorkspaceIconView: View {
    let workspace: Workspace
    var size: CGFloat = 52
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "shippingbox.fill").foregroundStyle(.white).font(.system(size: size * 0.42))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .task(id: workspace.iconRelativePath) { await load() }
    }

    private func load() async {
        let ws = workspace
        let loaded: UIImage? = await Task.detached { () -> UIImage? in
            if let url = ws.iconURL, let img = UIImage(contentsOfFile: url.path) { return img }
            guard let app = ws.appURL else { return nil }
            let car = app.appendingPathComponent("Assets.car")
            guard FileManager.default.fileExists(atPath: car.path),
                  let catalog = try? AssetCatalog(url: car) else { return nil }
            for name in [ws.iconName, "AppIcon"].compactMap({ $0 }) {
                if let img = catalog.bestImage(named: name) { return img }
            }
            return nil
        }.value
        image = loaded
    }
}

/// A read-only, selectable, monospaced text page.
struct ReadOnlyTextView: View {
    let title: String
    let text: String
    var body: some View {
        CodeTextView(text: .constant(text), editable: false, controller: TextViewController())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                }
            }
    }
}

extension URL {
    func relativePath(from root: URL) -> String {
        let a = standardizedFileURL.pathComponents
        let b = root.standardizedFileURL.pathComponents
        if a.count >= b.count, Array(a.prefix(b.count)) == b {
            let rest = a.dropFirst(b.count)
            return rest.isEmpty ? "/" : rest.joined(separator: "/")
        }
        return lastPathComponent
    }
}
