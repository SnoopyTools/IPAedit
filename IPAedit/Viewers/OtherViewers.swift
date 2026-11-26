import SwiftUI
import AVKit
import PDFKit
import QuickLook

struct MediaPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
    }
}

struct PDFViewer: View {
    let url: URL
    var body: some View {
        if let doc = PDFDocument(url: url) {
            PDFKitView(document: doc)
        } else {
            ViewerError(message: "This isn't a readable PDF.")
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = document
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {}
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// Embedded provisioning profiles are CMS-signed plists; this pulls the plist out.
struct ProvisionView: View {
    let url: URL
    @EnvironmentObject var nav: Navigator
    @State private var info: [String: Any]?
    @State private var xml = ""
    @State private var failed = false

    var body: some View {
        Group {
            if let info = info {
                List {
                    Section("Profile") {
                        row("Name", info["Name"])
                        row("App ID name", info["AppIDName"])
                        row("Team", info["TeamName"])
                        row("Team ID", (info["TeamIdentifier"] as? [String])?.joined(separator: ", "))
                        row("UUID", info["UUID"])
                        row("Created", (info["CreationDate"] as? Date)?.formatted())
                        row("Expires", (info["ExpirationDate"] as? Date)?.formatted())
                        if let exp = info["ExpirationDate"] as? Date {
                            Text(exp < Date() ? "Expired" : "Valid for \(Int(exp.timeIntervalSinceNow / 86400)) more days")
                                .foregroundStyle(exp < Date() ? Color.red : Color.green)
                        }
                        row("Devices", (info["ProvisionedDevices"] as? [String]).map { "\($0.count)" }
                            ?? ((info["ProvisionsAllDevices"] as? Bool) == true ? "All (enterprise)" : "—"))
                    }
                    if let ent = info["Entitlements"] as? [String: Any] {
                        Section("Entitlements") {
                            ForEach(ent.keys.sorted(), id: \.self) { k in
                                VStack(alignment: .leading) {
                                    Text(k).font(.caption.bold())
                                    Text(String(describing: ent[k]!)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Button { nav.push(.text(title: "Profile XML", body: xml)) } label: {
                            Label("View raw XML", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                }
            } else if failed {
                ViewerError(message: "No profile data found in this file.")
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: load)
    }

    private func row(_ title: String, _ value: Any?) -> some View {
        LabeledContent(title) {
            Text(value.map { String(describing: $0) } ?? "—").textSelection(.enabled)
        }
    }

    private func load() {
        guard info == nil, let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            failed = true
            return
        }
        let slice = data[start.lowerBound..<end.upperBound]
        xml = String(decoding: slice, as: UTF8.self)
        info = (try? PropertyListSerialization.propertyList(from: Data(slice), format: nil)) as? [String: Any]
        if info == nil { failed = true }
    }
}

struct SearchView: View {
    let workspace: Workspace
    @State private var query = ""
    @State private var searchContents = false
    @State private var results: [URL] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                TextField("File name or text", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(run)
                Toggle("Also search inside text files", isOn: $searchContents)
                Button(action: run) {
                    HStack {
                        Text("Search")
                        if searching { Spacer(); ProgressView() }
                    }
                }
                .disabled(query.isEmpty)
            }
            if !results.isEmpty {
                Section("\(results.count) result\(results.count == 1 ? "" : "s")") {
                    ForEach(results, id: \.self) { url in
                        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        let kind = FileKind.detect(url, isDirectory: isDir)
                        NavigationLink(value: isDir ? Route.folder(url) : Route.file(url, kind.defaultViewer)) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                    Text(url.deletingLastPathComponent().relativePath(from: workspace.root))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                }
                            } icon: { Image(systemName: kind.symbol) }
                        }
                    }
                }
            } else if !searching && !query.isEmpty {
                Text("No results yet.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { searchTask?.cancel() }
    }

    private func run() {
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        searching = true
        results = []
        let q = query.lowercased(), root = workspace.root, contents = searchContents
        searchTask = Task {
            let found = await Task.detached { SearchView.search(q, in: root, contents: contents) }.value
            if !Task.isCancelled {
                results = found
                searching = false
            }
        }
    }

    nonisolated static func search(_ q: String, in root: URL, contents: Bool) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return [] }
        let needle = Data(q.utf8)
        for case let url as URL in e {
            if out.count >= 1000 { break }
            if url.lastPathComponent.lowercased().contains(q) {
                out.append(url)
                continue
            }
            guard contents else { continue }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true || (v?.fileSize ?? 0) > 5 * 1024 * 1024 { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.range(of: needle) != nil {
                out.append(url)
            } else if FileKind.looksLikeText(data.prefix(512)),
                      let s = String(data: data, encoding: .utf8), s.lowercased().contains(q) {
                out.append(url)
            }
        }
        return out
    }
}
