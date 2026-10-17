import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarTags {
    static func title(for name: String) -> String {
        values.contains { $0.0 == name } ? L10n.string(name) : name
    }

    static let values: [(String, Color)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Purple", .purple), ("Gray", .gray),
    ]
}

enum FavoriteFolders {
    static let key = "sidebarFavorites"
    static let changed = Notification.Name("FinderSearch.sidebarFavoritesChanged")

    static func defaults(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications"]
            + ["Documents", "Downloads", "Desktop", "Pictures", "Music", "Movies"]
            .map { home + "/" + $0 }
    }

    static func load(from defaults: UserDefaults) -> [String] {
        let paths =
            defaults.stringArray(forKey: key)
            ?? (Self.defaults() + (defaults.stringArray(forKey: "favorites") ?? []))
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        .filter { seen.insert($0).inserted }
    }

    static func existingDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let url = url.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                values.isDirectory == true, values.isPackage != true,
                seen.insert(url.path).inserted
            else { return nil }
            return url
        }
    }

    static func label(for path: String) -> (name: String, symbol: String) {
        let names = [
            "Applications", "Documents", "Downloads", "Desktop", "Pictures", "Music", "Movies",
        ]
        let symbols = [
            "a.square", "doc", "arrow.down.circle", "menubar.dock.rectangle", "photo", "music.note",
            "film",
        ]
        if let index = defaults().firstIndex(of: path) {
            return (L10n.string(names[index]), symbols[index])
        }
        return ((path as NSString).lastPathComponent, "folder")
    }
}

/// Folder results and loading phases have no bearing on sidebar content.
struct SidebarState: Equatable {
    let selection: String?
    let favorites: [String]
    let volumes: [MountedVolume]
    let ejectingVolumes: Set<String>
    let showDiskAccessHint: Bool

    init(
        route: String, favorites: [String], volumes: [MountedVolume], ejectingVolumes: Set<String>,
        showDiskAccessHint: Bool
    ) {
        let home = NSHomeDirectory()
        let fixedRoutes =
            [
                "recents", home,
                home + "/Library/Mobile Documents/com~apple~CloudDocs",
            ]
            + SidebarTags.values.map { "tag:" + $0.0 }
        // An ordinary child folder selects no sidebar row. Moving between such
        // folders should leave the entire sidebar untouched.
        selection = (fixedRoutes + favorites + volumes.map(\.id)).contains(route) ? route : nil
        self.favorites = favorites
        self.volumes = volumes
        self.ejectingVolumes = ejectingVolumes
        self.showDiskAccessHint = showDiskAccessHint
    }
}

struct BrowserSidebar: View, Equatable {
    let state: SidebarState
    let select: (String) -> Void
    let removeFavorite: (String) -> Void
    let moveFavorites: (IndexSet, Int) -> Void
    let openInNewTab: (URL) -> Void
    let addFavoriteFolders: ([URL]) async -> Bool
    @State private var folderDropTargeted = false
    let eject: (MountedVolume) -> Void
    private let home = NSHomeDirectory()

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Callbacks target the same browser and workspace for this view's lifetime;
        // the browser's identity changes when switching tabs.
        lhs.state == rhs.state
    }

    var body: some View {
        VStack(spacing: 0) {
            locations
            if state.showDiskAccessHint {
                Divider()
                Button {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                        )!)
                } label: {
                    Text(L10n.string("Enable Full Disk Access…"))
                        .font(.caption).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(12)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 208, max: 280)
    }

    private var locations: some View {
        List(
            selection: Binding<String?>(
                get: { state.selection },
                set: { if let route = $0 { select(route) } }
            )
        ) {
            Label(L10n.string("Recents"), systemImage: "clock").tag("recents")
            Section(L10n.string("Favorites")) {
                ForEach(state.favorites, id: \.self) { path in
                    let label = FavoriteFolders.label(for: path)
                    row(label.name, label.symbol, path)
                        .contextMenu {
                            folderActions(path)
                            Divider()
                            Button(L10n.string("Remove from Sidebar")) { removeFavorite(path) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            FavoriteDragTarget(path: path) { source, target in
                                guard let from = state.favorites.firstIndex(of: source),
                                    let to = state.favorites.firstIndex(of: target)
                                else { return }
                                moveFavorites(IndexSet(integer: from), to > from ? to + 1 : to)
                            }
                        }
                }
            }
            Section(L10n.string("Locations")) {
                row(
                    L10n.string("iCloud Drive"), "icloud",
                    home + "/Library/Mobile Documents/com~apple~CloudDocs"
                ).contextMenu {
                    folderActions(home + "/Library/Mobile Documents/com~apple~CloudDocs")
                }
                row((home as NSString).lastPathComponent, "house", home)
                    .contextMenu { folderActions(home) }
                ForEach(state.volumes) { volume in
                    let ejecting = state.ejectingVolumes.contains(volume.id)
                    let ejectLabel =
                        ejecting
                        ? L10n.format("Ejecting %@…", volume.name)
                        : L10n.format("Eject %@", volume.name)
                    HStack {
                        Label(volume.name, systemImage: "externaldrive")
                        Spacer(minLength: 4)
                        if volume.canEject {
                            Button {
                                eject(volume)
                            } label: {
                                Group {
                                    if ejecting {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "eject.fill").font(.system(size: 11))
                                            .foregroundStyle(.primary)
                                    }
                                }.frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .disabled(ejecting)
                            .help(ejectLabel)
                            .accessibilityLabel(ejectLabel)
                        }
                    }.tag(volume.id)
                        .contextMenu {
                            folderActions(volume.id)
                            if volume.canEject {
                                Divider()
                                Button(L10n.format("Eject “%@”", volume.name)) { eject(volume) }
                                    .disabled(ejecting)
                            }
                        }
                }
            }
            Section(L10n.string("Tags")) {
                ForEach(SidebarTags.values, id: \.0) { name, color in
                    Label {
                        Text(L10n.string(name))
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 10))
                            .foregroundStyle(color)
                    }.tag("tag:" + name)
                }
            }
        }
        // Recreate the native list after a reorder so selection follows the path,
        // rather than the previous row index retained by AppKit.
        .id(state.favorites)
        .listStyle(.sidebar)
        .onDrop(of: [UTType.fileURL], isTargeted: $folderDropTargeted) { providers in
            FavoriteFolderDrop.perform(providers, add: addFavoriteFolders)
        }
        .overlay {
            if folderDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                    .padding(4).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func folderActions(_ path: String) -> some View {
        Button(L10n.string("Open")) { select(path) }
        Button(L10n.string("Open in New Tab")) {
            openInNewTab(URL(fileURLWithPath: path, isDirectory: true))
        }
        Button(L10n.string("Reveal in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func row(_ name: String, _ symbol: String, _ path: String) -> some View {
        Label(name, systemImage: symbol).tag(path)
    }
}
