import SwiftUI
import UIKit

final class HexDocument: ObservableObject {
    let url: URL
    private var handle: FileHandle?
    private(set) var writable = false
    @Published private(set) var size: UInt64 = 0
    @Published private(set) var revision = 0
    @Published var loadError: String?
    private var cache: [UInt64: Data] = [:]
    private let pageSize: UInt64 = 64 * 1024

    init(url: URL) {
        self.url = url
        if let h = try? FileHandle(forUpdating: url) {
            handle = h
            writable = true
        } else if let h = try? FileHandle(forReadingFrom: url) {
            handle = h
        } else {
            loadError = "Couldn't open the file."
        }
        size = (try? handle?.seekToEnd()) ?? 0
    }

    deinit { try? handle?.close() }

    private func page(_ index: UInt64) -> Data {
        if let d = cache[index] { return d }
        guard let h = handle else { return Data() }
        if cache.count > 64 { cache.removeAll() }
        let d: Data
        do {
            try h.seek(toOffset: index * pageSize)
            d = try h.read(upToCount: Int(pageSize)) ?? Data()
        } catch {
            d = Data()
        }
        cache[index] = d
        return d
    }

    func bytes(at offset: UInt64, count: Int) -> Data {
        var out = Data()
        var off = offset
        var remaining = count
        while remaining > 0 && off < size {
            let index = off / pageSize
            let p = page(index)
            let inPage = Int(off - index * pageSize)
            let n = min(remaining, p.count - inPage)
            if n <= 0 { break }
            out.append(p.sub(inPage, n))
            off += UInt64(n)
            remaining -= n
        }
        return out
    }

    func line(row: Int, perRow: Int) -> String {
        let off = UInt64(row) * UInt64(perRow)
        let b = bytes(at: off, count: perRow)
        var hex = ""
        var ascii = ""
        for byte in b {
            hex += String(format: "%02X ", byte)
            ascii.append((0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "·")
        }
        if b.count < perRow { hex += String(repeating: "   ", count: perRow - b.count) }
        return String(format: "%08llX ", off) + hex + ascii
    }

    func write(_ data: Data, at offset: UInt64) throws {
        guard writable, let h = handle else { throw SimpleError("This file is read-only.") }
        try h.seek(toOffset: offset)
        try h.write(contentsOf: data)
        try h.synchronize()
        cache.removeAll()
        size = try h.seekToEnd()
        revision += 1
    }

    /// Searches from `start` (wrapping to the beginning). Uses its own file handle.
    static func find(_ pattern: Data, in url: URL, from start: UInt64) -> UInt64? {
        guard !pattern.isEmpty, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk = 1024 * 1024
        func scan(_ from: UInt64, _ to: UInt64) -> UInt64? {
            var pos = from
            while pos < to {
                guard (try? h.seek(toOffset: pos)) != nil,
                      let d = try? h.read(upToCount: chunk + pattern.count - 1), !d.isEmpty else { return nil }
                if let r = d.range(of: pattern) {
                    let found = pos + UInt64(r.lowerBound - d.startIndex)
                    return found < to ? found : nil
                }
                pos += UInt64(chunk)
            }
            return nil
        }
        return scan(min(start, size), size) ?? scan(0, min(start + UInt64(pattern.count), size))
    }
}

final class HexTableController {
    weak var table: UITableView?
    func scroll(to row: Int) {
        guard let t = table, row >= 0, row < t.numberOfRows(inSection: 0) else { return }
        t.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
    }
}

struct HexTable: UIViewRepresentable {
    let doc: HexDocument
    let perRow: Int
    let revision: Int
    let highlightRow: Int?
    let controller: HexTableController
    let onTap: (Int) -> Void

    var rowCount: Int { Int((doc.size + UInt64(perRow) - 1) / UInt64(perRow)) }

    func makeUIView(context: Context) -> UITableView {
        let t = UITableView(frame: .zero, style: .plain)
        t.register(UITableViewCell.self, forCellReuseIdentifier: "hex")
        t.dataSource = context.coordinator
        t.delegate = context.coordinator
        t.rowHeight = 20
        t.estimatedRowHeight = 0
        t.separatorStyle = .none
        controller.table = t
        context.coordinator.signature = signature
        return t
    }

    private var signature: String { "\(perRow)-\(revision)-\(highlightRow ?? -1)-\(doc.size)" }

    func updateUIView(_ t: UITableView, context: Context) {
        context.coordinator.parent = self
        controller.table = t
        if context.coordinator.signature != signature {
            context.coordinator.signature = signature
            t.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var parent: HexTable
        var signature = ""
        init(_ p: HexTable) { parent = p }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { parent.rowCount }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "hex", for: indexPath)
            var config = UIListContentConfiguration.cell()
            config.text = parent.doc.line(row: indexPath.row, perRow: parent.perRow)
            config.textProperties.font = .monospacedSystemFont(ofSize: parent.perRow > 8 ? 9 : 12, weight: .regular)
            config.textProperties.numberOfLines = 1
            config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 4)
            cell.contentConfiguration = config
            cell.backgroundColor = indexPath.row == parent.highlightRow ? UIColor.systemYellow.withAlphaComponent(0.35) : .clear
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            parent.onTap(indexPath.row)
        }
    }
}

struct HexEditorView: View {
    @StateObject private var doc: HexDocument
    @AppStorage("hexBytesPerRow") private var perRow = 8
    @State private var controller = HexTableController()
    @State private var editingRow: EditRow?
    @State private var highlight: Int?
    @State private var prompt: PromptKind?
    @State private var promptText = ""
    @State private var status: String?
    @State private var lastFind: UInt64 = 0

    struct EditRow: Identifiable { let row: Int; var id: Int { row } }
    enum PromptKind { case goto, findHex, findText }

    init(url: URL) {
        _doc = StateObject(wrappedValue: HexDocument(url: url))
    }

    var body: some View {
        Group {
            if let err = doc.loadError {
                ViewerError(message: err)
            } else {
                HexTable(doc: doc, perRow: perRow, revision: doc.revision, highlightRow: highlight,
                         controller: controller) { row in editingRow = EditRow(row: row) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(status ?? "\(ByteFormat.size(doc.size)) · \(doc.size) bytes\(doc.writable ? "" : " · read-only")")
                    .font(.caption.monospacedDigit())
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { ask(.goto) } label: { Label("Go to offset", systemImage: "arrow.right.to.line") }
                    Button { ask(.findHex) } label: { Label("Find hex bytes", systemImage: "number") }
                    Button { ask(.findText) } label: { Label("Find text", systemImage: "textformat") }
                    Picker("Bytes per row", selection: $perRow) {
                        Text("8 bytes per row").tag(8)
                        Text("16 bytes per row").tag(16)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(promptPlaceholder, text: $promptText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Go") { runPrompt() }
        }
        .sheet(item: $editingRow) { item in
            HexRowEditor(doc: doc, offset: UInt64(item.row) * UInt64(perRow), length: perRow) { message in
                status = message
            }
        }
    }

    private var promptTitle: String {
        switch prompt {
        case .goto: return "Go to offset (hex)"
        case .findHex: return "Find hex bytes"
        case .findText: return "Find text"
        case nil: return ""
        }
    }

    private var promptPlaceholder: String {
        switch prompt {
        case .goto: return "e.g. 1F40"
        case .findHex: return "e.g. CF FA ED FE"
        default: return "Text"
        }
    }

    private func ask(_ kind: PromptKind) {
        promptText = ""
        prompt = kind
    }

    private func runPrompt() {
        guard let kind = prompt else { return }
        let input = promptText
        switch kind {
        case .goto:
            let clean = input.lowercased().replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit }
            guard let off = UInt64(clean, radix: 16), off < max(doc.size, 1) else {
                status = "Offset out of range."
                return
            }
            jump(to: off)
        case .findHex, .findText:
            let pattern: Data? = kind == .findHex ? Data(hexString: input) : Data(input.utf8)
            guard let p = pattern, !p.isEmpty else {
                status = "Enter something to search for."
                return
            }
            let url = doc.url
            let start = lastFind == 0 && highlight == nil ? 0 : lastFind + 1
            status = "Searching…"
            Task.detached {
                let found = HexDocument.find(p, in: url, from: start)
                await MainActor.run {
                    if let f = found {
                        lastFind = f
                        jump(to: f)
                        status = String(format: "Found at 0x%llX (search again for next)", f)
                    } else {
                        status = "Not found."
                    }
                }
            }
        }
    }

    private func jump(to offset: UInt64) {
        let row = Int(offset / UInt64(perRow))
        highlight = row
        DispatchQueue.main.async { controller.scroll(to: row) }
    }
}

struct HexRowEditor: View {
    @ObservedObject var doc: HexDocument
    let offset: UInt64
    let length: Int
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hex = ""
    @State private var original = Data()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Offset", value: String(format: "0x%08llX", offset))
                    TextField("Hex bytes", text: $hex, axis: .vertical)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("Bytes")
                } footer: {
                    Text("Overwrite in place: keep exactly \(original.count) bytes so nothing shifts.")
                }
                Section("Preview") {
                    Text(preview).font(.body.monospaced())
                }
                if let error = error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit bytes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Write") { write() }.disabled(!doc.writable)
                }
            }
            .onAppear {
                original = doc.bytes(at: offset, count: length)
                hex = original.map { String(format: "%02X", $0) }.joined(separator: " ")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var preview: String {
        guard let d = Data(hexString: hex) else { return "Invalid hex" }
        return String(d.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "·" })
    }

    private func write() {
        guard let d = Data(hexString: hex) else { error = "That isn't valid hex."; return }
        guard d.count == original.count else { error = "Must be \(original.count) bytes (you have \(d.count))."; return }
        do {
            try doc.write(d, at: offset)
            onDone(String(format: "Wrote %d bytes at 0x%llX", d.count, offset))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
