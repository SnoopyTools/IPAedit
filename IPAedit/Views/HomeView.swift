import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var nav: Navigator
    @State private var importing = false
    @State private var pendingDelete: Workspace?

    var body: some View {
        NavigationStack(path: $nav.path) {
            Group {
                if store.workspaces.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("IPAedit")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Open IPA", systemImage: "plus") }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink(value: Route.folder(WorkspaceStore.exportsDir)) {
                        Label("Exports", systemImage: "tray.full")
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: IPATypes.importable) { result in
            if case .success(let url) = result { store.importIPA(from: url) }
            if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
        }
        .overlay {
            if let busy = store.busy { BusyOverlay(info: busy) }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(item: Binding(
            get: { store.lastExport.map(IdentifiableURL.init) },
            set: { if $0 == nil { store.lastExport = nil } })) { item in
            ExportDoneSheet(url: item.url)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No IPAs open").font(.title2.bold())
            Text("Open an .ipa to browse, view and edit everything inside it, then rebuild it into a new IPA.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button { importing = true } label: {
                Label("Open IPA", systemImage: "folder.badge.plus").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var list: some View {
        List {
            ForEach(store.workspaces) { ws in
                NavigationLink(value: Route.workspace(ws.id)) {
                    HStack(spacing: 12) {
                        WorkspaceIconView(workspace: ws, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ws.displayName).font(.headline)
                            if let b = ws.bundleID { Text(b).font(.caption).foregroundStyle(.secondary) }
                            Text([ws.version, ws.name + ".ipa"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions {
                    Button(role: .destructive) { pendingDelete = ws } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .confirmationDialog("Delete this workspace?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible) {
            Button("Delete \(pendingDelete?.displayName ?? "")", role: .destructive) {
                if let ws = pendingDelete { store.delete(ws) }
                pendingDelete = nil
            }
        } message: {
            Text("The extracted files and any unsaved edits are removed. Exported IPAs are kept.")
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .workspace(let id):
            WorkspaceView(workspaceID: id)
        case .folder(let url):
            FileBrowserView(directory: url)
        case .file(let url, let viewer):
            FileViewerHost(url: url, initialViewer: viewer)
        case .search(let id):
            if let ws = store.workspace(id: id) { SearchView(workspace: ws) }
        case .text(let title, let body):
            ReadOnlyTextView(title: title, text: body)
        }
    }
}

struct ExportDoneSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("IPA built").font(.title2.bold())
                Text(url.lastPathComponent).font(.headline)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                Text(ByteFormat.size(size)).foregroundStyle(.secondary)
                Text("Saved in Files › On My iPhone › IPAedit › Exports. Edited apps need re-signing (LiveContainer, Sideloadly, etc. do this when installing).")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Button { sharing = true } label: { Label("Share / Save to Files", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $sharing) { ShareSheet(items: [url]) }
        }
        .presentationDetents([.medium, .large])
    }
}
