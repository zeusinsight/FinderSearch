import SwiftUI
import UniformTypeIdentifiers

@MainActor enum OpenWithApps {
    static func applications(for hit: Hit) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: hit.url).sorted {
            $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent) == .orderedAscending
        }
    }
    static func title(_ application: URL, for hit: Hit) -> String {
        let name = application.deletingPathExtension().lastPathComponent
        return NSWorkspace.shared.urlForApplication(toOpen: hit.url) == application
            ? name + " (default)" : name
    }
}
struct OpenWithMenu: View {
    @ObservedObject var model: SearchModel
    let hit: Hit
    var body: some View {
        Menu("Open With") {
            ForEach(OpenWithApps.applications(for: hit), id: \.path) { application in
                Button(OpenWithApps.title(application, for: hit)) {
                    model.openWith(application, hit: hit)
                }
            }
            Divider()
            Button("Other…") { model.chooseApplication(for: hit) }
        }.disabled(hit.isFolder)
    }
}
extension SearchModel {
    func openWith(_ application: URL, hit: Hit) {
        let urls = selection.contains(hit.path) ? selectedItems.map(\.url) : [hit.url]
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: .init()) {
            [weak self] _, error in
            if let error { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
    func chooseApplication(for hit: Hit) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"; panel.prompt = "Open"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let application = panel.url { openWith(application, hit: hit) }
    }
}
