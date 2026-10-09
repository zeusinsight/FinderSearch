import SwiftUI
import AppKit
import Darwin

enum FileViewMode: String, CaseIterable {
    case icons, list, columns, gallery
    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2";
        case .list: return "list.bullet";
        case .columns: return "rectangle.split.3x1";
        case .gallery: return "rectangle.bottomthird.inset.filled"
        }
    }
    var title: String { rawValue.capitalized }
}
enum FileSort: String, CaseIterable {
    case name = "Name", modified = "Date Modified", size = "Size", kind = "Kind", relevance =
        "Relevance"
}
struct FileJournal { let name: String; let operations: [FileMutation] }

@MainActor final class SearchModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published var location = URL(fileURLWithPath: NSHomeDirectory())
    @Published var route = NSHomeDirectory()
    @Published var query = "" {
        willSet { if !changingLocation && !isSearch { saveDefaultSnapshot() } }
        didSet {
            invalidateDerived()
            if !changingLocation && !isSearch,
                let snapshot = snapshots[SnapshotKey(route: route, hidden: showHidden)]
            {
                sort = snapshot.sort; ascending = snapshot.ascending
            } else if !changingLocation && !isSearch
                && !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                hits = []; selection = []
            }
            schedule()
        }
    }
    @Published var scope = "" { didSet { if !query.isEmpty { schedule() } } }
    @Published var fileType = "" { didSet { schedule() } }
    @Published var hits: [Hit] = [] { didSet { invalidateDerived() } }
    @Published var extraHits: [Hit] = [] { didSet { selectedCache = nil } }
    @Published var selection: Set<String> = [] {
        didSet {
            selectedCache = nil
            if let focusedPath, selection.contains(focusedPath) { return }
            focusedPath = selection.sorted().first
            selectionAnchor = focusedPath
        }
    }
    @Published var focusedPath: String?
    private var selectionAnchor: String?
    @Published var searching = false
    @Published var loading = false
    @Published var error: String?
    @Published var ready = false
    @Published var entries = 0
    @Published var fullDiskAccess = false
    @Published var elapsed: Double = 0
    @Published var preview: Hit?
    @Published var viewMode =
        FileViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "icons")
        ?? .icons
    {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var sort: FileSort = .name { didSet { invalidateDerived() } }
    @Published var ascending = true { didSet { invalidateDerived() } }
    @Published var showHidden = false { didSet { invalidateDerived(); schedule() } }
    @Published var busy = false
    @Published var undoStack: [FileJournal] = []
    @Published var redoStack: [FileJournal] = []
    @Published var backStack: [URL] = []
    @Published var forwardStack: [URL] = []
    private let engine: any SearchService
    init(engine: any SearchService = Engine()) { self.engine = engine }
    private var task: Task<Void, Never>?
    private var sortedCache: [Hit]?
    private var selectedCache: [Hit]?
    private struct SnapshotKey: Hashable { let route: String; let hidden: Bool }
    private struct Snapshot {
        let hits: [Hit]; var selection: Set<String>; let sort: FileSort; let ascending: Bool;
        let ordered: [Hit]
    }
    private var snapshots: [SnapshotKey: Snapshot] = [:]
    private var snapshotOrder: [SnapshotKey] = []
    private var changingLocation = false
    private var watchRefresh: Task<Void, Never>?
    private func invalidateDerived() { sortedCache = nil; selectedCache = nil }
    private var generation = 0
    private var statusStarted = false
    private var watchTask: Task<Void, Never>?
    private var watchGeneration = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var metadata: NSMetadataQuery?
    private var metadataObserver: NSObjectProtocol?
    var canWriteHere: Bool { !isSearch && route != "recents" && !route.hasPrefix("tag:") }
    var isSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var title: String {
        route == "recents"
            ? "Recents"
            : route.hasPrefix("tag:")
                ? String(route.dropFirst(4))
                : location.lastPathComponent.isEmpty ? "Macintosh HD" : location.lastPathComponent
    }
    var selected: Hit? { selectedItems.first }
    var selectedItems: [Hit] {
        guard !selection.isEmpty else { return [] }
        if let selectedCache { return selectedCache }
        var seen = Set<String>()
        let result = (sortedHits + extraHits.filter { showHidden || !$0.name.hasPrefix(".") })
            .filter { selection.contains($0.path) && seen.insert($0.path).inserted }
        selectedCache = result
        return result
    }
    var sortedHits: [Hit] {
        if let sortedCache { return sortedCache }
        let filtered = showHidden ? hits : hits.filter { !$0.name.hasPrefix(".") }
        if isSearch && sort == .relevance { sortedCache = filtered; return filtered }
        let result = filtered.sorted { a, b in
            let comparison: ComparisonResult
            switch sort {
            case .modified:
                comparison =
                    a.mtime == b.mtime
                    ? .orderedSame : a.mtime < b.mtime ? .orderedAscending : .orderedDescending
            case .size:
                comparison =
                    a.size == b.size
                    ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
            case .kind: comparison = a.typeName.localizedStandardCompare(b.typeName)
            default: comparison = a.name.localizedStandardCompare(b.name)
            }
            if comparison == .orderedSame { return ascending ? a.path < b.path : a.path > b.path }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        sortedCache = result
        return result
    }
    func select(_ hit: Hit, extending: Bool, toggling: Bool) {
        if toggling {
            if selection.contains(hit.path) {
                selection.remove(hit.path)
            } else {
                focusedPath = hit.path; selection.insert(hit.path)
            }
            selectionAnchor = focusedPath
        } else if extending, let anchor = selectionAnchor,
            let start = sortedHits.firstIndex(where: { $0.path == anchor }),
            let end = sortedHits.firstIndex(where: { $0.path == hit.path })
        {
            focusedPath = hit.path
            selection = Set(sortedHits[min(start, end)...max(start, end)].map(\.path))
            selectionAnchor = anchor
        } else {
            focusedPath = hit.path; selection = [hit.path]; selectionAnchor = hit.path
        }
    }
    func moveSelection(by delta: Int, extending: Bool) {
        let items = sortedHits
        guard !items.isEmpty else { return }
        let current = focusedPath.flatMap { path in items.firstIndex { $0.path == path } }
        let next =
            current.map { min(items.count - 1, max(0, $0 + delta)) }
            ?? (delta < 0 ? items.count - 1 : 0)
        let target = items[next].path
        if extending {
            let anchor = selectionAnchor ?? focusedPath ?? target
            let start = items.firstIndex { $0.path == anchor } ?? next
            focusedPath = target
            selection = Set(items[min(start, next)...max(start, next)].map(\.path))
            selectionAnchor = anchor
        } else {
            focusedPath = target; selection = [target]; selectionAnchor = target
        }
    }
    var ancestors: [URL] {
        var result: [URL] = [];
        var url = isSearch ? selected?.url.deletingLastPathComponent() ?? location : location
        while true {
            result.insert(url, at: 0); if url.path == "/" { break }; url.deleteLastPathComponent()
        }
        return result
    }
    func start() { if hits.isEmpty { schedule() }; watch() }
    func navigate(_ url: URL, history: Bool = true) {
        guard !busy else { return }
        saveDefaultSnapshot()
        changingLocation = true
        if history && url != location { backStack.append(location); forwardStack = [] }
        location = url.standardizedFileURL; route = location.path
        extraHits = []; scope = ""; query = ""; fileType = ""; selection = []; sort = .name;
        ascending = true
        if let snapshot = snapshots[SnapshotKey(route: route, hidden: showHidden)] {
            sort = snapshot.sort; ascending = snapshot.ascending
        }
        changingLocation = false
        if snapshots[SnapshotKey(route: route, hidden: showHidden)] == nil { hits = [] }
        watch(); schedule()
        if let snapshot = snapshots[SnapshotKey(route: route, hidden: showHidden)] {
            selection = snapshot.selection
        }
    }
    func goBack() {
        guard !busy, let url = backStack.popLast() else { return }; forwardStack.append(location);
        navigate(url, history: false)
    }
    func goForward() {
        guard !busy, let url = forwardStack.popLast() else { return }; backStack.append(location);
        navigate(url, history: false)
    }
    func sidebar(_ value: String) {
        guard !busy else { return }
        if value == "recents" || value.hasPrefix("tag:") {
            saveDefaultSnapshot(); changingLocation = true
        }
        if value == "recents" {
            route = value; scope = ""; query = ""; sort = .modified; ascending = false;
            changingLocation = false; hits = []; schedule()
        } else if value.hasPrefix("tag:") {
            route = value; scope = ""; query = ""; changingLocation = false; hits = []; schedule()
        } else {
            navigate(URL(fileURLWithPath: value))
        }
    }
    func schedule() {
        guard !changingLocation else { return }
        generation += 1; let revision = generation
        task?.cancel(); error = nil
        if isSearch { extraHits = [] }
        let searchingNow = isSearch
        let cached = !searchingNow && restoreDefaultSnapshot()
        if route.hasPrefix("tag:") && !isSearch { loadTag(String(route.dropFirst(4))); return }
        let folder = location, hidden = showHidden, text = query, searchScope = scope,
            type = fileType
        let recent = route == "recents" && !isSearch
        loading = !searchingNow && !cached; searching = searchingNow
        task = Task {
            do {
                let result: [Hit]
                if searchingNow || recent {
                    try await Task.sleep(for: .milliseconds(searchingNow ? 300 : 0))
                    try Task.checkCancellation()
                    var fields: [String: Any] = [
                        "q": recent ? "mtime:<30d kind:file" : text, "limit": recent ? 1000 : 500,
                    ]
                    if recent {
                        fields["in"] = NSHomeDirectory()
                    } else if !searchScope.isEmpty {
                        fields["in"] = searchScope
                    }
                    if type == "dir" {
                        fields["kind"] = "dir"
                    } else if !type.isEmpty {
                        fields["type"] = type
                    }
                    let reply = try await engine.request(fields)
                    guard reply.ok else {
                        throw Engine.Failure.message(reply.error ?? "Search failed")
                    }
                    result = reply.hits ?? [];
                    if revision == generation { elapsed = Double(reply.took_us ?? 0) / 1000 }
                } else {
                    result = try await LocalFiles.load(folder, hidden: hidden)
                }
                guard revision == generation, !Task.isCancelled else { return }
                hits = result;
                selection.formIntersection(
                    Set(
                        (sortedHits + extraHits.filter { showHidden || !$0.name.hasPrefix(".") })
                            .map(\.path)))
                loading = false; searching = false
                if !searchingNow { saveDefaultSnapshot() }
            } catch is CancellationError {} catch {
                guard revision == generation else { return };
                self.error = error.localizedDescription; hits = []; selection = []; loading = false;
                searching = false
            }
        }
    }
    @discardableResult private func restoreDefaultSnapshot() -> Bool {
        let key = SnapshotKey(route: route, hidden: showHidden)
        guard let snapshot = snapshots[key] else { return false }
        hits = snapshot.hits
        if sort == snapshot.sort && ascending == snapshot.ascending {
            sortedCache = snapshot.ordered
        }
        selection.formIntersection(Set(sortedHits.map(\.path)))
        elapsed = 0
        return true
    }
    private func saveDefaultSnapshot() {
        guard !isSearch, !loading else { return }
        let key = SnapshotKey(route: route, hidden: showHidden)
        snapshots[key] = Snapshot(
            hits: hits, selection: selection, sort: sort, ascending: ascending, ordered: sortedHits)
        snapshotOrder.removeAll { $0 == key }; snapshotOrder.append(key)
        while snapshotOrder.count > 8
            || (snapshots.values.reduce(0) { $0 + $1.hits.count } > 40000
                && snapshotOrder.count > 1)
        {
            snapshots.removeValue(forKey: snapshotOrder.removeFirst())
        }
    }
    private func watch() {
        watchGeneration += 1; let token = watchGeneration
        watchTask?.cancel(); watchRefresh?.cancel(); watcher?.cancel(); watcher = nil
        let folder = location
        watchTask = Task {
            let fd = await Task.detached(priority: .utility) { Darwin.open(folder.path, O_EVTONLY) }
                .value
            guard fd >= 0 else { return }
            guard !Task.isCancelled, watchGeneration == token else { Darwin.close(fd); return }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, self.watchGeneration == token, self.route == folder.path else {
                    return
                }
                self.watchRefresh?.cancel()
                self.watchRefresh = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, let self else { return }
                    if !self.isSearch && !self.busy { self.schedule() }
                }
            }
            source.setCancelHandler { Darwin.close(fd) }; source.resume(); watcher = source
        }
    }
    func monitor() async {
        guard !statusStarted else { return }; statusStarted = true
        while !Task.isCancelled {
            do {
                let status = try await engine.request(["op": "status"])
                let becameReady = status.ok && !ready; if ready != status.ok { ready = status.ok }
                if status.ok {
                    if entries != status.entries ?? 0 { entries = status.entries ?? 0 };
                    if fullDiskAccess != status.full_disk_access ?? false {
                        fullDiskAccess = status.full_disk_access ?? false
                    }; if becameReady && (isSearch || route == "recents") { schedule() }
                }
            } catch { if isSearch { self.error = error.localizedDescription } }
            try? await Task.sleep(for: .seconds(5))
        }; statusStarted = false
    }
    func open(_ item: Hit? = nil) {
        if let item {
            if item.isFolder {
                navigate(item.url)
            } else if !NSWorkspace.shared.open(item.url) {
                error = "Could not open ‘\(item.name)’."
            }; return
        }
        for hit in selectedItems {
            if hit.isFolder && selection.count == 1 { navigate(hit.url); return };
            if !NSWorkspace.shared.open(hit.url) { error = "Could not open ‘\(hit.name)’." }
        }
    }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url)) }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false;
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { navigate(url) }
    }
    func goToFolder() {
        let alert = NSAlert(); alert.messageText = "Go to Folder"; alert.addButton(withTitle: "Go");
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: location.path);
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                directory.boolValue
            {
                navigate(url)
            } else {
                error = "That folder does not exist."
            }
        }
    }
    func rename() {
        guard !busy, let hit = selected, selection.count == 1 else { return }
        let alert = NSAlert(); alert.messageText = "Rename ‘\(hit.name)’";
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: hit.name);
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24); alert.accessoryView = field;
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                !name.contains(":"), !name.contains("\0")
            else { error = "Choose a valid filename without slashes or colons."; return }
            perform(
                [.move(hit.url, hit.url.deletingLastPathComponent().appendingPathComponent(name))],
                name: "Rename")
        }
    }
    func newFolder() {
        guard canWriteHere else { return };
        perform(
            [.folder(LocalFiles.availableName(in: location, name: "untitled folder"))],
            name: "New Folder")
    }
    func duplicate() {
        perform(
            selectedItems.map {
                .copy(
                    $0.url,
                    LocalFiles.availableName(
                        in: $0.url.deletingLastPathComponent(), name: $0.name, suffix: " copy"))
            }, name: "Duplicate")
    }
    func trash() { perform(selectedItems.map { .trash($0.url) }, name: "Move to Trash") }
    func copy() {
        NSPasteboard.general.clearContents();
        NSPasteboard.general.writeObjects(selectedItems.map { $0.url as NSURL })
    }
    func copyPath() {
        NSPasteboard.general.clearContents();
        NSPasteboard.general.setString(
            selectedItems.map(\.path).joined(separator: "\n"), forType: .string)
    }
    func paste(move: Bool = false) {
        guard canWriteHere else { return }
        let urls =
            NSPasteboard.general.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        transfer(urls, to: location, move: move)
    }
    func transfer(_ urls: [URL], to folder: URL, move: Bool) {
        guard !busy else { return }
        var seen = Set<String>()
        let items = urls.filter { $0.isFileURL && seen.insert($0.path).inserted }
        var invalid = false
        let operations: [FileMutation] = items.compactMap { source in
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            if source.standardizedFileURL == destination.standardizedFileURL {
                return move
                    ? nil
                    : .copy(
                        source,
                        LocalFiles.availableName(
                            in: folder, name: source.lastPathComponent, suffix: " copy"))
            }
            if folder.resolvingSymlinksInPath().path.hasPrefix(
                source.resolvingSymlinksInPath().path + "/")
            {
                invalid = true; error = "A folder cannot be moved or copied inside itself.";
                return nil
            }
            return move ? .move(source, destination) : .copy(source, destination)
        }
        if !invalid { perform(operations, name: move ? "Move" : "Copy") }
    }
    func perform(_ operations: [FileMutation], name: String, history: Int = 0) {
        guard !operations.isEmpty, !busy else { return }; busy = true; error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LocalFiles.apply(operations)
            }.value
            if !result.inverse.isEmpty {
                let journal = FileJournal(name: name, operations: result.inverse)
                if history == 1 {
                    redoStack.append(journal)
                } else {
                    undoStack.append(journal); if history == 0 { redoStack = [] }
                }
            }
            if history != 0, !result.failed.isEmpty {
                let failed = FileJournal(name: name, operations: result.failed)
                if history == 1 { undoStack.append(failed) } else { redoStack.append(failed) }
            }
            busy = false; schedule()
            if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
        }
    }
    func undo() {
        guard !busy, let journal = undoStack.popLast() else { return };
        perform(journal.operations, name: journal.name, history: 1)
    }
    func redo() {
        guard !busy, let journal = redoStack.popLast() else { return };
        perform(journal.operations, name: journal.name, history: 2)
    }
    func info() {
        guard let hit = selected else { return }
        let alert = NSAlert(); alert.messageText = hit.name
        let tags = (try? hit.url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        alert.informativeText =
            "Kind: \(hit.typeName)\nSize: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: hit.size), countStyle: .file))\nModified: \(hit.modified.formatted())\nWhere: \(hit.parent)\nTags: \(tags.joined(separator: ", "))"
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
    func tag(_ name: String) {
        let operations: [FileMutation] = selectedItems.map { hit in
            var tags = (try? hit.url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            if tags.contains(name) { tags.removeAll { $0 == name } } else { tags.append(name) }
            return .tags(hit.url, tags)
        }
        perform(operations, name: "Tags")
    }
    private func loadTag(_ name: String) {
        metadata?.stop();
        if let metadataObserver { NotificationCenter.default.removeObserver(metadataObserver) }
        generation += 1; let token = generation
        searching = false; loading = !restoreDefaultSnapshot(); if loading { hits = [] };
        selection = []
        let q = NSMetadataQuery(); q.searchScopes = [NSHomeDirectory()];
        q.predicate = NSPredicate(format: "kMDItemUserTags LIKE %@", name + "*")
        metadataObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token, self.route == "tag:" + name,
                    !self.isSearch, let query = self.metadata
                else { return }
                query.disableUpdates()
                self.hits = query.results.compactMap { value in
                    guard let item = value as? NSMetadataItem,
                        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                    else { return nil }; return try? Hit.read(URL(fileURLWithPath: path))
                }
                self.loading = false; self.saveDefaultSnapshot(); query.stop()
            }
        }
        metadata = q; q.start()
    }
    deinit {
        watchTask?.cancel(); task?.cancel(); watchRefresh?.cancel(); watcher?.cancel();
        metadata?.stop();
        if let metadataObserver { NotificationCenter.default.removeObserver(metadataObserver) }
    }
}

@MainActor final class BrowserWorkspace: ObservableObject {
    @Published var tabs: [SearchModel] = [SearchModel()]
    @Published var selectedTab = UUID()
    @Published var favorites: [String] =
        UserDefaults.standard.stringArray(forKey: "favorites") ?? []
    @Published var volumes: [URL] = []
    init() { selectedTab = tabs[0].id; refreshVolumes() }
    var current: SearchModel { tabs.first { $0.id == selectedTab } ?? tabs[0] }
    func newTab(_ location: URL? = nil) {
        let tab = SearchModel(); tab.navigate(location ?? current.location); tabs.append(tab);
        selectedTab = tab.id
    }
    func closeTab(_ id: UUID) {
        guard tabs.count > 1, tabs.first(where: { $0.id == id })?.busy != true else { return };
        tabs.removeAll { $0.id == id };
        if !tabs.contains(where: { $0.id == selectedTab }) { selectedTab = tabs[0].id }
    }
    func addFavorite(_ url: URL) {
        if !favorites.contains(url.path) {
            favorites.append(url.path); UserDefaults.standard.set(favorites, forKey: "favorites")
        }
    }
    func removeFavorite(_ path: String) {
        favorites.removeAll { $0 == path };
        UserDefaults.standard.set(favorites, forKey: "favorites")
    }
    func refreshVolumes() {
        volumes =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeIsBrowsableKey],
                options: [.skipHiddenVolumes]) ?? []
    }
}
