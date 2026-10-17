import SwiftUI
import Combine

@MainActor final class BrowserPane: ObservableObject, Identifiable {
    let id: UUID
    @Published var tabs: [SearchModel] { didSet { tabsChanged.send() } }
    @Published var selectedTab: UUID
    @Published var closedTabs: [TabSession] = []
    let tabsChanged = PassthroughSubject<Void, Never>()

    init(id: UUID = UUID(), tabs: [SearchModel] = [], selectedIndex: Int = 0) {
        self.id = id
        let initialTabs = tabs.isEmpty ? [SearchModel()] : tabs
        self.tabs = initialTabs
        selectedTab = initialTabs[min(max(0, selectedIndex), initialTabs.count - 1)].id
    }
    var current: SearchModel { tabs.first { $0.id == selectedTab } ?? tabs[0] }
    var canHide: Bool {
        !tabs.contains {
            $0.busy || $0.conflict != nil || $0.renaming != nil || $0.batchRename != nil
                || $0.preview != nil
        }
    }
    func newTab(_ location: URL? = nil) {
        let tab = SearchModel()
        tab.navigate(location ?? current.location)
        tabs.append(tab); selectedTab = tab.id
    }
    func closeTab(_ id: UUID) {
        guard tabs.count > 1, let tab = tabs.first(where: { $0.id == id }), !tab.busy else {
            return
        }
        closedTabs.append(TabSession(tab))
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        tabs.removeAll { $0.id == id }
        if selectedTab == id { selectedTab = tabs[0].id }
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

extension BrowserWorkspace {
    var activePane: BrowserPane { panes.first { $0.id == activePaneID } ?? panes[0] }
    var allTabs: [SearchModel] { panes.flatMap(\.tabs) }
    var current: SearchModel { activePane.current }

    func activatePane(_ id: UUID) {
        guard panes.prefix(layout.paneCount).contains(where: { $0.id == id }) else { return }
        if activePaneID != id { activePaneID = id }
    }

    func canSetLayout(_ next: PaneLayout) -> Bool {
        var ordered = panes
        if let index = ordered.firstIndex(where: { $0.id == activePaneID }), index >= next.paneCount
        {
            ordered.swapAt(0, index)
        }
        return ordered.dropFirst(next.paneCount).allSatisfy(\.canHide)
    }

    func setLayout(_ next: PaneLayout) {
        guard canSetLayout(next) else { return }
        var ordered = panes
        while ordered.count < next.paneCount {
            let tab = SearchModel()
            tab.navigate(current.location); tab.viewMode = current.viewMode
            ordered.append(BrowserPane(tabs: [tab]))
        }
        // Keep the pane the user was working in visible when reducing the count.
        if let index = ordered.firstIndex(where: { $0.id == activePaneID }), index >= next.paneCount
        {
            ordered.swapAt(0, index)
        }
        layout = next
        panes = ordered
        saveSession()
    }
}
