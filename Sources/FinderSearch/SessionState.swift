import AppKit
import Combine

struct TabSession: Codable, Equatable {
    var path: String
    var route: String
    var query: String
    var scope: String
    var view: String
    var sort: String
    var ascending: Bool
    var hidden: Bool
    var selection: Set<String>
    var scrollAnchor: String?
    var scrollOffset: Double

    @MainActor init(_ model: SearchModel) {
        path = model.location.path; route = model.route; query = model.query; scope = model.scope
        view = model.viewMode.rawValue
        sort = model.sort.rawValue; ascending = model.ascending; hidden = model.showHidden
        selection = model.selection; scrollAnchor = model.scrollAnchor
        scrollOffset = model.scrollOffset
    }

    @MainActor func restore() -> SearchModel {
        let model = SearchModel()
        model.navigate(URL(fileURLWithPath: path, isDirectory: true))
        if route == "recents" || route.hasPrefix("tag:") { model.sidebar(route) }
        model.scope = scope; model.query = query
        model.viewMode = FileViewMode(rawValue: view) ?? .icons
        model.sort = FileSort(rawValue: sort) ?? .name
        model.ascending = ascending; model.showHidden = hidden
        model.selection = selection; model.scrollAnchor = scrollAnchor
        model.scrollOffset = scrollOffset
        return model
    }
}

struct WorkspaceSession: Codable {
    static let key = "browserSession.v1"
    var tabs: [TabSession]
    var selectedIndex: Int
}

extension BrowserWorkspace {
    func observeSession() {
        guard sessionDefaults != nil else { return }
        sessionObservers = tabs.map { tab in
            tab.objectWillChange.merge(with: tab.scrollChanges)
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.saveSession() }
        }
        sessionObservers.append(
            objectWillChange
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.saveSession() })
    }

    func saveSession() {
        guard let sessionDefaults, !tabs.isEmpty else { return }
        let state = WorkspaceSession(
            tabs: tabs.map(TabSession.init),
            selectedIndex: tabs.firstIndex { $0.id == selectedTab } ?? 0)
        if let data = try? JSONEncoder().encode(state) {
            sessionDefaults.set(data, forKey: WorkspaceSession.key)
        }
    }

    func moveTab(_ source: UUID, to destination: UUID) {
        guard source != destination, let from = tabs.firstIndex(where: { $0.id == source }),
            let to = tabs.firstIndex(where: { $0.id == destination })
        else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    func reopenClosedTab() {
        guard let state = closedTabs.popLast() else { return }
        let tab = state.restore(); tabs.append(tab); selectedTab = tab.id
    }
}
