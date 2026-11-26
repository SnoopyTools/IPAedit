import SwiftUI

struct WorkspaceView: View {
    let workspaceID: UUID
    @EnvironmentObject var store: WorkspaceStore
    @EnvironmentObject var nav: Navigator
    @State private var showExport = false
    @State private var showQuickEdit = false
    @State private var confirmDelete = false

    var body: some View {
        if let ws = store.workspace(id: workspaceID) {
            content(ws)
        } else {
            Text("This workspace no longer exists.").foregroundStyle(.secondary)
        }
    }

    private func content(_ ws: Workspace) -> some View {
        let fm = FileManager.default
        let app = ws.appURL
        let info = ws.infoPlistURL.flatMap { IPAPackager.readPlist($0) }
        let executable = (info?["CFBundleExecutable"] as? String).flatMap { name in app?.appendingPathComponent(name) }
        let car = app?.appendingPathComponent("Assets.car")
        let profile = app?.appendingPathComponent("embedded.mobileprovision")
        let frameworks = app?.appendingPathComponent("Frameworks", isDirectory: true)
        let plugins = app?.appendingPathComponent("PlugIns", isDirectory: true)
        func exists(_ url: URL?) -> URL? { url.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } }

        return List {
            Section {
                HStack(spacing: 14) {
                    WorkspaceIconView(workspace: ws, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ws.displayName).font(.title3.bold())
                        if let b = ws.bundleID { Text(b).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                        if let v = ws.version, !v.isEmpty { Text("Version \(v)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Browse") {
                NavigationLink(value: Route.folder(ws.root)) {
                    Label("IPA contents", systemImage: "shippingbox")
                }
                if let app = app {
                    NavigationLink(value: Route.folder(app)) {
                        Label(app.lastPathComponent, systemImage: "app.badge")
                    }
                }
                if let f = exists(frameworks) {
                    NavigationLink(value: Route.folder(f)) { Label("Frameworks", systemImage: "building.columns") }
                }
                if let p = exists(plugins) {
                    NavigationLink(value: Route.folder(p)) { Label("PlugIns (extensions)", systemImage: "puzzlepiece.extension") }
                }
                NavigationLink(value: Route.search(ws.id)) {
                    Label("Search files", systemImage: "magnifyingglass")
                }
            }

            Section("Tools") {
                if let info = exists(ws.infoPlistURL) {
                    NavigationLink(value: Route.file(info, .plist)) { Label("Info.plist", systemImage: "list.bullet.rectangle") }
                    Button { showQuickEdit = true } label: { Label("Name, bundle ID & version", systemImage: "square.and.pencil") }
                }
                if let exe = exists(executable) {
                    NavigationLink(value: Route.file(exe, .machO)) { Label("Main executable (\(exe.lastPathComponent))", systemImage: "cpu") }
                }
                if let car = exists(car) {
                    NavigationLink(value: Route.file(car, .assets)) { Label("Assets.car", systemImage: "square.stack.3d.up") }
                }
                if let profile = exists(profile) {
                    NavigationLink(value: Route.file(profile, .provision)) { Label("Provisioning profile", systemImage: "checkmark.seal") }
                }
            }

            Section {
                Button { showExport = true } label: {
                    Label("Build IPA", systemImage: "hammer.fill").font(.headline)
                }
            } footer: {
                Text("Packs everything back into a new .ipa with your edits.")
            }

            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete workspace", systemImage: "trash")
                }
            }
        }
        .navigationTitle(ws.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) { ExportSheet(workspace: ws) }
        .sheet(isPresented: $showQuickEdit) { QuickEditSheet(workspace: ws) }
        .confirmationDialog("Delete \(ws.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(ws)
                nav.path = NavigationPath()
            }
        } message: {
            Text("Removes the extracted files and any unsaved edits.")
        }
    }
}

struct ExportSheet: View {
    let workspace: Workspace
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("compressExport") private var compress = true
    @State private var fileName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("File name") {
                    TextField("Name", text: $fileName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Toggle("Compress (smaller, slower)", isOn: $compress)
                } footer: {
                    Text("Edited apps lose their original signature. Re-sign when installing (LiveContainer, Sideloadly, AltStore, etc.).")
                }
            }
            .navigationTitle("Build IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Build") {
                        let name = fileName.trimmingCharacters(in: .whitespaces)
                        store.exportIPA(workspace, compress: compress, fileName: name.isEmpty ? workspace.name : name)
                        dismiss()
                    }
                }
            }
            .onAppear { if fileName.isEmpty { fileName = "\(workspace.name)-edited.ipa" } }
        }
        .presentationDetents([.medium])
    }
}

struct QuickEditSheet: View {
    let workspace: Workspace
    @EnvironmentObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var bundleName = ""
    @State private var bundleID = ""
    @State private var version = ""
    @State private var build = ""
    @State private var minOS = ""
    @State private var fileSharing = false
    @State private var removeDeviceLimits = false
    @State private var hasDeviceLimits = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    field("Display name", $displayName)
                    field("Bundle name", $bundleName)
                    field("Bundle ID", $bundleID)
                }
                Section("Version") {
                    field("Version", $version)
                    field("Build", $build)
                    field("Minimum iOS", $minOS)
                }
                Section("Patches") {
                    Toggle("Show documents in Files app", isOn: $fileSharing)
                    if hasDeviceLimits {
                        Toggle("Remove device restrictions", isOn: $removeDeviceLimits)
                    }
                }
                if let error = error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("App details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear(perform: load)
        }
    }

    private func field(_ title: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: binding)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(.secondary)
        }
    }

    private func load() {
        guard let url = workspace.infoPlistURL, let info = IPAPackager.readPlist(url) else { return }
        displayName = info["CFBundleDisplayName"] as? String ?? ""
        bundleName = info["CFBundleName"] as? String ?? ""
        bundleID = info["CFBundleIdentifier"] as? String ?? ""
        version = info["CFBundleShortVersionString"] as? String ?? ""
        build = info["CFBundleVersion"] as? String ?? ""
        minOS = info["MinimumOSVersion"] as? String ?? ""
        fileSharing = (info["UIFileSharingEnabled"] as? Bool ?? false) && (info["LSSupportsOpeningDocumentsInPlace"] as? Bool ?? false)
        hasDeviceLimits = info["UISupportedDevices"] != nil
    }

    private func save() {
        guard let url = workspace.infoPlistURL else { return }
        do {
            let data = try Data(contentsOf: url)
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
                throw SimpleError("Info.plist isn't a dictionary.")
            }
            func set(_ key: String, _ value: String) {
                if value.isEmpty { info.removeValue(forKey: key) } else { info[key] = value }
            }
            set("CFBundleDisplayName", displayName)
            set("CFBundleName", bundleName)
            set("CFBundleIdentifier", bundleID)
            set("CFBundleShortVersionString", version)
            set("CFBundleVersion", build)
            set("MinimumOSVersion", minOS)
            if fileSharing {
                info["UIFileSharingEnabled"] = true
                info["LSSupportsOpeningDocumentsInPlace"] = true
            } else {
                info.removeValue(forKey: "UIFileSharingEnabled")
            }
            if removeDeviceLimits { info.removeValue(forKey: "UISupportedDevices") }
            let out = try PropertyListSerialization.data(fromPropertyList: info,
                                                         format: format == .openStep ? .xml : format, options: 0)
            try out.write(to: url)
            store.refreshMetadata(workspace)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
