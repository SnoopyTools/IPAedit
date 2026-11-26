import SwiftUI
import UIKit

/// Holds a reference to the live UITextView so toolbar buttons can drive it.
final class TextViewController: ObservableObject {
    weak var textView: UITextView?

    func showFind(replace: Bool) {
        guard let tv = textView else { return }
        if #available(iOS 16.0, *) {
            tv.becomeFirstResponder()
            tv.findInteraction?.presentFindNavigator(showingReplace: replace)
        }
    }
}

struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    var editable: Bool = true
    var fontSize: CGFloat = 13
    var controller: TextViewController
    var onEdit: () -> Void = {}

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isEditable = editable
        tv.isSelectable = true
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.alwaysBounceVertical = true
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 40, right: 6)
        if #available(iOS 16.0, *) { tv.isFindInteractionEnabled = true }
        tv.text = text
        controller.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text && !context.coordinator.isEditing {
            tv.text = text
        }
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.isEditable = editable
        controller.textView = tv
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        var isEditing = false
        init(_ parent: CodeTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            isEditing = true
            parent.text = textView.text
            parent.onEdit()
            isEditing = false
        }
    }
}

struct TextFileEditor: View {
    let url: URL
    @StateObject private var controller = TextViewController()
    @State private var text = ""
    @State private var encoding: String.Encoding = .utf8
    @State private var loaded = false
    @State private var dirty = false
    @State private var tooBig: UInt64?
    @State private var status: String?
    @AppStorage("editorFontSize") private var fontSize: Double = 13

    var body: some View {
        Group {
            if let size = tooBig {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle)
                    Text("This file is \(ByteFormat.size(size)). Large files can be slow to edit as text.")
                        .multilineTextAlignment(.center)
                    Button("Open anyway") { load(force: true) }.buttonStyle(.borderedProminent)
                }
                .padding()
            } else if loaded {
                CodeTextView(text: $text, fontSize: CGFloat(fontSize), controller: controller) { dirty = true }
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = status {
                Text(status).font(.caption).padding(6).frame(maxWidth: .infinity).background(.thinMaterial)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save") { save() }.disabled(!dirty).bold()
                Menu {
                    Button { controller.showFind(replace: false) } label: { Label("Find", systemImage: "magnifyingglass") }
                    Button { controller.showFind(replace: true) } label: { Label("Find & Replace", systemImage: "arrow.left.arrow.right") }
                    Button { formatJSON() } label: { Label("Pretty-print JSON", systemImage: "curlybraces") }
                    Button { fontSize = min(fontSize + 1, 28) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                    Button { fontSize = max(fontSize - 1, 8) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                    Button { UIPasteboard.general.string = text } label: { Label("Copy all", systemImage: "doc.on.doc") }
                    Text("Encoding: \(encodingName)")
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { if !loaded && tooBig == nil { load(force: false) } }
    }

    private var encodingName: String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .isoLatin1: return "Latin-1"
        default: return "\(encoding)"
        }
    }

    private func load(force: Bool) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size > 8 * 1024 * 1024 && !force {
            tooBig = size
            return
        }
        tooBig = nil
        guard let data = try? Data(contentsOf: url) else {
            status = "Couldn't read the file."
            loaded = true
            return
        }
        if let s = String(data: data, encoding: .utf8) {
            text = s; encoding = .utf8
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            text = s; encoding = .utf16
        } else {
            text = String(data: data, encoding: .isoLatin1) ?? ""
            encoding = .isoLatin1
            status = "Not valid UTF-8 – shown as Latin-1. Use the Hex Editor for binary files."
        }
        loaded = true
    }

    private func save() {
        guard let data = text.data(using: encoding) ?? text.data(using: .utf8) else { return }
        do {
            try data.write(to: url)
            dirty = false
            status = "Saved \(ByteFormat.size(data.count))"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func formatJSON() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: pretty, encoding: .utf8) else {
            status = "Not valid JSON."
            return
        }
        text = s
        dirty = true
        status = nil
    }
}
