import SwiftUI

struct PlistEditorView: View {
    let url: URL
    @State private var doc: PlistDocument?
    @State private var error: String?

    var body: some View {
        Group {
            if let doc = doc {
                PlistRootView(doc: doc)
            } else if let error = error {
                ViewerError(message: "Not a valid property list.\n\(error)")
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard doc == nil else { return }
            do { doc = try PlistDocument(url: url) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PlistRootView: View {
    @ObservedObject var doc: PlistDocument
    @State private var showXML = false
    @State private var status: String?

    var body: some View {
        PlistContainerView(node: doc.root, doc: doc)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text(status ?? formatName + (doc.dirty ? " · unsaved changes" : ""))
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.thinMaterial)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Save") { save() }.disabled(!doc.dirty).bold()
                    Menu {
                        Button { showXML = true } label: { Label("Edit as XML", systemImage: "chevron.left.forwardslash.chevron.right") }
                        Picker("Save format", selection: $doc.format) {
                            Text("Binary").tag(PropertyListSerialization.PropertyListFormat.binary)
                            Text("XML").tag(PropertyListSerialization.PropertyListFormat.xml)
                        }
                        Button { UIPasteboard.general.string = doc.xmlString() } label: { Label("Copy as XML", systemImage: "doc.on.doc") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .onChange(of: doc.format) { _ in doc.dirty = true }
            .sheet(isPresented: $showXML) { PlistXMLEditor(doc: doc) }
    }

    private var formatName: String { doc.format == .binary ? "Binary plist" : "XML plist" }

    private func save() {
        do {
            try doc.save()
            status = "Saved"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}

struct PlistContainerView: View {
    @ObservedObject var node: PlistNode
    @ObservedObject var doc: PlistDocument
    @State private var editing: PlistNode?
    @State private var query = ""

    var body: some View {
        List {
            ForEach(filtered) { child in
                PlistRow(node: child, parent: node, doc: doc, onEdit: { editing = child })
            }
            .onDelete { offsets in
                let ids = offsets.map { filtered[$0].id }
                node.children.removeAll { ids.contains($0.id) }
                doc.touch()
            }
            .onMove(perform: moveAction)
            if node.children.isEmpty {
                Text("Empty \(node.type.short.lowercased())").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Filter keys and values")
        .navigationTitle(node.parent == nil ? "Root" : node.label(in: node.parent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { add() } label: { Label("Add", systemImage: "plus") }
                Spacer()
                EditButton()
            }
        }
        .sheet(item: $editing) { n in
            PlistValueEditor(node: n, parent: node, doc: doc)
        }
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard query.isEmpty else { return nil }
        let node = node, doc = doc
        return { from, to in
            node.children.move(fromOffsets: from, toOffset: to)
            doc.touch()
        }
    }

    private var filtered: [PlistNode] {
        guard !query.isEmpty else { return node.children }
        return node.children.filter {
            $0.key.localizedCaseInsensitiveContains(query) || (!$0.isContainer && $0.summary.localizedCaseInsensitiveContains(query))
        }
    }

    private func add() {
        let child = PlistNode(key: node.type == .dictionary ? node.uniqueChildKey("New Key") : "", type: .string)
        child.parent = node
        node.children.append(child)
        doc.touch()
        editing = child
    }
}

private struct PlistRow: View {
    @ObservedObject var node: PlistNode
    let parent: PlistNode
    let doc: PlistDocument
    let onEdit: () -> Void

    var body: some View {
        if node.isContainer {
            NavigationLink {
                PlistContainerView(node: node, doc: doc)
            } label: {
                content
            }
            .swipeActions(edge: .leading) {
                Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
            }
        } else {
            Button(action: onEdit) { content }
                .foregroundStyle(.primary)
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(node.type.short)
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label(in: parent)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(node.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var color: Color {
        switch node.type {
        case .dictionary: return .purple
        case .array: return .indigo
        case .string: return .blue
        case .integer, .real: return .orange
        case .boolean: return .green
        case .date: return .teal
        case .data: return .gray
        }
    }
}

struct PlistValueEditor: View {
    @ObservedObject var node: PlistNode
    let parent: PlistNode
    let doc: PlistDocument
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var type: PlistType = .string
    @State private var text = ""
    @State private var bool = false
    @State private var date = Date()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if parent.type == .dictionary {
                    Section("Key") {
                        TextField("Key", text: $key).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
                Section("Type") {
                    Picker("Type", selection: $type) {
                        ForEach(PlistType.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Value") {
                    switch type {
                    case .boolean:
                        Toggle(bool ? "YES" : "NO", isOn: $bool)
                    case .date:
                        DatePicker("Date", selection: $date)
                    case .dictionary, .array:
                        Text("\(node.children.count) children – open it from the list to edit them.")
                            .foregroundStyle(.secondary)
                    case .data:
                        TextField("Hex bytes", text: $text, axis: .vertical)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    case .integer, .real:
                        TextField("Number", text: $text)
                            .keyboardType(.numbersAndPunctuation)
                    case .string:
                        TextField("Text", text: $text, axis: .vertical)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                if let error = error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Edit value")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply() } }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        key = node.key
        type = node.type
        bool = node.bool
        date = node.date
        switch node.type {
        case .string: text = node.string
        case .integer: text = String(node.integer)
        case .real: text = String(node.real)
        case .data: text = node.data.map { String(format: "%02X", $0) }.joined(separator: " ")
        default: text = ""
        }
    }

    private func apply() {
        if parent.type == .dictionary {
            let k = key
            if k.isEmpty { error = "Key can't be empty."; return }
            if parent.children.contains(where: { $0 !== node && $0.key == k }) {
                error = "Another item already uses the key “\(k)”."
                return
            }
        }
        switch type {
        case .integer:
            guard let v = Int(text.trimmingCharacters(in: .whitespaces)) else { error = "Enter a whole number."; return }
            node.integer = v
        case .real:
            guard let v = Double(text.trimmingCharacters(in: .whitespaces)) else { error = "Enter a number."; return }
            node.real = v
        case .data:
            guard let d = Data(hexString: text) else { error = "Enter valid hex bytes."; return }
            node.data = d
        case .string: node.string = text
        case .boolean: node.bool = bool
        case .date: node.date = date
        case .dictionary, .array:
            if node.type != type { node.convert(to: type) }
        }
        if parent.type == .dictionary { node.key = key }
        node.type = type
        parent.objectWillChange.send()
        doc.touch()
        dismiss()
    }
}

struct PlistXMLEditor: View {
    @ObservedObject var doc: PlistDocument
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = TextViewController()
    @State private var xml = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            CodeTextView(text: $xml, controller: controller)
                .safeAreaInset(edge: .bottom) {
                    if let error = error {
                        Text(error).font(.caption).foregroundStyle(.red).padding(6)
                            .frame(maxWidth: .infinity).background(.thinMaterial)
                    }
                }
                .navigationTitle("XML")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            do {
                                try doc.replace(withXML: xml)
                                dismiss()
                            } catch {
                                self.error = "Invalid plist XML: \(error.localizedDescription)"
                            }
                        }
                    }
                }
                .onAppear { xml = doc.xmlString() }
        }
    }
}
