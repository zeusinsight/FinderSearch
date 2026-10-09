import SwiftUI
import AppKit

enum SidebarTags {
    static let values: [(String, Color)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Purple", .purple), ("Gray", .gray),
    ]
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
                "recents", "/Applications", home,
                home + "/Library/Mobile Documents/com~apple~CloudDocs",
            ]
            + ["Documents", "Downloads", "Desktop", "Pictures", "Music", "Movies"].map {
                home + "/" + $0
            }
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
    let eject: (MountedVolume) -> Void
    private let home = NSHomeDirectory()

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Callbacks target the same browser and workspace for this view's lifetime;
        // the browser's identity changes when switching tabs.
        lhs.state == rhs.state
    }

    var body: some View {
        List(
            selection: Binding<String?>(
                get: { state.selection },
                set: { if let route = $0 { select(route) } }
            )
        ) {
            Label("Recents", systemImage: "clock").tag("recents")
            Section("Favorites") {
                row("Applications", "a.square", "/Applications")
                row("Documents", "doc", home + "/Documents")
                row("Downloads", "arrow.down.circle", home + "/Downloads")
                row("Desktop", "menubar.dock.rectangle", home + "/Desktop")
                row("Pictures", "photo", home + "/Pictures")
                row("Music", "music.note", home + "/Music")
                row("Movies", "film", home + "/Movies")
                ForEach(state.favorites, id: \.self) { path in
                    row((path as NSString).lastPathComponent, "folder", path)
                        .contextMenu {
                            Button("Remove from Sidebar") { removeFavorite(path) }
                        }
                }
            }
            Section("Locations") {
                row(
                    "iCloud Drive", "icloud", home + "/Library/Mobile Documents/com~apple~CloudDocs"
                )
                row((home as NSString).lastPathComponent, "house", home)
                ForEach(state.volumes) { volume in
                    HStack {
                        Label(volume.name, systemImage: "externaldrive")
                        Spacer(minLength: 4)
                        if volume.canEject {
                            Button {
                                eject(volume)
                            } label: {
                                Image(systemName: "eject.fill").font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .disabled(state.ejectingVolumes.contains(volume.id))
                            .help("Eject \(volume.name)")
                            .accessibilityLabel("Eject \(volume.name)")
                        }
                    }.tag(volume.id)
                }
            }
            Section("Tags") {
                ForEach(SidebarTags.values, id: \.0) { name, color in
                    Label {
                        Text(name)
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 10))
                            .foregroundStyle(color)
                    }.tag("tag:" + name)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 208, max: 280)
        .safeAreaInset(edge: .bottom) {
            if state.showDiskAccessHint {
                Button("Enable Full Disk Access…") {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                        )!)
                }.font(.caption).padding(12)
            }
        }
    }

    private func row(_ name: String, _ symbol: String, _ path: String) -> some View {
        Label(name, systemImage: symbol).tag(path)
    }
}
