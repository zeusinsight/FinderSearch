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
                ApplicationIcon.registerBundle()
                NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            }
        }
        .defaultSize(width: 1050, height: 680).windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "browser") }.keyboardShortcut("n")
                Button("New Tab") { workspace?.activePane.newTab() }.keyboardShortcut("t")
                Button("Reopen Closed Tab") { workspace?.activePane.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(workspace?.activePane.closedTabs.isEmpty != false)
                Button("New Folder") { model?.newFolder() }.keyboardShortcut(
                    "n", modifiers: [.command, .shift]
                ).disabled(model?.busy != false || model?.canWriteHere != true)
                Button("Open…") { model?.chooseFolder() }.keyboardShortcut(
                    "o", modifiers: [.command, .option])
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
                Button("Cut") { textOrFile("cut:") { model?.cut() } }.keyboardShortcut("x")
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
                Button("Rename…") { model?.renameItems() }.disabled(
                    model?.selection.isEmpty != false || model?.busy == true)
                Button("Compress") { model?.compress() }.disabled(
                    model?.selection.isEmpty != false || model?.busy == true
                        || model?.canWriteHere != true)
                Button("Extract ZIP") { model?.extract() }.disabled(
                    model?.selectedItems.contains { $0.url.pathExtension.lowercased() == "zip" }
                        != true || model?.busy == true)
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
                Divider()
                ForEach(GoDestination.allCases) { destination in
                    Button(destination.title) { model?.sidebar(destination.route) }
                        .keyboardShortcut(
                            KeyEquivalent(destination.key), modifiers: destination.modifiers
                        )
                        .disabled(model?.busy != false)
                }
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
extension Notification.Name {
    static let focusSearch = Notification.Name("focusSearch")
    static let focusBrowserFiles = Notification.Name("focusBrowserFiles")
    static let blurBrowserFiles = Notification.Name("blurBrowserFiles")
}
struct BrowserRoot: View {
    @StateObject private var workspace = BrowserWorkspace(sessionDefaults: .standard)
    var body: some View {
        BrowserView(workspace: workspace, model: workspace.current)
            .focusedSceneObject(workspace).focusedSceneObject(workspace.current)
    }
}

struct BrowserView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var model: SearchModel
    @FocusState private var searchFocused: Bool
    @State private var browserWindow: NSWindow?
    @State private var keyMonitor: Any?
    private let tags = SidebarTags.values
    var body: some View {
        NavigationSplitView {
            BrowserSidebar(
                state: SidebarState(
                    route: model.route, favorites: workspace.favorites,
                    volumes: workspace.volumes, ejectingVolumes: workspace.ejectingVolumes,
                    showDiskAccessHint: model.ready && !model.fullDiskAccess),
                select: { route in
                    NotificationCenter.default.post(name: .blurBrowserFiles, object: model)
                    model.sidebar(route)
                },
                removeFavorite: { workspace.removeFavorite($0) },
                moveFavorites: { workspace.moveFavorites(from: $0, to: $1) },
                openInNewTab: { workspace.activePane.newTab($0) },
                addFavoriteFolders: { await workspace.addFavoriteFolders($0) },
                eject: { volume in workspace.eject(volume) { model.error = $0 } }
            ).equatable()
        } detail: {
            ResizablePaneLayout(
                items: workspace.panes, layout: workspace.layout,
                weights: Binding(
                    get: { workspace.layoutWeights[workspace.layout.rawValue] ?? [:] },
                    set: { workspace.layoutWeights[workspace.layout.rawValue] = $0 })
            ) { pane in
                BrowserPaneHost(workspace: workspace, pane: pane)
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
                ToolbarItem { PaneLayoutPicker(workspace: workspace) }
                ToolbarItem {
                    ViewModePicker(selection: $model.viewMode)
                        .frame(width: 150, height: 28)
                        .padding(.horizontal, 6)
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
            .onSubmit(of: .search) { model.submitSearch() }
        }
        .background(BrowserWindowCapture { browserWindow = $0 }.frame(width: 0, height: 0))
        .background(
            MouseNavigationTarget { command in
                guard !model.busy, model.preview == nil else { return false }
                if command == .back { model.goBack() } else { model.goForward() }
                return true
            }.frame(width: 0, height: 0)
        )
        .onAppear { installKeyMonitor() }
        .onChange(of: model.id) { _, _ in
            searchFocused = false; installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            guard let browserWindow, NSApp.keyWindow === browserWindow else { return }
            model.sort = .relevance; searchFocused = true
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
        ) { _ in
            workspace.refreshVolumes()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
        ) { _ in
            workspace.refreshVolumes()
        }
        .sheet(
            item: Binding(
                get: { workspace.allTabs.compactMap(\.conflict).first },
                set: { _ in })
        ) { conflict in
            if let owner = workspace.allTabs.first(where: { $0.conflict?.id == conflict.id }) {
                ConflictSheet(conflict: conflict) { choice, all in
                    owner.resolveConflict(choice, applyToAll: all)
                }
                .interactiveDismissDisabled()
            }
        }
        .sheet(
            item: Binding(
                get: { workspace.allTabs.first { $0.batchRename != nil } },
                set: { if $0 == nil { workspace.allTabs.forEach { $0.batchRename = nil } } })
        ) { owner in
            if let request = owner.batchRename { BatchRenameSheet(model: owner, request: request) }
        }
        .sheet(
            item: Binding(
                get: { workspace.allTabs.first { $0.preview != nil } },
                set: { if $0 == nil { workspace.allTabs.forEach { $0.preview = nil } } })
        ) { owner in QuickLookBrowser(model: owner) }
    }
    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let browserWindow, NSApp.keyWindow === browserWindow, !browserWindow.isSheet
            else { return event }
            if let command = TabShortcut.command(for: event) {
                if command == .new {
                    workspace.activePane.newTab()
                } else {
                    workspace.activePane.reopenClosedTab()
                }
                return nil
            }
            if searchFocused && event.keyCode == 125 && !model.sortedHits.isEmpty {
                searchFocused = false
                NotificationCenter.default.post(name: .focusBrowserFiles, object: model)
                model.select(model.sortedHits[0], extending: false, toggling: false)
                model.selectionNavigation.send((model.sortedHits[0].path, false)); return nil
            }
            return event
        }
    }
    @ViewBuilder private var actions: some View {
        Button("Open") { model.open() }.disabled(model.selection.isEmpty)
        Button("Open in New Tab") {
            if let hit = model.selected, hit.isFolder { workspace.activePane.newTab(hit.url) }
        }.disabled(model.selected?.isFolder != true)
        Divider()
        Button("Get Info") { model.info() }.disabled(model.selection.isEmpty)
        Button("Quick Look") { model.preview = model.selected }.disabled(model.selection.isEmpty)
        Button("Rename…") { model.renameItems() }.disabled(model.selection.isEmpty || model.busy)
        Button("Duplicate") { model.duplicate() }.disabled(model.selection.isEmpty || model.busy)
        Button("Cut") { model.cut() }.disabled(model.selection.isEmpty || model.busy)
        Button("Copy") { model.copy() }.disabled(model.selection.isEmpty)
        Button("Copy Path") { model.copyPath() }.disabled(model.selection.isEmpty)
        Button("Paste Items") { model.paste() }.disabled(model.busy || !model.canWriteHere)
        Button("Move Items Here") { model.paste(move: true) }.disabled(
            model.busy || !model.canWriteHere)
        Divider()
        Button("New Folder") { model.newFolder() }.disabled(model.busy || !model.canWriteHere)
        Button("New Text File") { model.newTextFile() }.disabled(model.busy || !model.canWriteHere)
        Button("Add Folder to Sidebar") {
            workspace.addFavorite(
                model.selected?.isFolder == true ? model.selected!.url : model.location)
        }
        Button("Show in Finder") { model.reveal() }.disabled(model.selection.isEmpty)
        Divider()
        Button("Move to Trash") { model.trash() }.disabled(model.selection.isEmpty || model.busy)
    }
}

struct BrowserPaneHost: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var pane: BrowserPane
    var body: some View {
        BrowserPaneView(workspace: workspace, pane: pane, model: pane.current)
    }
}

struct BrowserPaneView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var pane: BrowserPane
    @ObservedObject var model: SearchModel
    private enum KeyboardFocus: Hashable { case files }
    @FocusState private var keyboardFocus: KeyboardFocus?
    @State private var fileNavigationActive = false
    @State private var keyMonitor: Any?
    @State private var browserWindow: NSWindow?
    @State private var gridColumns = 5
    private let tags = SidebarTags.values
    var body: some View {
        VStack(spacing: 0) {
            if pane.tabs.count > 1 { BrowserTabBar(pane: pane) }
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
                .contentShape(Rectangle())
                .contextMenu { backgroundActions }
                .modifier(SafeBackgroundDropTarget(model: model))
                .focusable(model.viewMode == .icons || model.viewMode == .gallery)
                .focused($keyboardFocus, equals: .files).focusEffectDisabled()
            pathBar
            statusBar
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if workspace.layout != .single {
                Rectangle().strokeBorder(
                    workspace.activePaneID == pane.id ? Color.accentColor.opacity(0.7) : .clear,
                    lineWidth: 1.5
                )
                .allowsHitTesting(false)
            }
        }
        .background(BrowserWindowCapture { browserWindow = $0 }.frame(width: 0, height: 0))
        .overlay(
            PaneActivationTarget {
                workspace.activatePane(pane.id); fileNavigationActive = true
            }
        )
        .onAppear {
            model.start(); installKeyMonitor()
        }
        .onChange(of: model.id) { _, _ in
            keyboardFocus = nil; fileNavigationActive = false
            model.start(); installKeyMonitor()
        }
        .onChange(of: workspace.activePaneID) { _, id in
            if id != pane.id { keyboardFocus = nil; fileNavigationActive = false }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusBrowserFiles)) { notification in
            guard let target = notification.object as? SearchModel, target.id == model.id else {
                return
            }
            focusFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .blurBrowserFiles)) { notification in
            guard let target = notification.object as? SearchModel, target.id == model.id else {
                return
            }
            keyboardFocus = nil; fileNavigationActive = false
        }
        .onChange(of: model.viewMode) { _, _ in
            model.cancelRename()
            model.extraHits = []; model.selection.formIntersection(Set(model.hits.map(\.path)))
        }
        .onChange(of: model.renaming) { _, hit in
            keyboardFocus = nil; fileNavigationActive = hit == nil
        }
        .onChange(of: model.query) { _, _ in
            if model.isSearch && model.sort != .relevance { model.sort = .relevance }
        }
        .task(id: model.id) { await model.monitor() }
    }
    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard workspace.activePaneID == pane.id, let browserWindow,
                NSApp.keyWindow === browserWindow
            else { return event }
            guard NSApp.keyWindow?.isSheet != true, model.preview == nil,
                fileNavigationActive,
                !(NSApp.keyWindow?.firstResponder is NSTextView)
            else { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if event.keyCode == 49 { model.preview = model.selected; return nil }
                if event.keyCode == 36 { model.rename(); return nil }
                if event.keyCode == 53 { model.selection = []; return nil }
                if (model.viewMode == .icons || model.viewMode == .gallery
                    || (model.viewMode == .columns && [125, 126].contains(event.keyCode))),
                    [123, 124, 125, 126].contains(event.keyCode)
                {
                    let stride = model.viewMode == .icons ? gridColumns : 1
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
    private var searchScopeBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text("Search:").foregroundStyle(.secondary)
                scopeButtons
                Spacer()
                kindPicker.frame(width: 130)
            }
            HStack(spacing: 6) {
                Menu {
                    scopeButtons
                } label: {
                    Text(model.scope.isEmpty ? "This Mac" : model.location.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                }
                kindPicker.frame(maxWidth: 90)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    @ViewBuilder private var scopeButtons: some View {
        Button("This Mac") { model.scope = "" }.buttonStyle(.bordered)
            .tint(model.scope.isEmpty ? .accentColor : .secondary)
        Button(model.location.lastPathComponent) { model.scope = model.location.path }
            .buttonStyle(.bordered).tint(model.scope.isEmpty ? .secondary : .accentColor)
    }
    private var kindPicker: some View {
        Picker("Kind", selection: $model.fileType) {
            Text("Any Kind").tag(""); Text("Folder").tag("dir"); Text("Document").tag("doc");
            Text("Image").tag("image"); Text("Movie").tag("video"); Text("Audio").tag("audio")
        }.labelsHidden()
    }
    @ViewBuilder private var fileContent: some View {
        if model.viewMode == .columns && model.canWriteHere {
            ColumnBrowser(model: model, focusFiles: { focusFiles() }, rowMenu: rowActions).id(
                model.id)
        } else if (model.loading || model.searching) && model.sortedHits.isEmpty {
            FolderLoadingSkeleton(mode: model.viewMode, iconSize: model.iconSize)
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
            case .icons: iconGrid.id(model.id)
            case .list: fileTable
            case .columns:
                fileTable
            case .gallery:
                GalleryBrowser(model: model, select: select, rowMenu: rowActions).id(model.id)
            }
        }
    }
    private var iconGrid: some View {
        GeometryReader { geometry in
            iconScroll(minHeight: geometry.size.height)
                .onAppear { updateColumns(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
                .onChange(of: model.iconSize) { _, _ in updateColumns(geometry.size.width) }
        }
    }
    private func updateColumns(_ width: Double) {
        gridColumns = max(1, Int((width - 36) / (model.iconSize + 69)))
    }
    private func iconScroll(minHeight: Double) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: model.iconSize + 55), spacing: 14)],
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(model.sortedHits) { hit in iconCell(hit) }
                }.scrollTargetLayout().padding(18)
                    .frame(minHeight: minHeight, alignment: .top)
                    .marqueeSelection(model: model, focusFiles: focusFiles)
            }
            .scrollPosition(id: $model.scrollAnchor)
            .onReceive(model.selectionNavigation) { request in
                proxy.scrollTo(request.path)
            }
        }
    }
    private func iconCell(_ hit: Hit) -> some View {
        VStack(spacing: 6) {
            FileThumbnail(hit: hit, size: model.iconSize).frame(
                width: model.iconSize + 10, height: model.iconSize + 10)
            FileNameLabel(model: model, hit: hit, lineLimit: 2, centered: true)
                .frame(height: 32, alignment: .top)
        }
        .modifier(CutAppearance(path: hit.path))
        .padding(6).frame(maxWidth: .infinity)
        .background(
            model.selection.contains(hit.path) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .modifier(FileClickActions(select: { select(hit) }, open: { model.open(hit) }))
        .contextMenu { rowActions(hit) }.draggable(hit.url)
        .modifier(FolderDropTarget(hit: hit, model: model))
        .onHover { hovering in if hovering && hit.isFolder { model.prefetchFolder(hit.url) } }
        .marqueeItem(hit.path, in: model.id)
        .id(hit.path)
        .accessibilityLabel(hit.name).accessibilityAddTraits(
            model.selection.contains(hit.path) ? [.isSelected] : [])
    }
    private var fileTable: some View {
        FileList(
            model: model, focusFiles: focusFiles, newTab: { pane.newTab($0) },
            addFavorite: { workspace.addFavorite($0) })
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
        GeometryReader { geometry in
            HStack {
                if model.loading || model.searching || model.sorting || model.busy {
                    ProgressView().controlSize(.mini)
                }
                if let progress = model.operationProgress {
                    if let fraction = progress.fraction, geometry.size.width > 340 {
                        ProgressView(value: fraction).frame(width: 100)
                    }
                    Text("\(model.operationName) · \(progress.item)").lineLimit(1)
                    if progress.bytes > 0 && geometry.size.width > 420 {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: progress.bytes, countStyle: .file)
                        )
                        .monospacedDigit()
                    }
                    Button("Cancel") { model.cancelOperation() }.controlSize(.small).fixedSize()
                } else {
                    Text(
                        model.selection.isEmpty
                            ? (model.isSearch && model.hits.count == 500
                                ? "First 500 matches" : "\(model.sortedHits.count) items")
                            : "\(model.selection.count) selected")
                }
                if model.isSearch && geometry.size.width > 280 {
                    Text(String(format: "· %.1f ms", model.elapsed)).monospacedDigit()
                }
                Spacer()
                if model.viewMode == .icons && geometry.size.width > 340 {
                    Image(systemName: "square").font(.system(size: 8));
                    Slider(value: $model.iconSize, in: 40...96).frame(width: 100)
                        .accessibilityLabel(
                            "Icon Size");
                    Image(systemName: "square").font(.system(size: 13))
                }
            }.lineLimit(1).font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, geometry.size.width > 260 ? 14 : 8).frame(
                    height: 28
                )
        }.frame(height: 28).background(Color(nsColor: .windowBackgroundColor))
    }
    @ViewBuilder private var backgroundActions: some View {
        Button("New Folder") { model.newFolder() }.disabled(model.busy || !model.canWriteHere)
        Button("New Text File") { model.newTextFile() }.disabled(model.busy || !model.canWriteHere)
        Button("Paste Items") { model.paste() }.disabled(model.busy || !model.canWriteHere)
        Button("Move Items Here") { model.paste(move: true) }.disabled(
            model.busy || !model.canWriteHere)
        Divider()
        Button("Open in New Tab") { pane.newTab(model.location) }.disabled(!model.canWriteHere)
        Button("Add Folder to Sidebar") { workspace.addFavorite(model.location) }.disabled(
            !model.canWriteHere)
        Divider()
        Menu("View") {
            ForEach(FileViewMode.allCases, id: \.self) { mode in
                Button(mode.title) { model.viewMode = mode }
            }
        }
        Toggle("Show Hidden Files", isOn: $model.showHidden)
        Button("Refresh") { model.schedule() }.disabled(model.busy)
    }
    @ViewBuilder private func rowActions(_ hit: Hit) -> some View {
        Button("Open") { model.open(hit) }
        OpenWithMenu(model: model, hit: hit)
        Button("Open in New Tab") { pane.newTab(hit.url) }.disabled(!hit.isFolder)
        Button("Quick Look") { model.preview = hit }
        Button("Open Enclosing Folder") { model.navigate(hit.url.deletingLastPathComponent()) }
        Divider()
        Button("Get Info") {
            contextual(hit); model.info()
        }
        Button("Rename…") {
            contextual(hit); model.renameItems()
        }
        Button("Compress") {
            contextual(hit); model.compress()
        }.disabled(model.busy || !model.canWriteHere)
        Button("Extract ZIP") {
            contextual(hit); model.extract()
        }.disabled(model.busy || hit.url.pathExtension.lowercased() != "zip")
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
        workspace.activatePane(pane.id)
        keyboardFocus = nil; fileNavigationActive = true
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
    private func select(_ hit: Hit) {
        guard model.renaming?.path != hit.path else { return }
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
