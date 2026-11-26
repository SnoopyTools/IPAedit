import SwiftUI

struct FileViewerHost: View {
    let url: URL
    @State private var viewer: Viewer
    @State private var sharing = false

    init(url: URL, initialViewer: Viewer) {
        self.url = url
        _viewer = State(initialValue: initialViewer)
    }

    var body: some View {
        content
            .id(viewer)
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Open with", selection: $viewer) {
                            ForEach(Viewer.allCases) { v in
                                Label(v.title, systemImage: v.symbol).tag(v)
                            }
                        }
                        Divider()
                        Button { sharing = true } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: viewer.symbol)
                    }
                }
            }
            .sheet(isPresented: $sharing) { ShareSheet(items: [url]) }
    }

    @ViewBuilder
    private var content: some View {
        switch viewer {
        case .text: TextFileEditor(url: url)
        case .hex: HexEditorView(url: url)
        case .plist: PlistEditorView(url: url)
        case .image: ImageViewer(url: url)
        case .machO: MachOView(url: url)
        case .inspector: InspectorView(url: url)
        case .strings: StringsDumpView(url: url)
        case .assets: AssetsCarView(url: url)
        case .media: MediaPlayerView(url: url)
        case .pdf: PDFViewer(url: url)
        case .provision: ProvisionView(url: url)
        case .quickLook: QuickLookView(url: url)
        }
    }
}

/// Shown by viewers that can't handle a file, with a hint to try another one.
struct ViewerError: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Text("Try another viewer from the menu at the top right.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
