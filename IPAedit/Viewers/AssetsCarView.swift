import SwiftUI

struct AssetsCarView: View {
    let url: URL
    @State private var catalog: AssetCatalog?
    @State private var names: [String] = []
    @State private var error: String?
    @State private var query = ""
    @State private var selected: SelectedAsset?
    @State private var exportMessage: String?
    @State private var exporting = false

    struct SelectedAsset: Identifiable { let name: String; var id: String { name } }

    private var filtered: [String] {
        query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if let error = error {
                ViewerError(message: error)
            } else if let catalog = catalog {
                ScrollView {
                    Text("\(names.count) images · read-only (compiled catalogs can't be rebuilt on device)")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 14) {
                        ForEach(filtered, id: \.self) { name in
                            Button { selected = SelectedAsset(name: name) } label: {
                                AssetThumb(catalog: catalog, name: name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
                .searchable(text: $query, prompt: "Search assets")
            } else {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { exportAll() } label: { Label("Export all", systemImage: "square.and.arrow.down.on.square") }
                    .disabled(catalog == nil || exporting)
            }
        }
        .overlay { if exporting { ProgressView("Exporting…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .alert("Export finished", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportMessage ?? "") }
        .sheet(item: $selected) { item in
            if let catalog = catalog { AssetDetail(catalog: catalog, name: item.name) }
        }
        .task {
            guard catalog == nil else { return }
            let u = url
            do {
                let c = try await Task.detached { try AssetCatalog(url: u) }.value
                let n = await Task.detached { c.imageNames }.value
                catalog = c
                names = n
                if n.isEmpty { error = "No images found in this catalog (it may hold only colours or data)." }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func exportAll() {
        guard let catalog = catalog else { return }
        exporting = true
        let base = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let folder = WorkspaceStore.exportsDir.appendingPathComponent("\(base)-Assets", isDirectory: true)
        Task.detached {
            let result = Result { try catalog.exportAll(to: folder) { _ in } }
            await MainActor.run {
                exporting = false
                switch result {
                case .success(let n): exportMessage = "Saved \(n) PNGs to Files › IPAedit › Exports › \(folder.lastPathComponent)."
                case .failure(let e): exportMessage = e.localizedDescription
                }
            }
        }
    }
}

private struct AssetThumb: View {
    let catalog: AssetCatalog
    let name: String
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFit().padding(6)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(height: 84)
            Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
        }
        .task {
            let c = catalog, n = name
            image = await Task.detached { c.renditions(named: n).last?.image ?? c.bestImage(named: n) }.value
        }
    }
}

private struct AssetDetail: View {
    let catalog: AssetCatalog
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var renditions: [AssetCatalog.Rendition] = []
    @State private var sharing: [Any]?

    var body: some View {
        NavigationStack {
            List {
                ForEach(renditions) { r in
                    HStack(spacing: 12) {
                        Image(uiImage: r.image).resizable().scaledToFit().frame(width: 72, height: 72)
                            .background(Checkerboard())
                        VStack(alignment: .leading) {
                            Text(r.detail).font(.subheadline)
                        }
                        Spacer()
                        Button {
                            if let png = r.image.pngData() {
                                let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "_"))@\(Int(max(r.scale, 1)))x.png")
                                try? png.write(to: file)
                                sharing = [file]
                            }
                        } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                    }
                }
                if renditions.isEmpty { Text("No bitmap renditions.").foregroundStyle(.secondary) }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { renditions = catalog.renditions(named: name) }
            .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
                ShareSheet(items: sharing ?? [])
            }
        }
    }
}
