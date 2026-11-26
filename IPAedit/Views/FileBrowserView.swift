import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let modified: Date?
    let kind: FileKind
    var id: URL { url }

    static func == (a: FileItem, b: FileItem) -> Bool { a.url == b.url && a.size == b.size && a.modified == b.modified }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum SortMode: String, CaseIterable, Identifiable {
    case name = "Name", size = "Size", date = "Date", kind = "Kind"
    var id: String { rawValue }
}

struct FileBrowserView: View {
    let directory: URL
    @EnvironmentObject var nav: Navigator
    @EnvironmentObject var store: WorkspaceStore
    @State private var items: [FileItem] = []
    @State private var loading = true
    @State private var query = ""
    @AppStorage("sortMode") private var sortRaw = SortMode.name.rawValue

    @State private var renaming: FileItem?
    @State private var renameText = ""
    @State private var deleting: FileItem?
    @State private var creatingFile = false
    @State private var creatingFolder = false
    @State private var newName = ""
    @State private var importing = false
    @State private var sharing: IdentifiableURL?
    @State private var infoItem: FileItem?
    @State private var errorText: String?

    private var sortMode: SortMode { SortMode(rawValue: sortRaw) ?? .name }

    private var visible: [FileItem] {
        let filtered = query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch sortMode {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: return a.size > b.size
            case .date: return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            case .kind:
                let ea = (a.name as NSString).pathExtension, eb = (b.name as NSString).pathExtension
                return ea == eb ? a.name.localizedStandardCompare(b.name) == .orderedAscending : ea < eb
            }
        }
    }

    var body: some View {
        List {
            ForEach(visible) { item in
                NavigationLink(value: route(for: item)) {
                    FileRow(item: item)
                }
                .contextMenu { menu(for: item) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
                    Button { startRename(item) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                }
            }
            if !loading && items.isEmpty {
                Text("Empty folder").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .overlay { if loading { ProgressView() } }
        .searchable(text: $query, prompt: "Filter this folder")
        .navigationTitle(directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { newName = "untitled.txt"; creatingFile = true } label: { Label("New File", systemImage: "doc.badge.plus") }
                    Button { newName = "New Folder"; creatingFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    Button { importing = true } label: { Label("Import Files Here", systemImage: "square.and.arrow.down") }
                    Divider()
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(SortMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let item = renaming { rename(item, to: renameText) } }
        }
        .alert("New File", isPresented: $creatingFile) {
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create(folder: false) }
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create(folder: true) }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deleting { delete(item) } }
        } message: {
            Text("This can't be undone.")
        }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .sheet(item: $infoItem, onDismiss: { Task { await reload() } }) { FileInfoSheet(item: $0) }
    }

    private func route(for item: FileItem) -> Route {
        item.isDirectory ? .folder(item.url) : .file(item.url, item.kind.defaultViewer)
    }

    @ViewBuilder
    private func menu(for item: FileItem) -> some View {
        if !item.isDirectory {
            Menu {
                ForEach(Viewer.allCases) { v in
                    Button { nav.push(.file(item.url, v)) } label: { Label(v.title, systemImage: v.symbol) }
                }
            } label: { Label("Open With", systemImage: "arrow.up.forward.app") }
        }
        if ["ipa", "tipa"].contains(item.url.pathExtension.lowercased()) {
            Button {
                nav.path = NavigationPath()
                store.importIPA(from: item.url)
            } label: { Label("Open as new workspace", systemImage: "shippingbox") }
        }
        Button { startRename(item) } label: { Label("Rename", systemImage: "pencil") }
        Button { duplicate(item) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if !item.isDirectory {
            Button { sharing = IdentifiableURL(url: item.url) } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
        }
        Button { UIPasteboard.general.string = item.name } label: { Label("Copy Name", systemImage: "doc.on.doc") }
        Button { infoItem = item } label: { Label("Info & Permissions", systemImage: "info.circle") }
        Divider()
        Button(role: .destructive) { deleting = item } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Actions

    private func reload() async {
        let dir = directory
        let loaded: [FileItem] = await Task.detached { () -> [FileItem] in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            return urls.map { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                let isDir = v?.isDirectory ?? false
                return FileItem(url: url, name: url.lastPathComponent, isDirectory: isDir,
                                isSymlink: v?.isSymbolicLink ?? false,
                                size: UInt64(v?.fileSize ?? 0), modified: v?.contentModificationDate,
                                kind: FileKind.detect(url, isDirectory: isDir))
            }
        }.value
        items = loaded
        loading = false
    }

    private func refresh() { Task { await reload() } }

    private func startRename(_ item: FileItem) {
        renameText = item.name
        renaming = item
    }

    private func rename(_ item: FileItem, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains("/"), clean != item.name else { return }
        do {
            try FileManager.default.moveItem(at: item.url, to: directory.appendingPathComponent(clean))
        } catch { errorText = error.localizedDescription }
        refresh()
    }

    private func duplicate(_ item: FileItem) {
        let base = (item.name as NSString).deletingPathExtension
        let ext = (item.name as NSString).pathExtension
        var n = 1
        var target: URL
        repeat {
            let name = n == 1 ? "\(base) copy" : "\(base) copy \(n)"
            target = directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            n += 1
        } while FileManager.default.fileExists(atPath: target.path)
        do { try FileManager.default.copyItem(at: item.url, to: target) } catch { errorText = error.localizedDescription }
        refresh()
    }

    private func delete(_ item: FileItem) {
        do { try FileManager.default.removeItem(at: item.url) } catch { errorText = error.localizedDescription }
        deleting = nil
        refresh()
    }

    private func create(folder: Bool) {
        let clean = newName.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !clean.contains("/") else { return }
        let url = directory.appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            errorText = "\(clean) already exists."
            return
        }
        do {
            if folder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        } catch { errorText = error.localizedDescription }
        refresh()
    }

    /// Copies picked files into this folder, replacing files with the same name.
    private func importFiles(_ urls: [URL]) {
        var failures: [String] = []
        for src in urls {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let dest = directory.appendingPathComponent(src.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
            } catch {
                failures.append("\(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { errorText = failures.joined(separator: "\n") }
        refresh()
    }
}

struct FileRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if item.isSymlink { parts.append("Symlink") }
        parts.append(item.isDirectory ? "Folder" : ByteFormat.size(item.size))
        if let d = item.modified { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private var color: Color {
        switch item.kind {
        case .folder: return .blue
        case .appBundle: return .indigo
        case .image: return .pink
        case .plist: return .orange
        case .text: return .gray
        case .machO: return .red
        case .assetsCar: return .purple
        case .audio, .video: return .teal
        case .pdf: return .red
        case .provision: return .green
        case .archive: return .brown
        case .binary: return .secondary
        }
    }
}

struct FileInfoSheet: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var permissions = ""
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Size", value: item.isDirectory ? folderSize : ByteFormat.size(item.size))
                    if let d = item.modified { LabeledContent("Modified", value: d.formatted()) }
                    if item.isSymlink, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path) {
                        LabeledContent("Links to", value: dest)
                    }
                }
                Section {
                    TextField("Octal, e.g. 755", text: $permissions)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                    Button("Make executable (755)") { permissions = "755"; apply() }
                    Button("Apply") { apply() }
                } header: {
                    Text("Unix permissions")
                } footer: {
                    Text("Main app binaries and helper tools need the executable bit (755).")
                }
                if let message = message { Section { Text(message) } }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear {
                if let p = (try? FileManager.default.attributesOfItem(atPath: item.url.path))?[.posixPermissions] as? NSNumber {
                    permissions = String(p.intValue, radix: 8)
                }
            }
        }
    }

    private var folderSize: String {
        var total: UInt64 = 0
        if let e = FileManager.default.enumerator(at: item.url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return ByteFormat.size(total)
    }

    private func apply() {
        guard let value = Int(permissions, radix: 8), value >= 0, value <= 0o7777 else {
            message = "Enter an octal value like 644 or 755."
            return
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: value)], ofItemAtPath: item.url.path)
            message = "Permissions set to \(String(value, radix: 8))."
        } catch {
            message = error.localizedDescription
        }
    }
}
