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

    var iconSize: Double?
    var fileType: String?
    var backPaths: [String]?
    var forwardPaths: [String]?

    @MainActor init(_ model: SearchModel) {
        path = model.location.path; route = model.route; query = model.query; scope = model.scope
        view = model.viewMode.rawValue
        sort = model.sort.rawValue; ascending = model.ascending; hidden = model.showHidden
        selection = model.selection; scrollAnchor = model.scrollAnchor
        scrollOffset = model.scrollOffset
        iconSize = model.iconSize; fileType = model.fileType
        backPaths = model.backStack.map(\.path); forwardPaths = model.forwardStack.map(\.path)
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
        model.iconSize = min(96, max(40, iconSize ?? 64))
        model.fileType = fileType ?? ""
        model.backStack = (backPaths ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        model.forwardStack = (forwardPaths ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        return model
    }
}

struct WorkspaceSession: Codable {
    static let key = "browserSession.v1"
    var tabs: [TabSession]
    var selectedIndex: Int
}

struct PaneSession: Codable {
    var id: UUID
    var tabs: [TabSession]
    var selectedIndex: Int

    @MainActor init(_ pane: BrowserPane) {
        id = pane.id; tabs = pane.tabs.map(TabSession.init)
        selectedIndex = pane.tabs.firstIndex { $0.id == pane.selectedTab } ?? 0
    }
    @MainActor func restore() -> BrowserPane {
        BrowserPane(id: id, tabs: tabs.map { $0.restore() }, selectedIndex: selectedIndex)
    }
}

struct PaneWorkspaceSession: Codable {
    static let key = "browserSession.v2"
    var panes: [PaneSession]
    var activePaneID: UUID
    var layout: PaneLayout
    var weights: [String: [String: [Double]]]
}

extension BrowserWorkspace {
    func restoreSession() {
        if let data = sessionDefaults?.data(forKey: PaneWorkspaceSession.key),
            let state = try? JSONDecoder().decode(PaneWorkspaceSession.self, from: data),
            (state.layout.paneCount...4).contains(state.panes.count),
            Set(state.panes.map(\.id)).count == state.panes.count,
            state.panes.allSatisfy({ !$0.tabs.isEmpty && $0.tabs.count <= 50 })
        {
            panes = state.panes.map { $0.restore() }
            layout = state.layout; layoutWeights = state.weights
            activePaneID =
                panes.prefix(layout.paneCount).contains { $0.id == state.activePaneID }
                ? state.activePaneID : panes[0].id
        } else if let data = sessionDefaults?.data(forKey: WorkspaceSession.key),
            let state = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
            !state.tabs.isEmpty, state.tabs.count <= 50
        {
            panes = [
                BrowserPane(
                    tabs: state.tabs.map { $0.restore() }, selectedIndex: state.selectedIndex)
            ]
            activePaneID = panes[0].id
        } else {
            activePaneID = panes[0].id
        }
    }

    func observeSession() {
        sessionObservers = []
        for pane in panes {
            sessionObservers.append(
                pane.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                })
            sessionObservers.append(
                pane.tabsChanged.sink { [weak self] _ in
                    self?.observeSession(); self?.saveSession()
                })
            for tab in pane.tabs {
                // Only window-level operation/presentation changes redraw the workspace.
                // File contents and selection remain observed by the individual pane.
                let presentation = Publishers.MergeMany([
                    tab.$busy.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                    tab.$conflict.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                    tab.$batchRename.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                    tab.$preview.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                    tab.$renaming.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                ])
                sessionObservers.append(
                    presentation.sink { [weak self] _ in self?.objectWillChange.send() })
                if sessionDefaults != nil {
                    sessionObservers.append(
                        tab.objectWillChange.merge(with: tab.scrollChanges)
                            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
                            .sink { [weak self] _ in self?.saveSession() })
                }
            }
        }
        if sessionDefaults != nil {
            sessionObservers.append(
                objectWillChange
                    .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
                    .sink { [weak self] _ in self?.saveSession() })
        }
    }

    func saveSession() {
        guard let sessionDefaults, !panes.isEmpty else { return }
        let state = PaneWorkspaceSession(
            panes: panes.map(PaneSession.init), activePaneID: activePaneID,
            layout: layout, weights: layoutWeights)
        if let data = try? JSONEncoder().encode(state) {
            sessionDefaults.set(data, forKey: PaneWorkspaceSession.key)
        }
    }
}
