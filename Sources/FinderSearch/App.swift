import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

@main struct FinderSearchApp: App {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var model: SearchModel?
    @FocusedObject private var workspace: BrowserWorkspace?
    var body: some Scene {
        WindowGroup(id: "browser") {
            BrowserRoot().frame(minWidth: 850, minHeight: 470).onAppear {
                NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            }
        }
        .defaultSize(width: 1050, height: 680).windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "browser") }.keyboardShortcut("n")
                Button("New Tab") { workspace?.newTab() }.keyboardShortcut("t")
                Button("New Folder") { model?.newFolder() }.keyboardShortcut(
                    "n", modifiers: [.command, .shift]
                ).disabled(model?.busy != false || model?.canWriteHere != true)
                Button("Open…") { model?.chooseFolder() }.keyboardShortcut(
                    "o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model?.undoStack.last.map { "Undo \($0.name)" } ?? "Undo") {
                    textOrFile("undo:") { model?.undo() }
                }.keyboardShortcut("z")
                Button(model?.redoStack.last.map { "Redo \($0.name)" } ?? "Redo") {
                    textOrFile("redo:") { model?.redo() }
                }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { textOrFile("copy:") { model?.copy() } }.keyboardShortcut("c")
                Button("Paste Items") { textOrFile("paste:") { model?.paste() } }.keyboardShortcut(
                    "v")
                Button("Move Items Here") { model?.paste(move: true) }.keyboardShortcut(
                    "v", modifiers: [.command, .option]
                ).disabled(model?.busy != false || model?.canWriteHere != true)
                Button("Select All") {
                    textOrFile("selectAll:") {
                        if let model { model.selection = Set(model.sortedHits.map(\.path)) }
                    }
                }.keyboardShortcut("a")
            }
            CommandGroup(after: .newItem) {
                Button("Open Selected") { model?.open() }.keyboardShortcut("o").disabled(
                    model?.selection.isEmpty != false)
                Button("Rename") { model?.rename() }.disabled(
                    model?.selection.count != 1 || model?.busy == true)
                Button("Duplicate") { model?.duplicate() }.keyboardShortcut("d").disabled(
                    model?.selection.isEmpty != false || model?.busy == true)
                Button("Move to Trash") {
                    textOrFile("deleteToBeginningOfLine:") { model?.trash() }
                }.keyboardShortcut(.delete)
                Button("Get Info") { model?.info() }.keyboardShortcut("i").disabled(
                    model?.selection.isEmpty != false)
                Button("Quick Look") { model?.preview = model?.selected }.keyboardShortcut("y")
                    .disabled(model?.selection.isEmpty != false)
            }
            CommandMenu("Go") {
                Button("Back") { model?.goBack() }.keyboardShortcut("[").disabled(
                    model?.backStack.isEmpty != false)
                Button("Forward") { model?.goForward() }.keyboardShortcut("]").disabled(
                    model?.forwardStack.isEmpty != false)
                Button("Enclosing Folder") {
                    if let model { model.navigate(model.location.deletingLastPathComponent()) }
                }.keyboardShortcut(.upArrow)
                Button("Go to Folder…") { model?.goToFolder() }.keyboardShortcut(
                    "g", modifiers: [.command, .shift])
                Button("Home") { model?.navigate(FileManager.default.homeDirectoryForCurrentUser) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                ForEach(FileViewMode.allCases.indices, id: \.self) { index in
                    Button("As \(FileViewMode.allCases[index].title)") {
                        model?.viewMode = FileViewMode.allCases[index]
                    }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Button("Show Hidden Files") { model?.showHidden.toggle() }.keyboardShortcut(
                    ".", modifiers: [.command, .shift])
                Button("Refresh") { model?.schedule() }.keyboardShortcut("r")
                Button("Search") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }.keyboardShortcut("f")
            }
        }
    }
    private func textOrFile(_ selector: String, action: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: nil)
        } else {
            action()
        }
    }
}
extension Notification.Name { static let focusSearch = Notification.Name("focusSearch") }
struct BrowserRoot: View {
    @StateObject private var workspace = BrowserWorkspace()
    var body: some View {
        BrowserView(workspace: workspace, model: workspace.current).id(workspace.selectedTab)
            .focusedSceneObject(workspace).focusedSceneObject(workspace.current)
    }
}

struct BrowserView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var model: SearchModel
    @FocusState private var filesFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var fileNavigationActive = false
    @State private var keyMonitor: Any?
    @State private var iconSize: Double = 64
    @State private var gridColumns = 5
    private let home = NSHomeDirectory()
    private let tags: [(String, Color)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green), ("Blue", .blue),
        ("Purple", .purple), ("Gray", .gray),
    ]
    var body: some View {
        NavigationSplitView {
            List(
                selection: Binding(
                    get: { model.route },
                    set: {
                        fileNavigationActive = false; model.sidebar($0)
                    })
            ) {
                Label("Recents", systemImage: "clock").tag("recents")
                Section("Favorites") {
                    sidebar("Applications", "a.square", "/Applications")
                    sidebar("Documents", "doc", home + "/Documents")
                    sidebar("Downloads", "arrow.down.circle", home + "/Downloads")
                    sidebar("Desktop", "menubar.dock.rectangle", home + "/Desktop")
                    sidebar("Pictures", "photo", home + "/Pictures")
                    sidebar("Music", "music.note", home + "/Music")
                    sidebar("Movies", "film", home + "/Movies")
                    ForEach(workspace.favorites, id: \.self) { path in
                        sidebar(URL(fileURLWithPath: path).lastPathComponent, "folder", path)
                            .contextMenu {
                                Button("Remove from Sidebar") { workspace.removeFavorite(path) }
                            }
                    }
                }
                Section("Locations") {
                    sidebar(
                        "iCloud Drive", "icloud",
                        home + "/Library/Mobile Documents/com~apple~CloudDocs")
                    sidebar(URL(fileURLWithPath: home).lastPathComponent, "house", home)
                    ForEach(workspace.volumes, id: \.path) { url in
                        sidebar(
                            url.path == "/" ? "Macintosh HD" : url.lastPathComponent,
                            "externaldrive", url.path)
                    }
                }
                Section("Tags") {
                    ForEach(tags, id: \.0) { name, color in
                        Label {
                            Text(name)
                        } icon: {
                            Image(systemName: "circle.fill").font(.system(size: 10))
                                .foregroundStyle(color)
                        }.tag("tag:" + name)
                    }
                }
            }
            .listStyle(.sidebar).navigationSplitViewColumnWidth(min: 170, ideal: 208, max: 280)
            .safeAreaInset(edge: .bottom) {
                if model.ready && !model.fullDiskAccess {
                    Button("Enable Full Disk Access…") {
                        NSWorkspace.shared.open(
                            URL(
                                string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                            )!)
                    }.font(.caption).padding(12)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if workspace.tabs.count > 1 { tabBar }
                if model.isSearch { searchScopeBar }
                if let error = model.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle");
                        Text(error).font(.callout).textSelection(.enabled); Spacer();
                        Button {
                            model.error = nil
                        } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.plain)
                    }.padding(12).background(Color(nsColor: .controlBackgroundColor)); Divider()
                }
                fileContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(SafeBackgroundDropTarget(model: model))
                    .focusable(model.viewMode == .icons || model.viewMode == .gallery).focused(
                        $filesFocused
                    ).focusEffectDisabled()
                pathBar
                statusBar
            }
            .navigationTitle(model.isSearch ? "Searching “\(model.query)”" : model.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button {
                            model.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }.disabled(model.backStack.isEmpty).help("Back")
                        Button {
                            model.goForward()
                        } label: {
                            Image(systemName: "chevron.right")
                        }.disabled(model.forwardStack.isEmpty).help("Forward")
                    }
                }
                ToolbarItem {
                    Picker("View", selection: $model.viewMode) {
                        ForEach(FileViewMode.allCases, id: \.self) { mode in
                            Image(systemName: mode.symbol).tag(mode).help(mode.title)
                        }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                ToolbarItem {
                    Menu {
                        Picker("Sort By", selection: $model.sort) {
                            ForEach(FileSort.allCases, id: \.self) { sort in
                                Text(sort.rawValue).tag(sort)
                            }
                        }
                        Toggle("Ascending", isOn: $model.ascending)
                        Toggle("Show Hidden Files", isOn: $model.showHidden)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }.help("Sort")
                }
                ToolbarItem {
                    ShareLink(items: model.selectedItems.map(\.url)) {
                        Image(systemName: "square.and.arrow.up")
                    }.disabled(model.selection.isEmpty).help("Share")
                }
                ToolbarItem {
                    Menu {
                        ForEach(tags, id: \.0) { name, _ in Button(name) { model.tag(name) } }
                    } label: {
                        Image(systemName: "tag")
                    }.disabled(model.selection.isEmpty).help("Tags")
                }
                ToolbarItem {
                    Menu {
                        actions
                    } label: {
                        Image(systemName: "ellipsis")
                    }.help("Actions")
                }
            }
            .searchable(text: $model.query, placement: .toolbar, prompt: "Search")
            .searchFocused($searchFocused)
        }
        .onAppear {
            model.start()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if searchFocused && event.keyCode == 125 && !model.sortedHits.isEmpty {
                    focusFiles(); model.selection = [model.sortedHits[0].path]; return nil
                }
                guard NSApp.keyWindow?.isSheet != true, model.preview == nil,
                    fileNavigationActive && !searchFocused,
                    !(NSApp.keyWindow?.firstResponder is NSTextView)
                else { return event }
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    if event.keyCode == 49 { model.preview = model.selected; return nil }
                    if event.keyCode == 36 { model.rename(); return nil }
                    if event.keyCode == 53 { model.selection = []; return nil }
                    if (model.viewMode == .icons || model.viewMode == .gallery),
                        [123, 124, 125, 126].contains(event.keyCode)
                    {
                        let stride = model.viewMode == .gallery ? 1 : gridColumns
                        let delta =
                            event.keyCode == 123
                            ? -1
                            : event.keyCode == 124 ? 1 : event.keyCode == 125 ? stride : -stride
                        model.moveSelection(
                            by: delta, extending: event.modifierFlags.contains(.shift))
                        return nil
                    }
                }
                if event.modifierFlags.contains(.command), event.keyCode == 125 {
                    model.open(); return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            fileNavigationActive = false; model.sort = .relevance; searchFocused = true
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
        ) { _ in workspace.refreshVolumes() }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
        ) { _ in workspace.refreshVolumes() }
        .onChange(of: model.viewMode) { _, _ in
            model.extraHits = []; model.selection.formIntersection(Set(model.hits.map(\.path)))
        }
        .onChange(of: searchFocused) { _, focused in if focused { fileNavigationActive = false } }
        .onChange(of: model.query) { _, text in
            if model.isSearch && model.sort != .relevance { model.sort = .relevance }
        }
        .task { await model.monitor() }
        .sheet(item: $model.preview) { hit in
            VStack(spacing: 0) {
                HStack {
                    Text(hit.name).font(.headline).lineLimit(1); Spacer();
                    Button("Open") {
                        model.open(hit); model.preview = nil
                    }; Button("Done") { model.preview = nil }.keyboardShortcut(.cancelAction)
                }.padding(); Divider(); QuickLook(url: hit.url).frame(minWidth: 650, minHeight: 470)
            }
        }
    }
    private func sidebar(_ name: String, _ symbol: String, _ path: String) -> some View {
        Label(name, systemImage: symbol).tag(path)
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(workspace.tabs) { tab in
                HStack(spacing: 8) {
                    Button {
                        workspace.selectedTab = tab.id
                    } label: {
                        Text(tab.title).lineLimit(1).frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                    Button {
                        workspace.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10))
                    }.buttonStyle(.plain).help("Close Tab").disabled(tab.busy)
                }.padding(.horizontal, 12).padding(.vertical, 8).background(
                    tab.id == workspace.selectedTab
                        ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                Divider()
            }
            Button {
                workspace.newTab()
            } label: {
                Image(systemName: "plus")
            }.buttonStyle(.plain).padding(.horizontal, 12).help("New Tab")
        }.frame(height: 32).background(Color(nsColor: .windowBackgroundColor))
    }
    private var searchScopeBar: some View {
        HStack(spacing: 10) {
            Text("Search:").foregroundStyle(.secondary)
            Button("This Mac") { model.scope = "" }.buttonStyle(.bordered).tint(
                model.scope.isEmpty ? .accentColor : .secondary)
            Button(model.location.lastPathComponent) { model.scope = model.location.path }
                .buttonStyle(.bordered).tint(model.scope.isEmpty ? .secondary : .accentColor)
            Spacer()
            Picker("Kind", selection: $model.fileType) {
                Text("Any Kind").tag(""); Text("Folder").tag("dir"); Text("Document").tag("doc");
                Text("Image").tag("image"); Text("Movie").tag("video"); Text("Audio").tag("audio")
            }.labelsHidden().frame(width: 130)
        }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 7).background(
            Color(nsColor: .controlBackgroundColor))
    }
    @ViewBuilder private var fileContent: some View {
        if model.viewMode == .columns && model.canWriteHere {
            ColumnBrowser(model: model, focusFiles: { focusFiles() })
        } else if (model.loading || model.searching) && model.sortedHits.isEmpty {
            FolderLoadingSkeleton(mode: model.viewMode, iconSize: iconSize)
        } else if model.sortedHits.isEmpty {
            ContentUnavailableView {
                Label(
                    model.isSearch ? "No Results" : "No Items",
                    systemImage: model.isSearch ? "magnifyingglass" : "folder")
            } description: {
                Text(
                    model.isSearch
                        ? "Try a different name or search location." : "This folder is empty.")
            }
        } else {
            switch model.viewMode {
            case .icons: iconGrid
            case .list: fileTable
            case .columns:
                fileTable
            case .gallery: GalleryBrowser(model: model, select: select)
            }
        }
    }
    private var iconGrid: some View {
        GeometryReader { geometry in
            iconScroll
                .onAppear { updateColumns(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
                .onChange(of: iconSize) { _, _ in updateColumns(geometry.size.width) }
        }
    }
    private func updateColumns(_ width: Double) {
        gridColumns = max(1, Int((width - 36) / (iconSize + 69)))
    }
    private var iconScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: iconSize + 55), spacing: 14)],
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(model.sortedHits) { hit in iconCell(hit) }
                }.padding(18)
            }
            .onChange(of: model.focusedPath) { _, path in if let path { proxy.scrollTo(path) } }
        }
        .contextMenu {
            Button("New Folder") { model.newFolder() }
            Button("Paste Items") { model.paste() }
            Button("Add to Sidebar") { workspace.addFavorite(model.location) }
        }
    }
    private func iconCell(_ hit: Hit) -> some View {
        VStack(spacing: 6) {
            FileThumbnail(hit: hit, size: iconSize).frame(
                width: iconSize + 10, height: iconSize + 10)
            Text(hit.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)
        }
        .padding(6).frame(maxWidth: .infinity)
        .background(
            model.selection.contains(hit.path) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle()).onTapGesture(count: 2) {
            select(hit); model.open(hit)
        }.onTapGesture { select(hit) }
        .contextMenu { rowActions(hit) }.draggable(hit.url)
        .modifier(FolderDropTarget(hit: hit, model: model))
        .id(hit.path)
        .accessibilityLabel(hit.name).accessibilityAddTraits(
            model.selection.contains(hit.path) ? [.isSelected] : [])
    }
    private var fileTable: some View {
        FileList(model: model, focusFiles: focusFiles, newTab: { workspace.newTab($0) })
    }
    private var pathBar: some View {
        VStack(spacing: 0) {
            Divider();
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if !model.isSearch
                        && (model.route == "recents" || model.route.hasPrefix("tag:"))
                    {
                        Label(model.title, systemImage: model.route == "recents" ? "clock" : "tag")
                    } else {
                        ForEach(model.ancestors, id: \.path) { url in
                            Button {
                                model.navigate(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(
                                        systemName: url.path == "/"
                                            ? "internaldrive" : "folder.fill"
                                    ).font(.system(size: 11));
                                    Text(url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
                                }
                            }.buttonStyle(.plain)
                            if url != model.ancestors.last {
                                Image(systemName: "chevron.right").font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var statusBar: some View {
        HStack {
            if model.loading || model.searching || model.busy { ProgressView().controlSize(.mini) }
            Text(
                model.selection.isEmpty
                    ? (model.isSearch && model.hits.count == 500
                        ? "First 500 matches" : "\(model.sortedHits.count) items")
                    : "\(model.selection.count) selected")
            if model.isSearch { Text(String(format: "· %.1f ms", model.elapsed)).monospacedDigit() }
            Spacer()
            if model.viewMode == .icons {
                Image(systemName: "square").font(.system(size: 8));
                Slider(value: $iconSize, in: 40...96).frame(width: 100).accessibilityLabel(
                    "Icon Size");
                Image(systemName: "square").font(.system(size: 13))
            }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(
            height: 28
        ).background(Color(nsColor: .windowBackgroundColor))
    }
    @ViewBuilder private var actions: some View {
        Button("Open") { model.open() }.disabled(model.selection.isEmpty)
        Button("Open in New Tab") {
            if let hit = model.selected, hit.isFolder { workspace.newTab(hit.url) }
        }.disabled(model.selected?.isFolder != true)
        Divider()
        Button("Get Info") { model.info() }.disabled(model.selection.isEmpty)
        Button("Quick Look") { model.preview = model.selected }.disabled(model.selection.isEmpty)
        Button("Rename…") { model.rename() }.disabled(model.selection.count != 1 || model.busy)
        Button("Duplicate") { model.duplicate() }.disabled(model.selection.isEmpty || model.busy)
        Button("Copy") { model.copy() }.disabled(model.selection.isEmpty)
        Button("Copy Path") { model.copyPath() }.disabled(model.selection.isEmpty)
        Button("Paste Items") { model.paste() }.disabled(model.busy || !model.canWriteHere)
        Button("Move Items Here") { model.paste(move: true) }.disabled(
            model.busy || !model.canWriteHere)
        Divider()
        Button("New Folder") { model.newFolder() }.disabled(model.busy || !model.canWriteHere)
        Button("Add Folder to Sidebar") {
            workspace.addFavorite(
                model.selected?.isFolder == true ? model.selected!.url : model.location)
        }
        Button("Show in Finder") { model.reveal() }.disabled(model.selection.isEmpty)
        Divider()
        Button("Move to Trash") { model.trash() }.disabled(model.selection.isEmpty || model.busy)
    }
    @ViewBuilder private func rowActions(_ hit: Hit) -> some View {
        Button("Open") { model.open(hit) }
        Button("Open in New Tab") { workspace.newTab(hit.url) }.disabled(!hit.isFolder)
        Button("Quick Look") { model.preview = hit }
        Button("Open Enclosing Folder") { model.navigate(hit.url.deletingLastPathComponent()) }
        Divider()
        Button("Get Info") {
            contextual(hit); model.info()
        }
        Button("Rename…") {
            model.selection = [hit.path]; model.rename()
        }
        Button("Duplicate") {
            contextual(hit); model.duplicate()
        }
        Button("Copy") {
            contextual(hit); model.copy()
        }
        Button("Copy Path") {
            contextual(hit); model.copyPath()
        }
        Menu("Tags") {
            ForEach(tags, id: \.0) { name, _ in
                Button(name) {
                    contextual(hit); model.tag(name)
                }
            }
        }
        Divider()
        Button("Move to Trash") {
            contextual(hit); model.trash()
        }
    }
    private func contextual(_ hit: Hit) {
        if !model.selection.contains(hit.path) { model.selection = [hit.path] }
    }
    private func focusFiles() {
        searchFocused = false; fileNavigationActive = true
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        filesFocused = model.viewMode == .icons || model.viewMode == .gallery
    }
    private func select(_ hit: Hit) {
        focusFiles()
        model.select(
            hit, extending: NSEvent.modifierFlags.contains(.shift),
            toggling: NSEvent.modifierFlags.contains(.command))
    }

}

struct QuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)!
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
}
