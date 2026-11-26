import Foundation
import SwiftUI

struct Workspace: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var created: Date
    var appName: String?
    var bundleID: String?
    var version: String?
    var appRelativePath: String?
    var iconRelativePath: String?
    var iconName: String?

    var folder: URL { WorkspaceStore.workspacesDir.appendingPathComponent(id.uuidString, isDirectory: true) }
    var root: URL { folder.appendingPathComponent("root", isDirectory: true) }
    var appURL: URL? { appRelativePath.map { root.appendingPathComponent($0, isDirectory: true) } }
    var iconURL: URL? { iconRelativePath.map { root.appendingPathComponent($0) } }
    var infoPlistURL: URL? { appURL?.appendingPathComponent("Info.plist") }
    var displayName: String { appName ?? name }
}

struct BusyInfo {
    var title: String
    var detail: String = ""
    var progress: Double = 0
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var busy: BusyInfo?
    @Published var errorMessage: String?
    @Published var lastExport: URL?

    nonisolated static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    nonisolated static var workspacesDir: URL { documents.appendingPathComponent("Workspaces", isDirectory: true) }
    nonisolated static var exportsDir: URL { documents.appendingPathComponent("Exports", isDirectory: true) }

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.workspacesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.exportsDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.workspacesDir, includingPropertiesForKeys: nil)) ?? []
        var list: [Workspace] = []
        for dir in dirs {
            let meta = dir.appendingPathComponent("workspace.json")
            if let data = try? Data(contentsOf: meta), let ws = try? JSONDecoder().decode(Workspace.self, from: data) {
                list.append(ws)
            }
        }
        workspaces = list.sorted { $0.created > $1.created }
    }

    private func save(_ ws: Workspace) {
        let meta = ws.folder.appendingPathComponent("workspace.json")
        if let data = try? JSONEncoder().encode(ws) {
            try? data.write(to: meta, options: .atomic)
        }
    }

    func workspace(id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    // MARK: Import

    func importIPA(from url: URL) {
        guard busy == nil else { return }
        let name = url.deletingPathExtension().lastPathComponent
        busy = BusyInfo(title: "Opening \(url.lastPathComponent)")

        let id = UUID()
        let base = Workspace(id: id, name: name, created: Date())
        let root = base.root
        let folder = base.folder

        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try IPAPackager.extract(ipa: url, to: root) { fraction, detail in
                    Task { @MainActor in
                        self.busy?.progress = fraction
                        self.busy?.detail = detail
                    }
                }
                var meta = base
                IPAPackager.fillMetadata(&meta)
                if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
                let finished = meta
                await MainActor.run {
                    self.save(finished)
                    self.workspaces.insert(finished, at: 0)
                    self.busy = nil
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                await MainActor.run {
                    self.busy = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Maintenance

    func delete(_ ws: Workspace) {
        try? FileManager.default.removeItem(at: ws.folder)
        workspaces.removeAll { $0.id == ws.id }
    }

    func rename(_ ws: Workspace, to newName: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        workspaces[i].name = newName
        save(workspaces[i])
    }

    /// Re-reads Info.plist (after edits) to refresh name, bundle id, icon.
    func refreshMetadata(_ ws: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        var updated = workspaces[i]
        IPAPackager.fillMetadata(&updated)
        workspaces[i] = updated
        save(updated)
    }

    // MARK: Export

    func exportIPA(_ ws: Workspace, compress: Bool, fileName: String) {
        guard busy == nil else { return }
        busy = BusyInfo(title: "Building \(fileName)")
        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let out = Self.exportsDir.appendingPathComponent(safe.hasSuffix(".ipa") ? safe : safe + ".ipa")
        let root = ws.root

        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: Self.exportsDir, withIntermediateDirectories: true)
                try IPAPackager.pack(root: root, to: out, compress: compress) { fraction, detail in
                    Task { @MainActor in
                        self.busy?.progress = fraction
                        self.busy?.detail = detail
                    }
                }
                await MainActor.run {
                    self.busy = nil
                    self.lastExport = out
                }
            } catch {
                try? FileManager.default.removeItem(at: out)
                await MainActor.run {
                    self.busy = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// Extraction / packing logic, independent of the UI.
enum IPAPackager {
    /// Turns a zip entry path into a safe relative path (no "..", no absolute paths).
    static func sanitize(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        if parts.isEmpty || parts.contains("..") { return nil }
        return parts.joined(separator: "/")
    }

    static func extract(ipa: URL, to root: URL, report: @escaping (Double, String) -> Void) throws {
        let fm = FileManager.default
        let reader = try ZipReader(url: ipa)
        let entries = try reader.entries()
        guard !entries.isEmpty else { throw SimpleError("The archive is empty.") }
        let total = max(1, entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize })
        let rootPath = root.resolvingSymlinksInPath().path
        var done: UInt64 = 0
        var lastReport = Date.distantPast

        func tick(_ name: String) {
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.08 {
                lastReport = now
                report(Double(done) / Double(total), name)
            }
        }

        for entry in entries {
            guard let rel = sanitize(entry.path) else { continue }
            let dest = root.appendingPathComponent(rel)

            if entry.isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            let parent = dest.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // Refuse to write through a symlink that points outside the workspace.
            guard parent.resolvingSymlinksInPath().path.hasPrefix(rootPath) else { continue }

            if entry.isSymlink {
                let target = String(decoding: try reader.data(for: entry), as: UTF8.self)
                try? fm.removeItem(at: dest)
                try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
                continue
            }

            try reader.extract(entry, to: dest) { n in
                done += UInt64(n)
                tick(rel)
            }
            let mode = entry.unixMode & 0o777
            if mode != 0 {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: mode | 0o600)], ofItemAtPath: dest.path)
            }
            tick(rel)
        }
        report(1, "Done")
    }

    private struct Item {
        var rel: String
        var url: URL
        var kind: FileAttributeType
        var size: UInt64
        var mode: UInt32
        var modified: Date
    }

    static func pack(root: URL, to out: URL, compress: Bool, report: @escaping (Double, String) -> Void) throws {
        let fm = FileManager.default
        var items: [Item] = []

        func walk(_ rel: String) throws {
            let dir = rel.isEmpty ? root : root.appendingPathComponent(rel)
            var names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
            if rel.isEmpty, let i = names.firstIndex(of: "Payload") {
                names.remove(at: i)
                names.insert("Payload", at: 0)
            }
            for name in names {
                let r = rel.isEmpty ? name : rel + "/" + name
                let url = root.appendingPathComponent(r)
                let attrs = try fm.attributesOfItem(atPath: url.path)
                let kind = (attrs[.type] as? FileAttributeType) ?? .typeRegular
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let mode = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
                let modified = (attrs[.modificationDate] as? Date) ?? Date()
                items.append(Item(rel: r, url: url, kind: kind, size: size, mode: mode, modified: modified))
                if kind == .typeDirectory { try walk(r) }
            }
        }
        try walk("")
        guard !items.isEmpty else { throw SimpleError("Nothing to pack.") }

        let total = max(1, items.reduce(UInt64(0)) { $0 + ($1.kind == .typeRegular ? $1.size : 0) })
        var done: UInt64 = 0
        var lastReport = Date.distantPast
        let writer = try ZipWriter(url: out, compress: compress)

        for item in items {
            switch item.kind {
            case .typeDirectory:
                try writer.addDirectory(path: item.rel, mode: item.mode, modified: item.modified)
            case .typeSymbolicLink:
                let target = try fm.destinationOfSymbolicLink(atPath: item.url.path)
                try writer.addSymlink(path: item.rel, target: target, modified: item.modified)
            case .typeRegular:
                try writer.addFile(path: item.rel, from: item.url, mode: item.mode, modified: item.modified) { n in
                    done += UInt64(n)
                    let now = Date()
                    if now.timeIntervalSince(lastReport) > 0.08 {
                        lastReport = now
                        report(Double(done) / Double(total), item.rel)
                    }
                }
            default:
                continue
            }
        }
        try writer.finish()
        report(1, "Done")
    }

    // MARK: Metadata

    static func readPlist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func fillMetadata(_ ws: inout Workspace) {
        let fm = FileManager.default
        let payload = ws.root.appendingPathComponent("Payload", isDirectory: true)
        let apps = ((try? fm.contentsOfDirectory(atPath: payload.path)) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        guard let appName = apps.first else { return }
        ws.appRelativePath = "Payload/" + appName
        let appURL = payload.appendingPathComponent(appName, isDirectory: true)
        guard let info = readPlist(appURL.appendingPathComponent("Info.plist")) else { return }

        ws.appName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        ws.bundleID = info["CFBundleIdentifier"] as? String
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        ws.version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")

        var iconNames: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                iconNames += (primary["CFBundleIconFiles"] as? [String]) ?? []
                if let n = primary["CFBundleIconName"] as? String { ws.iconName = n }
            }
        }
        iconNames += (info["CFBundleIconFiles"] as? [String]) ?? []
        if let f = info["CFBundleIconFile"] as? String { iconNames.append(f) }
        if ws.iconName == nil { ws.iconName = info["CFBundleIconName"] as? String }
        iconNames.append("AppIcon")
        let stems = iconNames.map { ($0 as NSString).deletingPathExtension }.filter { !$0.isEmpty }

        let files = (try? fm.contentsOfDirectory(atPath: appURL.path)) ?? []
        var best: (String, UInt64)?
        for f in files where f.lowercased().hasSuffix(".png") {
            guard stems.contains(where: { f.hasPrefix($0) }) else { continue }
            let size = ((try? fm.attributesOfItem(atPath: appURL.appendingPathComponent(f).path))?[.size] as? NSNumber)?.uint64Value ?? 0
            if best == nil || size > best!.1 { best = (f, size) }
        }
        ws.iconRelativePath = best.map { "Payload/\(appName)/\($0.0)" }
    }
}
