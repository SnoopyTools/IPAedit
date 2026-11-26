import SwiftUI
import UIKit

// MARK: - Model

final class InspectorModel: ObservableObject {
    @Published var image: MachOImage?
    @Published var slices: [MachOSlice] = []
    @Published var selected = 0
    @Published var error: String?
    @Published var loading = true
    let disassembler = Disassembler()

    @MainActor
    func load(url: URL) async {
        loading = true
        error = nil
        let index = selected
        let result: Result<(MachOImage, [MachOSlice]), Error> = await Task.detached {
            Result {
                let slices = try MachOImage.slices(of: url)
                guard !slices.isEmpty else { throw SimpleError("No 64-bit slice to inspect.") }
                // Prefer arm64e/arm64 when nothing has been picked yet.
                let pick = index < slices.count ? index : 0
                return (try MachOImage(url: url, slice: slices[pick]), slices)
            }
        }.value
        switch result {
        case .success(let (img, s)):
            image = img
            slices = s
        case .failure(let e):
            error = e.localizedDescription
        }
        loading = false
    }
}

func hex(_ a: UInt64) -> String { String(format: "0x%llx", a) }

// MARK: - Entry point

struct InspectorView: View {
    let url: URL
    @StateObject private var model = InspectorModel()

    var body: some View {
        Group {
            if model.loading {
                ProgressView("Analysing binary…")
            } else if let e = model.error {
                ViewerError(message: e)
            } else if let img = model.image {
                InspectorHome(url: url, image: img, model: model)
            }
        }
        .task { await model.load(url: url) }
    }
}

struct EncryptedBanner: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("This binary is encrypted").font(.headline)
                Text("It's an App Store binary (cryptid 1), so its code and strings are scrambled and the disassembly will be garbage. Objective-C class lists may still work. Use a decrypted IPA for real results.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
        }
    }
}

struct InspectorHome: View {
    let url: URL
    let image: MachOImage
    @ObservedObject var model: InspectorModel
    @State private var addressText = ""

    private var parsedAddress: UInt64? {
        var t = addressText.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("0x") { t.removeFirst(2) }
        if t.hasPrefix("sub_") { t.removeFirst(4) }
        guard let a = UInt64(t, radix: 16), image.fileOffset(forVM: a) != nil else { return nil }
        return a
    }

    var body: some View {
        List {
            if image.isEncrypted {
                Section { EncryptedBanner() }
            }
            if model.slices.count > 1 {
                Section {
                    Picker("Architecture", selection: $model.selected) {
                        ForEach(Array(model.slices.enumerated()), id: \.offset) { item in
                            Text(item.element.cpu).tag(item.offset)
                        }
                    }
                    .onChange(of: model.selected) { _ in
                        Task { await model.load(url: url) }
                    }
                }
            }
            Section("Overview") {
                LabeledContent("Architecture", value: image.cpu)
                LabeledContent("Image base", value: hex(image.textBase))
                if let e = image.entryPoint {
                    NavigationLink {
                        DisassemblyView(image: image, disassembler: model.disassembler, start: e)
                    } label: {
                        LabeledContent("Entry point", value: hex(e))
                    }
                }
                LabeledContent("Disassembler", value: model.disassembler == nil ? "Unavailable" : "Capstone \(Disassembler.capstoneVersion)")
                LabeledContent("Swift demangler", value: SwiftDemangler.isAvailable ? "Available" : "Unavailable")
            }
            Section("Browse") {
                NavigationLink {
                    FunctionsListView(image: image, disassembler: model.disassembler)
                } label: { countRow("Functions", "function", image.functions.count) }
                NavigationLink {
                    ClassesListView(image: image, disassembler: model.disassembler)
                } label: { countRow("Objective-C classes", "c.square", image.classes.count) }
                NavigationLink {
                    SymbolsListView(image: image, disassembler: model.disassembler, imports: false)
                } label: { countRow("Symbols", "tag", image.definedSymbols.count) }
                NavigationLink {
                    SymbolsListView(image: image, disassembler: model.disassembler, imports: true)
                } label: { countRow("Imports", "arrow.down.square", image.importedSymbols.count) }
                NavigationLink {
                    SectionsListView(image: image, disassembler: model.disassembler)
                } label: { countRow("Sections", "square.split.1x2", image.sections.count) }
                NavigationLink {
                    ReadOnlyTextView(title: "Class dump", text: ClassDump.header(for: image.classes))
                } label: { Label("Class dump (header)", systemImage: "doc.plaintext") }
            }
            Section {
                TextField("Address, e.g. 0x100004000", text: $addressText)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let a = parsedAddress {
                    NavigationLink {
                        DisassemblyView(image: image, disassembler: model.disassembler, start: a)
                    } label: { Label("Disassemble at \(hex(a))", systemImage: "arrow.right.circle") }
                }
            } header: {
                Text("Go to address")
            } footer: {
                if !addressText.isEmpty && parsedAddress == nil {
                    Text("That address isn't inside this binary.")
                }
            }
        }
    }

    private func countRow(_ title: String, _ icon: String, _ n: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(n)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Functions

struct FunctionRow: Identifiable {
    var function: MachOImage.Function
    var name: String
    var id: UInt64 { function.address }
}

struct FunctionsListView: View {
    let image: MachOImage
    let disassembler: Disassembler?
    @State private var rows: [FunctionRow] = []
    @State private var query = ""
    @State private var namedOnly = false
    @State private var loading = true

    private var filtered: [FunctionRow] {
        let q = query.lowercased()
        return rows.filter { row in
            (!namedOnly || row.function.name != nil)
                && (q.isEmpty || row.name.localizedCaseInsensitiveContains(q) || hex(row.function.address).contains(q))
        }
    }

    var body: some View {
        let list = filtered
        List {
            Section {
                Toggle("Named functions only", isOn: $namedOnly)
            }
            Section("\(list.count) functions") {
                ForEach(list.prefix(3000)) { row in
                    NavigationLink {
                        DisassemblyView(image: image, disassembler: disassembler, start: row.function.address)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.caption.monospaced()).lineLimit(3)
                            Text("\(hex(row.function.address)) · \(row.function.end - row.function.address) bytes")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if list.count > 3000 {
                    Text("\(list.count - 3000) more – search to narrow it down.").foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .searchable(text: $query, prompt: "Name or address")
        .navigationTitle("Functions")
        .task {
            let img = image
            rows = await Task.detached { img.functions.map { FunctionRow(function: $0, name: img.displayName(for: $0.address)) } }.value
            loading = false
        }
    }
}

// MARK: - Symbols

struct SymbolsListView: View {
    let image: MachOImage
    let disassembler: Disassembler?
    let imports: Bool
    @State private var query = ""

    var body: some View {
        let all = imports ? image.importedSymbols : image.definedSymbols
        let list = query.isEmpty ? all : all.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
        List {
            Section("\(list.count) \(imports ? "imports" : "symbols")") {
                ForEach(list.prefix(3000)) { s in
                    if !imports, image.function(containing: s.address) != nil {
                        NavigationLink {
                            DisassemblyView(image: image, disassembler: disassembler, start: s.address)
                        } label: { row(s) }
                    } else {
                        row(s)
                    }
                }
                if list.count > 3000 {
                    Text("\(list.count - 3000) more – search to narrow it down.").foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query, prompt: "Search")
        .navigationTitle(imports ? "Imports" : "Symbols")
    }

    private func row(_ s: MachOImage.Symbol) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(s.displayName).font(.caption.monospaced()).lineLimit(4).textSelection(.enabled)
            if s.displayName != s.name && s.displayName != String(s.name.dropFirst()) {
                Text(s.name).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if !s.isImport {
                Text(hex(s.address) + (image.section(containing: s.address).map { "  " + $0.fullName } ?? ""))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = s.displayName } label: { Label("Copy name", systemImage: "doc.on.doc") }
            Button { UIPasteboard.general.string = s.name } label: { Label("Copy raw symbol", systemImage: "doc.on.doc") }
        }
    }
}

// MARK: - Sections

struct SectionsListView: View {
    let image: MachOImage
    let disassembler: Disassembler?

    var body: some View {
        List {
            ForEach(image.sections) { s in
                if s.isCode && s.size > 0 {
                    NavigationLink {
                        DisassemblyView(image: image, disassembler: disassembler, start: s.addr, end: s.addr + s.size)
                    } label: { row(s) }
                } else {
                    row(s)
                }
            }
        }
        .navigationTitle("Sections")
    }

    private func row(_ s: MachOImage.Section) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.fullName).font(.caption.monospaced().bold())
                if s.isCode { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.caption2).foregroundStyle(.blue) }
            }
            Text("\(hex(s.addr)) – \(hex(s.addr + s.size)) · \(ByteFormat.size(s.size))")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Objective-C

struct ClassesListView: View {
    let image: MachOImage
    let disassembler: Disassembler?
    @State private var query = ""

    var body: some View {
        let list = query.isEmpty ? image.classes : image.classes.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) || ($0.category?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.methods.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
        List {
            Section("\(list.count) classes and categories") {
                ForEach(list) { c in
                    NavigationLink {
                        ClassDetailView(image: image, disassembler: disassembler, cls: c)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.category.map { "\(c.displayName) (\($0))" } ?? c.displayName)
                                .font(.caption.monospaced().bold()).lineLimit(2)
                            Text([c.superclass.map { ": " + $0 }, "\(c.methods.count) methods"].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Class or method")
        .navigationTitle("Classes")
    }
}

struct ClassDetailView: View {
    let image: MachOImage
    let disassembler: Disassembler?
    let cls: MachOImage.ObjCClass

    var body: some View {
        List {
            Section {
                if let s = cls.superclass { LabeledContent("Superclass", value: s) }
                if !cls.protocols.isEmpty { LabeledContent("Protocols", value: cls.protocols.joined(separator: ", ")) }
                if cls.displayName != cls.name { LabeledContent("Runtime name", value: cls.name) }
                NavigationLink {
                    ReadOnlyTextView(title: cls.displayName, text: ClassDump.header(for: [cls]))
                } label: { Label("Header", systemImage: "doc.plaintext") }
            }
            if !cls.properties.isEmpty {
                Section("Properties (\(cls.properties.count))") {
                    ForEach(cls.properties) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.caption.monospaced())
                            Text(p.attributes).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !cls.ivars.isEmpty {
                Section("Instance variables (\(cls.ivars.count))") {
                    ForEach(cls.ivars) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).font(.caption.monospaced())
                            Text("+\(hex(UInt64(v.offset)))  \(v.type)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            methodSection("Class methods", cls.methods.filter { $0.isClassMethod })
            methodSection("Instance methods", cls.methods.filter { !$0.isClassMethod })
        }
        .navigationTitle(cls.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func methodSection(_ title: String, _ methods: [MachOImage.ObjCMethod]) -> some View {
        if !methods.isEmpty {
            Section("\(title) (\(methods.count))") {
                ForEach(methods) { m in
                    let label = VStack(alignment: .leading, spacing: 2) {
                        Text((m.isClassMethod ? "+ " : "- ") + m.name).font(.caption.monospaced())
                        Text(m.imp == 0 ? m.types : "\(hex(m.imp))  \(m.types)")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if m.imp != 0 {
                        NavigationLink {
                            DisassemblyView(image: image, disassembler: disassembler, start: m.imp)
                        } label: { label }
                    } else {
                        label
                    }
                }
            }
        }
    }
}

enum ClassDump {
    static func header(for classes: [MachOImage.ObjCClass]) -> String {
        var out = ""
        for c in classes {
            var line = c.category != nil ? "@interface \(c.displayName) (\(c.category!))" : "@interface \(c.displayName)"
            if let s = c.superclass { line += " : \(s)" }
            if !c.protocols.isEmpty { line += " <\(c.protocols.joined(separator: ", "))>" }
            out += line
            if !c.ivars.isEmpty {
                out += " {\n"
                for v in c.ivars { out += "    \(v.type) \(v.name); // +\(hex(UInt64(v.offset)))\n" }
                out += "}"
            }
            out += "\n"
            for p in c.properties { out += "@property \(p.name); // \(p.attributes)\n" }
            if !c.properties.isEmpty { out += "\n" }
            for m in c.methods {
                out += "\(m.isClassMethod ? "+" : "-") \(m.name); // \(m.types)"
                if m.imp != 0 { out += " @ \(hex(m.imp))" }
                out += "\n"
            }
            out += "@end\n\n"
        }
        return out.isEmpty ? "No Objective-C classes found." : out
    }
}

// MARK: - Disassembly

struct DisassemblyView: View {
    let image: MachOImage
    let disassembler: Disassembler?
    let start: UInt64
    var end: UInt64? = nil

    @State private var lines: [Instruction] = []
    @State private var limit: UInt64 = 0
    @State private var loading = true
    @State private var highlight: UInt64?

    private static let chunk = 3000

    private var title: String {
        if let f = image.function(containing: start), f.address == start { return image.displayName(for: start) }
        return hex(start)
    }

    private var rangeEnd: UInt64 {
        if let e = end { return e }
        if let f = image.function(containing: start) { return f.end }
        let sec = image.section(containing: start)
        return min(start + 4096, sec.map { $0.addr + $0.size } ?? start + 4096)
    }

    var body: some View {
        Group {
            if disassembler == nil {
                ViewerError(message: "The disassembler couldn't be started.")
            } else {
                ScrollViewReader { proxy in
                    List {
                        if image.isEncrypted { Section { EncryptedBanner() } }
                        Section {
                            ForEach(lines) { insn in
                                row(insn, proxy: proxy)
                                    .id(insn.address)
                                    .listRowBackground(highlight == insn.address ? Color.yellow.opacity(0.25) : nil)
                            }
                            if limit < rangeEnd && !loading {
                                Button("Load more") { Task { await load(more: true) } }
                            }
                        } header: {
                            Text("\(hex(start)) – \(hex(rangeEnd))  ·  \(lines.count) instructions")
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .overlay { if loading && lines.isEmpty { ProgressView("Disassembling…") } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = lines.map(Self.text).joined(separator: "\n")
                } label: { Image(systemName: "doc.on.doc") }
            }
        }
        .task { if lines.isEmpty { await load(more: false) } }
    }

    static func text(_ i: Instruction) -> String {
        var s = String(format: "%llx  %08x  ", i.address, i.word) + i.mnemonic.padding(toLength: 8, withPad: " ", startingAt: 0) + " " + i.operands
        if let c = i.comment { s += "  ; " + c }
        return s
    }

    @ViewBuilder
    private func row(_ insn: Instruction, proxy: ScrollViewProxy) -> some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%llx", insn.address)).foregroundStyle(.secondary)
                Text(insn.mnemonic).bold().foregroundStyle(mnemonicColor(insn))
                Text(insn.operands)
            }
            .font(.caption.monospaced())
            if let c = insn.comment {
                Text("; " + c).font(.caption2.monospaced()).foregroundStyle(.green).lineLimit(2)
            }
        }
        .contextMenu {
            Button { UIPasteboard.general.string = Self.text(insn) } label: { Label("Copy line", systemImage: "doc.on.doc") }
            Button { UIPasteboard.general.string = hex(insn.address) } label: { Label("Copy address", systemImage: "number") }
            if let off = image.fileOffset(forVM: insn.address) {
                Button {
                    UIPasteboard.general.string = hex(UInt64(off) + image.sliceOffset)
                } label: { Label("Copy file offset (for Hex Editor)", systemImage: "number.square") }
            }
            Button { UIPasteboard.general.string = String(format: "%08x", insn.word.byteSwapped) } label: {
                Label("Copy bytes", systemImage: "square.grid.3x3")
            }
        }

        if let t = insn.target, t >= start, t < limit {
            Button {
                highlight = t
                withAnimation { proxy.scrollTo(t, anchor: .center) }
            } label: { content }
            .buttonStyle(.plain)
        } else if let t = insn.target, image.function(containing: t) != nil {
            NavigationLink {
                DisassemblyView(image: image, disassembler: disassembler, start: t)
            } label: { content }
        } else {
            content
        }
    }

    private func mnemonicColor(_ i: Instruction) -> Color {
        if i.mnemonic.hasPrefix("b") || i.mnemonic.hasPrefix("cb") || i.mnemonic.hasPrefix("tb") { return .blue }
        if i.mnemonic.hasPrefix("ret") { return .red }
        if i.mnemonic == ".word" { return .secondary }
        return .primary
    }

    private func load(more: Bool) async {
        guard let d = disassembler else { loading = false; return }
        loading = true
        let from = more ? limit : start
        let img = image
        let until = rangeEnd
        let chunk = Self.chunk
        let result = await Task.detached { d.disassemble(image: img, from: from, to: until, max: chunk) }.value
        lines += result
        limit = result.last.map { $0.address + 4 } ?? until
        loading = false
    }
}
