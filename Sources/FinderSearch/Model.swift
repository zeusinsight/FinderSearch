import SwiftUI
import AppKit
import Darwin
import Combine

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
    /// When on, searches match file contents (the engine's content index)
    /// instead of filenames.
    @Published var contentSearch = false {
        didSet {
            guard oldValue != contentSearch else { return }
            if contentSearch {
                // Filename results are not content results: drop them so the
                // view shows the content spinner instead of stale rows, and
                // drop Kind ▸ Folder, which contents cannot match.
                clearContentResults()
                if fileType == "dir" { fileType = "" }
                if isSearch { hits = []; selection = [] }
            } else {
                clearContentResults()
                if isSearch { hits = []; selection = [] }
            }
            if isSearch { schedule() }
        }
    }
    /// literal (smart case), regex, or symbol (definition of an identifier).
    @Published var contentMode = "literal" {
        didSet { if oldValue != contentMode, isSearch, contentSearch { schedule() } }
    }
    @Published var contentFiles: [ContentFile] = []
    @Published var contentSource = ""
    @Published var contentComplete = true
    @Published var contentIndexing = 0
    @Published var hits: [Hit] = [] { didSet { invalidateDerived() } }
    @Published var extraHits: [Hit] = [] {
        didSet { selectedCache = nil; extraRowIndex = nil }
    }
    @Published var selection: Set<String> = [] {
        didSet {
            selectedCache = nil
            if let renaming, !selection.contains(renaming.path) { cancelRename() }
            if let focusedPath, selection.contains(focusedPath) { return }
            focusedPath = selection.sorted().first
            selectionAnchor = focusedPath
        }
    }
    var marqueeSelecting = false
    @Published var focusedPath: String?
    // Scroll bindings track their own position. Persisting that position must
    // not invalidate the browser and every visible file cell on each row.
    let scrollChanges = PassthroughSubject<Void, Never>()
    var scrollAnchor: String? {
        didSet { if scrollAnchor != oldValue { scrollChanges.send() } }
    }
    var scrollOffset: Double = 0
    private var selectionAnchor: String?
    @Published var searching = false
    @Published var loading = false
    @Published private(set) var sorting = false
    @Published var error: String?
    @Published var ready = false
    @Published var entries = 0
    @Published var fullDiskAccess = false
    @Published var elapsed: Double = 0
    @Published var preview: Hit? {
        didSet {
            if oldValue == nil, let preview {
                previewItems =
                    selection.count > 1 && selection.contains(preview.path)
                    ? selectedItems : sortedHits
                if !previewItems.contains(where: { $0.path == preview.path }) {
                    previewItems = [preview]
                }
            } else if preview == nil {
                previewItems = []
            }
        }
    }
    var previewItems: [Hit] = []
    let springLoader = SpringLoader()
    @Published private(set) var renaming: Hit?
    @Published var viewMode =
        FileViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "icons")
        ?? .icons
    {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var sort: FileSort = .name { didSet { invalidateDerived(preserveOrder: true) } }
    @Published var ascending = true { didSet { invalidateDerived(preserveOrder: true) } }
    @Published var showHidden = false { didSet { invalidateDerived(); schedule() } }
    @Published var busy = false
    @Published var operationProgress: FileOperationProgress?
    @Published var operationName = ""
    @Published var conflict: FileConflict?
    @Published var batchRename: BatchRenameRequest?
    var conflictContinuation: CheckedContinuation<ConflictChoice, Never>?
    var allConflictChoice: ConflictChoice?
    private var operationControl: FileOperationControl?
    private var activeOperationID: UUID?
    var preparationTask: Task<Void, Never>?
    @Published var undoStack: [FileJournal] = []
    @Published var redoStack: [FileJournal] = []
    @Published var backStack: [URL] = []
    @Published var forwardStack: [URL] = []
    private let searchDebounce: Duration
    private var searchDebouncing = false
    private let engine: any SearchService
    private let diskAccessCheck: @Sendable () -> Bool
    private let folderLoader: @Sendable (URL, Bool) async throws -> [Hit]
    private let folderPreviewLoader: @Sendable (URL, Bool) async throws -> [Hit]
    init(
        engine: any SearchService = Engine(),
        searchDebounce: Duration = .milliseconds(50),
        diskAccessCheck: @escaping @Sendable () -> Bool = { FullDiskAccess.isGranted() },
        folderLoader: @escaping @Sendable (URL, Bool) async throws -> [Hit] = {
            try await LocalFiles.load($0, hidden: $1)
        },
        folderPreviewLoader: @escaping @Sendable (URL, Bool) async throws -> [Hit] = {
            try await LocalFiles.preview($0, hidden: $1)
        }
    ) {
        self.engine = engine
        self.searchDebounce = searchDebounce
        self.diskAccessCheck = diskAccessCheck
        self.folderLoader = folderLoader
        self.folderPreviewLoader = folderPreviewLoader
    }
    private var task: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var mutationError: String?
    @Published private var sortedCache: [Hit]? {
        didSet { rowIndex = nil; selectedCache = nil }
    }
    private var visibleCache: [Hit]? {
        didSet { rowIndex = nil; selectedCache = nil }
    }
    private var rowIndex: [String: Int]?
    private var extraRowIndex: [String: Int]?
    private var rowsByPath: [String: Int] {
        if let rowIndex { return rowIndex }
        let index = Self.indexRows(sortedHits)
        rowIndex = index
        return index
    }
    private static func indexRows(_ items: [Hit]) -> [String: Int] {
        var index: [String: Int] = [:]
        index.reserveCapacity(items.count)
        for (row, hit) in items.enumerated() where index[hit.path] == nil {
            index[hit.path] = row
        }
        return index
    }
    private var orderingCache: FileOrdering.Cache?
    private var orderingTask: Task<Void, Never>?
    private var orderingGeneration = 0
    private var selectedCache: [Hit]?
    private struct SnapshotKey: Hashable { let route: String; let hidden: Bool }
    private struct Snapshot {
        let hits: [Hit]; var selection: Set<String>; let sort: FileSort; let ascending: Bool;
        let ordered: [Hit]?
    }
    private var snapshots: [SnapshotKey: Snapshot] = [:]
    private var snapshotOrder: [SnapshotKey] = []
    private var changingLocation = false
    private var watchRefresh: Task<Void, Never>?
    private func invalidateDerived(preserveOrder: Bool = false) {
        visibleCache = preserveOrder ? (sortedCache ?? visibleCache) : nil
        sortedCache = nil; selectedCache = nil
        orderingTask?.cancel(); orderingGeneration += 1
        let revision = orderingGeneration
        let previous = orderingCache
        let items = hits, ordering = sort, direction = ascending,
            hidden = showHidden, searching = isSearch
        guard !items.isEmpty else { orderingCache = nil; sortedCache = []; sorting = false; return }
        sorting = true
        orderingTask = Task { [weak self] in
            do {
                let prepared = try await FileOrdering.prepareCached(
                    items, sort: ordering, ascending: direction, showHidden: hidden,
                    isSearch: searching, previous: previous)
                guard !Task.isCancelled, let self, self.orderingGeneration == revision else {
                    return
                }
                self.selectedCache = nil
                self.orderingCache = prepared
                self.sortedCache = prepared.ordered
                self.sorting = false
                self.saveDefaultSnapshot()
            } catch is CancellationError {} catch {
                guard let self, self.orderingGeneration == revision else { return }
                self.error = error.localizedDescription
                self.sorting = false
            }
        }
    }
    private func publish(_ items: [Hit], prepared: FileOrdering.Cache) {
        hits = items
        orderingTask?.cancel(); orderingGeneration += 1
        orderingCache = prepared
        sortedCache = prepared.ordered
        sorting = false
    }
    private var generation = 0
    private var statusStarted = false
    private var watchTask: Task<Void, Never>?
    private var watchGeneration = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var metadata: NSMetadataQuery?
    private var metadataObserver: NSObjectProtocol?
    var canWriteHere: Bool { !isSearch && route != "recents" && !route.hasPrefix("tag:") }
    var isSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// True while results come from the content index rather than the name index.
    var contentActive: Bool { contentSearch && isSearch }
    func matches(for path: String) -> [ContentMatch] {
        contentFiles.first { $0.path == path }?.matches ?? []
    }
    private func clearContentResults() {
        contentFiles = []; contentSource = ""; contentComplete = true; contentIndexing = 0
    }
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
        let items = sortedHits
        let result: [Hit]
        // Dense selections are cheaper to scan in display order than to sort
        // thousands of individual lookups. Sparse selections never scan all rows.
        if selection.count > (items.count + extraHits.count) / 4 {
            var seen = Set<String>()
            result = (items + extraHits.filter { showHidden || !$0.name.hasPrefix(".") })
                .filter { selection.contains($0.path) && seen.insert($0.path).inserted }
        } else {
            let rows = rowsByPath
            if extraRowIndex == nil { extraRowIndex = Self.indexRows(extraHits) }
            let extras = extraRowIndex!
            result = selection.compactMap { path -> (Int, Hit)? in
                if let row = rows[path] { return (row, items[row]) }
                if let row = extras[path] {
                    let hit = extraHits[row]
                    if showHidden || !hit.name.hasPrefix(".") {
                        return (items.count + row, hit)
                    }
                }
                return nil
            }.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        selectedCache = result
        return result
    }
    var sortedHits: [Hit] {
        if let sortedCache { return sortedCache }
        if let visibleCache { return visibleCache }
        // Rows stay usable while their requested ordering is prepared off-thread.
        let visible = showHidden ? hits : hits.filter { !$0.name.hasPrefix(".") }
        visibleCache = visible
        return visible
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
            let start = rowsByPath[anchor],
            let end = rowsByPath[hit.path]
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
        let rows = rowsByPath
        let current = focusedPath.flatMap { rows[$0] }
        let next =
            current.map { min(items.count - 1, max(0, $0 + delta)) }
            ?? (delta < 0 ? items.count - 1 : 0)
        let target = items[next].path
        if extending {
            let anchor = selectionAnchor ?? focusedPath ?? target
            let start = rows[anchor] ?? next
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
        cancelRename()
        mutationError = nil
        prefetchTask?.cancel()
        saveDefaultSnapshot()
        changingLocation = true
        if history && url != location { backStack.append(location); forwardStack = [] }
        if url.standardizedFileURL != location { scrollAnchor = nil; scrollOffset = 0 }
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
        cancelRename()
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
    /// Flush only a pending debounce; Return must not restart an in-flight search.
    func submitSearch() {
        guard isSearch, searchDebouncing else { return }
        schedule(immediate: true)
    }

    /// Content search replies carry paths only; read the attributes the views
    /// and sort need, off the main actor, keeping the engine's ranking.
    static func hits(fromPaths paths: [String]) async -> [Hit] {
        await Task.detached(priority: .userInitiated) {
            paths.compactMap { try? Hit.read(URL(fileURLWithPath: $0)) }
        }.value
    }
    func schedule(immediate: Bool = false) {
        guard !changingLocation else { return }
        generation += 1; let revision = generation
        task?.cancel()
        searchDebouncing = false
        guard !busy else { return }
        error = mutationError
        if isSearch { extraHits = [] }
        let searchingNow = isSearch
        let contentNow = contentActive
        let cached = !searchingNow && restoreDefaultSnapshot()
        if route.hasPrefix("tag:") && !isSearch { loadTag(String(route.dropFirst(4))); return }
        let folder = location, hidden = showHidden, text = query, searchScope = scope,
            type = fileType
        let recent = route == "recents" && !isSearch
        loading = !searchingNow && !cached; searching = searchingNow
        searchDebouncing = searchingNow && !immediate
        task = Task {
            do {
                var result: [Hit] = []
                var contentReply: [ContentFile]?
                var contentMeta: (source: String, complete: Bool, indexing: Int)?
                if searchingNow || recent {
                    if searchingNow && !immediate {
                        try await Task.sleep(for: searchDebounce)
                    }
                    try Task.checkCancellation()
                    searchDebouncing = false
                    var fields: [String: Any] = [
                        "q": recent ? "mtime:<30d kind:file" : text, "limit": recent ? 1000 : 500,
                    ]
                    if recent {
                        fields["in"] = NSHomeDirectory()
                    } else if !searchScope.isEmpty {
                        fields["in"] = searchScope
                    }
                    if contentNow {
                        // Content search: the pattern is what to look for inside
                        // files. Filename tokens, and the recency/kind filters
                        // of the browsing views, stay out of the request, so the
                        // Kind picker resets to Any Kind when contents are
                        // searched.
                        fields["op"] = "grep"
                        fields["pattern"] = text
                        fields["q"] = ""
                        fields["mode"] = contentMode
                        fields["per_file"] = 3
                        fields["budget_ms"] = 4000
                        // Directories never match contents.
                        if !type.isEmpty, type != "dir" { fields["type"] = type }
                    } else if type == "dir" {
                        fields["kind"] = "dir"
                    } else if !type.isEmpty {
                        fields["type"] = type
                    }
                    let reply = try await engine.request(fields)
                    guard reply.ok else {
                        throw Engine.Failure.message(reply.error ?? "Search failed")
                    }
                    if contentNow {
                        contentReply = reply.files ?? []
                        contentMeta = (
                            reply.source ?? "", reply.complete ?? true, reply.indexing ?? 0
                        )
                        result = await SearchModel.hits(fromPaths: contentReply!.map(\.path))
                    } else {
                        result = reply.hits ?? []
                    }
                    if revision == generation { elapsed = Double(reply.took_us ?? 0) / 1000 }
                } else {
                    if !cached {
                        await Task.yield()
                        let preview = try await folderPreviewLoader(folder, hidden)
                        let prepared = try await FileOrdering.prepareCached(
                            preview, sort: .name, ascending: true, showHidden: hidden,
                            isSearch: false)
                        guard revision == generation, !Task.isCancelled else { return }
                        publish(preview, prepared: prepared)
                        // Keep loading true while details fill in; the nonempty
                        // preview is already visible and can be selected.
                        await Task.yield()
                    }
                    result = try await folderLoader(folder, hidden)
                }
                guard revision == generation, !Task.isCancelled else { return }
                if let contentReply {
                    // A superseded reply must never replace the state of the
                    // query the user is looking at, so it lands after the guard.
                    contentFiles = contentReply
                    contentSource = contentMeta?.source ?? ""
                    contentComplete = contentMeta?.complete ?? true
                    contentIndexing = contentMeta?.indexing ?? 0
                }
                var prepared: FileOrdering.Cache
                while true {
                    let ordering = sort, direction = ascending, visibility = showHidden
                    prepared = try await FileOrdering.prepareCached(
                        result, sort: ordering, ascending: direction, showHidden: visibility,
                        isSearch: searchingNow, previous: orderingCache)
                    guard revision == generation, !Task.isCancelled else { return }
                    if ordering == sort && direction == ascending && visibility == showHidden {
                        break
                    }
                }
                publish(result, prepared: prepared)
                selection.formIntersection(
                    Set(
                        (sortedHits + extraHits.filter { showHidden || !$0.name.hasPrefix(".") })
                            .map(\.path)))
                loading = false; searching = false
                if !searchingNow {
                    saveDefaultSnapshot()
                    if canWriteHere {
                        prefetchFolders(
                            Self.prefetchCandidates(in: prepared.ordered))
                    }
                }
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
        if sort == snapshot.sort && ascending == snapshot.ascending, let ordered = snapshot.ordered
        {
            orderingTask?.cancel(); orderingGeneration += 1
            orderingCache = nil
            sortedCache = ordered
            sorting = false
        }
        // The previous ordering can still be visible while the restored rows
        // sort in the background. Reconcile against the snapshot itself.
        selection.formIntersection(
            Set(
                snapshot.hits.filter {
                    showHidden || !$0.name.hasPrefix(".")
                }.map(\.path)))
        elapsed = 0
        return true
    }
    private func saveDefaultSnapshot() {
        guard !isSearch, !loading, !busy else { return }
        let key = SnapshotKey(route: route, hidden: showHidden)
        snapshots[key] = Snapshot(
            hits: hits, selection: selection, sort: sort, ascending: ascending, ordered: sortedCache
        )
        trimSnapshots(keeping: key)
    }
    private func trimSnapshots(keeping key: SnapshotKey) {
        snapshotOrder.removeAll { $0 == key }; snapshotOrder.append(key)
        while snapshotOrder.count > 8
            || (snapshots.values.reduce(0) { $0 + $1.hits.count } > 40000
                && snapshotOrder.count > 1)
        {
            snapshots.removeValue(forKey: snapshotOrder.removeFirst())
        }
    }
    static func prefetchCandidates(in items: [Hit]) -> [URL] {
        var candidates: [URL] = []
        candidates.reserveCapacity(3)
        // Explicitly stop here: lazy Collection.filter/prefix can scan beyond
        // the third match while computing its end index and count.
        for hit in items where hit.isFolder {
            candidates.append(hit.url)
            if candidates.count == 3 { break }
        }
        return candidates
    }
    @discardableResult func prefetchFolder(_ folder: URL) -> Task<Void, Never>? {
        prefetchFolders([folder])
    }
    @discardableResult private func prefetchFolders(_ folders: [URL]) -> Task<Void, Never>? {
        guard !busy else { return nil }
        prefetchTask?.cancel()
        let hidden = showHidden
        let candidates = folders.filter {
            let path = $0.standardizedFileURL.path
            // Avoid speculative reads of network/cloud and consent-gated folders.
            guard !path.hasPrefix("/Volumes/"), !path.hasPrefix("/Network/"),
                !path.contains("/Library/Mobile Documents"), !path.contains("/Library/CloudStorage")
            else { return false }
            if !fullDiskAccess {
                for name in ["Documents", "Desktop", "Downloads", "Pictures", "Library"] {
                    let protected = NSHomeDirectory() + "/" + name
                    if path == protected || path.hasPrefix(protected + "/") { return false }
                }
            }
            return snapshots[SnapshotKey(route: path, hidden: hidden)] == nil
        }
        let loader = folderLoader
        prefetchTask = Task { [weak self] in
            for folder in candidates {
                guard !Task.isCancelled else { return }
                do {
                    let hits = try await loader(folder, hidden)
                    let ordered = try await FileOrdering.prepare(
                        hits, sort: .name, ascending: true, showHidden: hidden, isSearch: false)
                    guard !Task.isCancelled, let self else { return }
                    let key = SnapshotKey(route: folder.standardizedFileURL.path, hidden: hidden)
                    guard self.snapshots[key] == nil else { continue }
                    self.snapshots[key] = Snapshot(
                        hits: hits, selection: [], sort: .name,
                        ascending: true, ordered: ordered)
                    self.trimSnapshots(keeping: key)
                } catch { if Task.isCancelled { return } }
            }
        }
        return prefetchTask
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
            await refreshStatus()
            try? await Task.sleep(for: .seconds(5))
        }; statusStarted = false
    }
    func refreshStatus() async {
        // The shared daemon's status describes its startup restrictions, which
        // can outlive a permission change or a restart of the app.
        let check = diskAccessCheck
        let granted = await Task.detached(priority: .utility) { check() }.value
        if fullDiskAccess != granted { fullDiskAccess = granted }
        do {
            let status = try await engine.request(["op": "status"])
            let becameReady = status.ok && !ready; if ready != status.ok { ready = status.ok }
            if status.ok {
                if entries != status.entries ?? 0 { entries = status.entries ?? 0 }
                if becameReady && (isSearch || route == "recents") { schedule() }
            }
        } catch { if isSearch { self.error = error.localizedDescription } }
    }
    func open(_ item: Hit? = nil) {
        guard !busy else { return }
        if let item {
            guard item.kind != "pending" else { return }
            if item.isFolder {
                navigate(item.url)
            } else if !NSWorkspace.shared.open(item.url) {
                error = "Could not open ‘\(item.name)’."
            }; return
        }
        for hit in selectedItems {
            guard hit.kind != "pending" else { continue }
            if hit.isFolder && selection.count == 1 { navigate(hit.url); return };
            if !NSWorkspace.shared.open(hit.url) { error = "Could not open ‘\(hit.name)’." }
        }
    }
    func perform(
        _ operations: [FileMutation], name: String, history: Int = 0,
        renameCreated: URL? = nil
    ) {
        guard !operations.isEmpty, !busy else { return }; busy = true; error = nil
        cancelRename()
        mutationError = nil
        operationName = name
        let operationID = UUID(); activeOperationID = operationID
        let control = FileOperationControl { [weak self] progress in
            Task { @MainActor in
                guard self?.activeOperationID == operationID else { return }
                self?.operationProgress = progress
            }
        }
        operationControl = control
        task?.cancel(); prefetchTask?.cancel(); generation += 1
        snapshots.removeAll(); snapshotOrder.removeAll()
        let originalHits = hits, originalExtra = extraHits, originalSelection = selection
        let originalOrder = sortedHits
        let folder = canWriteHere ? location : nil
        hits = OptimisticFiles.applying(operations, to: originalHits, in: folder)
        visibleCache = OptimisticFiles.applying(operations, to: originalOrder, in: folder)
        extraHits = OptimisticFiles.applying(operations, to: originalExtra, in: nil)
        selection = OptimisticFiles.selection(
            originalSelection, after: operations, visibleHits: hits + extraHits)
        loading = false; searching = false
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LocalFiles.apply(operations, control: control)
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
            var successful = operations
            for failed in result.failed {
                if let index = successful.firstIndex(of: failed) { successful.remove(at: index) }
            }
            hits = OptimisticFiles.applying(successful, to: originalHits, in: folder)
            visibleCache = OptimisticFiles.applying(successful, to: originalOrder, in: folder)
            extraHits = OptimisticFiles.applying(successful, to: originalExtra, in: nil)
            selection = OptimisticFiles.selection(
                originalSelection, after: successful, visibleHits: hits + extraHits)
            busy = false
            operationControl = nil; activeOperationID = nil; operationProgress = nil
            if !result.errors.isEmpty { mutationError = result.errors.joined(separator: "\n") }
            var relocated = location.path
            for operation in successful {
                if case .move(let source, let destination) = operation,
                    relocated == source.path || relocated.hasPrefix(source.path + "/")
                {
                    relocated = destination.path + relocated.dropFirst(source.path.count)
                }
            }
            if relocated != location.path {
                let failure = mutationError
                navigate(URL(fileURLWithPath: relocated, isDirectory: true), history: false)
                mutationError = failure; error = failure
                return
            }
            saveDefaultSnapshot(); schedule()
            if let renameCreated, result.failed.isEmpty,
                let created = hits.first(where: { $0.path == renameCreated.path })
            {
                beginRename(created)
            }
        }
    }
    func prepareOperations(
        name: String, renameCreated: Bool = false,
        _ prepare: @escaping @Sendable () throws -> [FileMutation]
    ) {
        guard !busy else { return }
        busy = true; error = nil; mutationError = nil
        operationName = name
        operationProgress = FileOperationProgress()
        preparationTask = Task {
            do {
                let operations = try await BackgroundWork.run(prepare)
                try Task.checkCancellation()
                busy = false
                operationProgress = nil
                if operations.isEmpty {
                    schedule()
                } else {
                    let created: URL?
                    if renameCreated, let first = operations.first {
                        switch first {
                        case .folder(let url), .textFile(let url): created = url
                        default: created = nil
                        }
                    } else {
                        created = nil
                    }
                    perform(operations, name: name, renameCreated: created)
                }
            } catch is CancellationError {
                busy = false; operationProgress = nil; schedule()
            } catch {
                busy = false
                operationProgress = nil
                mutationError = error.localizedDescription
                schedule()
            }
        }
    }
    func cancelOperation() {
        preparationTask?.cancel(); operationControl?.cancel(); resolveConflict(.cancel)
    }
    func beginRename(_ hit: Hit) {
        guard !busy else { return }
        selection = [hit.path]; error = nil; renaming = hit
    }
    func cancelRename() {
        if renaming != nil { error = nil }
        renaming = nil
    }
    @discardableResult func commitRename(_ name: String) -> Bool {
        guard !busy, let hit = renaming else { return false }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
            !name.contains(":"), !name.contains("\0")
        else { error = "Choose a valid filename without slashes or colons."; return false }
        renaming = nil; error = nil
        guard name != hit.name else { return true }
        perform(
            [.move(hit.url, hit.url.deletingLastPathComponent().appendingPathComponent(name))],
            name: "Rename")
        return true
    }
    func undo() {
        guard !busy, let journal = undoStack.popLast() else { return };
        perform(journal.operations, name: journal.name, history: 1)
    }
    func redo() {
        guard !busy, let journal = redoStack.popLast() else { return };
        perform(journal.operations, name: journal.name, history: 2)
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
                let paths = query.results.compactMap { value -> String? in
                    guard let item = value as? NSMetadataItem,
                        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                    else { return nil }; return path
                }
                query.stop()
                self.loadTagResults(paths, token: token)
            }
        }
        metadata = q; q.start()
    }
    private func loadTagResults(_ paths: [String], token: Int) {
        task = Task {
            do {
                let result = try await BackgroundWork.run {
                    try paths.compactMap { path -> Hit? in
                        try Task.checkCancellation()
                        return try? Hit.read(URL(fileURLWithPath: path))
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                hits = result
                loading = false
                // The normal presentation task sorts and saves the snapshot.
            } catch is CancellationError {} catch {
                guard generation == token else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    deinit {
        watchTask?.cancel(); task?.cancel(); prefetchTask?.cancel(); orderingTask?.cancel()
        preparationTask?.cancel(); operationControl?.cancel()
        watchRefresh?.cancel(); watcher?.cancel();
        metadata?.stop();
        if let metadataObserver { NotificationCenter.default.removeObserver(metadataObserver) }
    }
}

@MainActor final class BrowserWorkspace: ObservableObject {
    @Published var tabs: [SearchModel] = [SearchModel()] {
        didSet { observeSession(); saveSession() }
    }
    @Published var selectedTab = UUID()
    @Published var favorites: [String] =
        UserDefaults.standard.stringArray(forKey: "favorites") ?? []
    @Published private(set) var volumes: [MountedVolume] = []
    @Published private(set) var ejectingVolumes: Set<String> = []
    private let volumeLoader: @Sendable () async throws -> [MountedVolume]
    private let volumeEjector: @Sendable (URL) async throws -> Void
    private var volumeTask: Task<Void, Never>?
    private var volumeGeneration = 0
    let sessionDefaults: UserDefaults?
    var sessionObservers: [AnyCancellable] = []
    private var terminationObserver: AnyCancellable?
    var closedTabs: [TabSession] = []
    init(
        volumeLoader: @escaping @Sendable () async throws -> [MountedVolume] = {
            try await MountedVolume.load()
        },
        volumeEjector: @escaping @Sendable (URL) async throws -> Void = {
            try await MountedVolume.eject($0)
        },
        sessionDefaults: UserDefaults? = nil
    ) {
        self.volumeLoader = volumeLoader; self.volumeEjector = volumeEjector
        self.sessionDefaults = sessionDefaults
        if let data = sessionDefaults?.data(forKey: WorkspaceSession.key),
            let state = try? JSONDecoder().decode(WorkspaceSession.self, from: data),
            !state.tabs.isEmpty, state.tabs.count <= 50
        {
            tabs = state.tabs.map { $0.restore() }
            selectedTab = tabs[min(max(0, state.selectedIndex), tabs.count - 1)].id
        } else {
            selectedTab = tabs[0].id
        }
        observeSession()
        terminationObserver = NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification
        )
        .sink { [weak self] _ in self?.saveSession() }
        refreshVolumes()
    }
    var current: SearchModel { tabs.first { $0.id == selectedTab } ?? tabs[0] }
    func newTab(_ location: URL? = nil) {
        let tab = SearchModel(); tab.navigate(location ?? current.location); tabs.append(tab);
        selectedTab = tab.id
    }
    func closeTab(_ id: UUID) {
        guard tabs.count > 1, tabs.first(where: { $0.id == id })?.busy != true else { return };
        if let tab = tabs.first(where: { $0.id == id }) {
            closedTabs.append(TabSession(tab));
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
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
        volumeTask?.cancel(); volumeGeneration += 1
        let generation = volumeGeneration, loader = volumeLoader
        volumeTask = Task { [weak self] in
            do {
                let volumes = try await loader()
                guard !Task.isCancelled, let self, self.volumeGeneration == generation else {
                    return
                }
                self.volumes = volumes
            } catch { /* Keep the current locations if a refresh is unavailable. */  }
        }
    }
    func eject(_ volume: MountedVolume, reportError: @escaping (String) -> Void) {
        guard volume.canEject, volumes.contains(volume), !ejectingVolumes.contains(volume.id) else {
            return
        }
        guard
            !tabs.contains(where: { tab in
                tab.busy
                    && (tab.location.path == volume.id
                        || tab.location.path.hasPrefix(volume.id + "/"))
            })
        else {
            reportError("Wait for the file operation to finish before ejecting ‘\(volume.name)’.")
            return
        }
        ejectingVolumes.insert(volume.id)
        let ejector = volumeEjector
        Task {
            defer { ejectingVolumes.remove(volume.id) }
            do {
                try await ejector(volume.url)
                volumes.removeAll { $0.id == volume.id }
                for tab in tabs
                where tab.location.path == volume.id || tab.location.path.hasPrefix(volume.id + "/")
                {
                    tab.navigate(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
                }
                refreshVolumes()
            } catch {
                reportError("Could not eject ‘\(volume.name)’: \(error.localizedDescription)")
            }
        }
    }
    deinit { volumeTask?.cancel() }
}
