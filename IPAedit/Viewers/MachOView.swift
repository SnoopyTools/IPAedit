import SwiftUI

struct MachOView: View {
    let url: URL
    @EnvironmentObject var nav: Navigator
    @State private var slices: [MachOSlice] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if let error = error {
                ViewerError(message: error)
            } else {
                List {
                    if slices.contains(where: { ($0.encryption?.cryptid ?? 0) != 0 }) {
                        Section { EncryptedBanner() }
                    }
                    Section {
                        Button { nav.push(.file(url, .inspector)) } label: {
                            Label("Disassemble & browse classes", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Button { nav.push(.file(url, .strings)) } label: { Label("Dump strings", systemImage: "text.magnifyingglass") }
                        Button { nav.push(.file(url, .hex)) } label: { Label("Open in Hex Editor", systemImage: "number") }
                    }
                    ForEach(slices) { s in sliceSections(s) }
                }
            }
        }
        .task {
            let u = url
            let result: Result<[MachOSlice], Error> = await Task.detached { Result { try MachOFile.parse(url: u) } }.value
            switch result {
            case .success(let s): slices = s
            case .failure(let e): error = e.localizedDescription
            }
            loading = false
        }
    }

    @ViewBuilder
    private func sliceSections(_ s: MachOSlice) -> some View {
        Section(slices.count > 1 ? "\(s.cpu) slice" : "Header") {
            row("Type", s.fileType)
            row("Architecture", s.cpu + (s.is64 ? " (64-bit)" : " (32-bit)"))
            if let p = s.platform { row("Platform", p) }
            if let m = s.minOS { row("Minimum OS", m) }
            if let sdk = s.sdk { row("SDK", sdk) }
            if let u = s.uuid { row("UUID", u) }
            if let i = s.installName { row("Install name", i) }
            row("Load commands", "\(s.loadCommandCount)")
            if !s.flags.isEmpty { row("Flags", s.flags.joined(separator: ", ")) }
            if slices.count > 1 { row("Slice", "offset \(s.offset) · \(ByteFormat.size(s.size))") }
            if let e = s.encryption {
                row("Encryption", e.cryptid == 0 ? "Not encrypted (cryptid 0)" : "ENCRYPTED (cryptid \(e.cryptid)) – App Store binary, needs decrypting")
            }
            if let c = s.codeSignature {
                row("Code signature", "\(ByteFormat.size(UInt64(c.size))) at 0x\(String(c.offset, radix: 16))")
            } else {
                row("Code signature", "None")
            }
            if let ent = s.entitlements {
                Button { nav.push(.text(title: "Entitlements", body: ent)) } label: {
                    Label("Entitlements", systemImage: "key")
                }
            }
        }
        if !s.dylibs.isEmpty {
            Section("Linked libraries (\(s.dylibs.count))") {
                ForEach(Array(s.dylibs.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        if !s.rpaths.isEmpty {
            Section("Run paths") {
                ForEach(Array(s.rpaths.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        if !s.segments.isEmpty {
            Section("Segments") {
                ForEach(Array(s.segments.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.caption.monospaced())
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
        }
    }
}

struct StringsDumpView: View {
    let url: URL
    @State private var strings: [(UInt64, String)] = []
    @State private var minLength = 6
    @State private var query = ""
    @State private var loading = true
    @State private var truncated = false

    private var filtered: [(UInt64, String)] {
        query.isEmpty ? strings : strings.filter { $0.1.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Stepper("Minimum length: \(minLength)", value: $minLength, in: 3...32)
                if truncated { Text("Showing the first 100,000 strings.").font(.caption).foregroundStyle(.secondary) }
            }
            let rows = filtered
            Section("\(rows.count) strings") {
                ForEach(Array(rows.prefix(5000).enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "0x%08llX", item.element.0)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(item.element.1).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .contextMenu {
                        Button { UIPasteboard.general.string = item.element.1 } label: { Label("Copy", systemImage: "doc.on.doc") }
                    }
                }
                if rows.count > 5000 {
                    Text("\(rows.count - 5000) more – use the search box to narrow it down.").foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if loading { ProgressView("Scanning…") } }
        .searchable(text: $query, prompt: "Search strings")
        .task(id: minLength) { await scan() }
    }

    private func scan() async {
        loading = true
        let u = url, minLen = minLength
        let (found, cut) = await Task.detached { () -> ([(UInt64, String)], Bool) in
            var out: [(UInt64, String)] = []
            guard let h = try? FileHandle(forReadingFrom: u) else { return ([], false) }
            defer { try? h.close() }
            var current: [UInt8] = []
            var start: UInt64 = 0
            var pos: UInt64 = 0
            while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty {
                for b in chunk {
                    if b >= 0x20 && b < 0x7F || b == 0x09 {
                        if current.isEmpty { start = pos }
                        current.append(b)
                    } else {
                        if current.count >= minLen {
                            out.append((start, String(decoding: current, as: UTF8.self)))
                            if out.count >= 100_000 { return (out, true) }
                        }
                        current.removeAll(keepingCapacity: true)
                    }
                    pos += 1
                }
                if Task.isCancelled { break }
            }
            if current.count >= minLen { out.append((start, String(decoding: current, as: UTF8.self))) }
            return (out, false)
        }.value
        strings = found
        truncated = cut
        loading = false
    }
}
