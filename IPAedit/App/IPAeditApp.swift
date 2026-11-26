import SwiftUI
import UniformTypeIdentifiers

@main
struct IPAeditApp: App {
    @StateObject private var store = WorkspaceStore()
    @StateObject private var nav = Navigator()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(nav)
                .onOpenURL { url in
                    let ext = url.pathExtension.lowercased()
                    if ["ipa", "tipa", "zip"].contains(ext) {
                        nav.path = NavigationPath()
                        store.importIPA(from: url)
                    }
                }
        }
    }
}

enum Route: Hashable {
    case workspace(UUID)
    case folder(URL)
    case file(URL, Viewer)
    case search(UUID)
    case text(title: String, body: String)
}

final class Navigator: ObservableObject {
    @Published var path = NavigationPath()
    func push(_ route: Route) { path.append(route) }
}

enum IPATypes {
    static var importable: [UTType] {
        var types: [UTType] = []
        if let t = UTType("com.apple.itunes.ipa") { types.append(t) }
        if let t = UTType(filenameExtension: "ipa") { types.append(t) }
        if let t = UTType(filenameExtension: "tipa") { types.append(t) }
        types.append(.zip)
        return types
    }
}
