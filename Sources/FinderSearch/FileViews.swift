import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct FileIcon: View {
    let hit: Hit
    @State private var image: NSImage?
    var body: some View {
        Image(nsImage: image ?? FileIcons.shared.placeholder(hit)).resizable()
            .task(id: hit.path + String(hit.mtime)) {
                let loaded = await FileIcons.shared.load(hit)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

@MainActor final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, NSImage>()
    private init() { images.countLimit = 256; images.totalCostLimit = 64 * 1024 * 1024 }
    func key(_ hit: Hit) -> String { hit.path + ":" + String(hit.mtime) + ":" + String(hit.size) }
    func image(_ hit: Hit) -> NSImage? { images.object(forKey: key(hit) as NSString) }
    func store(_ image: NSImage, for hit: Hit) {
        images.setObject(image, forKey: key(hit) as NSString, cost: 256 * 256 * 4)
    }
}

struct FileThumbnail: View {
    let hit: Hit
    let size: Double
    @State private var image: NSImage?
    var body: some View {
        Image(
            nsImage: image ?? ThumbnailCache.shared.image(hit) ?? FileIcons.shared.placeholder(hit)
        ).resizable().scaledToFit().frame(width: size, height: size)
            .task(id: hit.path + String(hit.mtime)) {
                if let cached = ThumbnailCache.shared.image(hit) { image = cached; return }
                let icon = await FileIcons.shared.load(hit)
                guard !Task.isCancelled else { return }; image = icon
                guard hit.kind != "dir" else { return }
                let unavailableCloudFile = await Task.detached(priority: .utility) {
                    let values = try? hit.url.resourceValues(forKeys: [
                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                    ])
                    return values?.isUbiquitousItem == true
                        && values?.ubiquitousItemDownloadingStatus != .current
                }.value
                guard !Task.isCancelled, !unavailableCloudFile else { return }
                let request = QLThumbnailGenerator.Request(
                    fileAt: hit.url, size: CGSize(width: 128, height: 128), scale: 2,
                    representationTypes: .thumbnail)
                let thumbnail: NSImage? = await withCheckedContinuation { continuation in
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                        result, _ in continuation.resume(returning: result?.nsImage)
                    }
                }
                if let thumbnail {
                    ThumbnailCache.shared.store(thumbnail, for: hit);
                    guard !Task.isCancelled else { return }; image = thumbnail
                }
            }
    }
}
struct GalleryBrowser: View {
    @ObservedObject var model: SearchModel
    let select: (Hit) -> Void
    var body: some View {
        VStack(spacing: 0) {
            if let hit = model.selected ?? model.sortedHits.first {
                QuickLook(url: hit.url).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text(hit.name).fontWeight(.medium); Spacer();
                    Text(hit.typeName).foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(model.sortedHits) { hit in
                            VStack(spacing: 5) {
                                FileThumbnail(hit: hit, size: 64);
                                Text(hit.name).font(.system(size: 11)).lineLimit(1).frame(
                                    width: 100)
                            }.padding(7)
                                .background(
                                    model.selection.contains(hit.path)
                                        ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                ).contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    select(hit); model.open(hit)
                                }.onTapGesture { select(hit) }.draggable(hit.url).modifier(
                                    FolderDropTarget(hit: hit, model: model)
                                )
                                .id(hit.path)
                        }
                    }.padding(12)
                }.frame(height: 115)
                    .onChange(of: model.focusedPath) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
            }
        }
    }
}
struct FileColumn: Identifiable {
    let id = UUID(); let url: URL; var items: [Hit]; var selected: String?
}
struct ColumnBrowser: View {
    @ObservedObject var model: SearchModel
    let focusFiles: () -> Void
    @State private var columns: [FileColumn] = []
    @State private var lastNavigation: URL?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        VStack(spacing: 0) {
                            if model.loading && column.url == model.location && column.items.isEmpty
                            {
                                FolderLoadingSkeleton(mode: .columns)
                            } else {
                                List(
                                    column.items,
                                    selection: Binding(
                                        get: {
                                            columns.indices.contains(index)
                                                ? columns[index].selected : nil
                                        },
                                        set: { path in
                                            if let path,
                                                let hit = column.items.first(where: {
                                                    $0.path == path
                                                })
                                            {
                                                pick(hit, at: index)
                                            }
                                        })
                                ) { hit in
                                    HStack(spacing: 6) {
                                        FileIcon(hit: hit).frame(width: 16, height: 16);
                                        Text(hit.name).font(.system(size: 12)).lineLimit(1);
                                        Spacer(minLength: 2);
                                        if hit.isFolder {
                                            Image(systemName: "chevron.right").font(
                                                .system(size: 9)
                                            ).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity).contentShape(Rectangle()).tag(
                                        hit.path
                                    ).draggable(hit.url).modifier(
                                        FolderDropTarget(hit: hit, model: model)
                                    ).onTapGesture(count: 2) { model.open(hit) }
                                }.listStyle(.plain)
                            }
                        }.frame(width: 235).id(column.id)
                        Divider()
                    }
                    if let hit = model.selected, !hit.isFolder {
                        VStack {
                            FileThumbnail(hit: hit, size: 120);
                            Text(hit.name).font(.headline).multilineTextAlignment(.center);
                            Text(hit.typeName).font(.caption).foregroundStyle(.secondary)
                        }.padding(20).frame(width: 240)
                    }
                }
            }.onChange(of: columns.count) { _, _ in
                if let last = columns.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .trailing)
                    }
                }
            }
        }
        .onChange(of: model.hits) { _, _ in
            if let index = columns.firstIndex(where: { $0.url == model.location }) {
                columns[index].items = model.sortedHits
            }
        }
        .task(id: model.location) {
            guard lastNavigation != model.location else { return }
            lastNavigation = model.location
            columns = [FileColumn(url: model.location, items: model.sortedHits)]
        }
    }
    private func pick(_ hit: Hit, at index: Int) {
        guard columns.indices.contains(index) else { return }; focusFiles()
        columns[index].selected = hit.path; columns = Array(columns.prefix(index + 1))
        model.extraHits = columns.flatMap(\.items); model.selection = [hit.path]
        guard hit.isFolder else { return }
        lastNavigation = hit.url; model.navigate(hit.url);
        model.extraHits = columns.flatMap(\.items); model.selection = [hit.path]
        columns.append(FileColumn(url: hit.url, items: model.sortedHits))
        model.extraHits = columns.flatMap(\.items); model.selection = [hit.path]
    }
}

/// Only explicitly identified folders accept drops. Other rows reject rather than
/// silently falling through to the parent directory.
struct FolderDropTarget: ViewModifier {
    let hit: Hit
    @ObservedObject var model: SearchModel
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .modifier(DropRowBounds(id: model.id))
            .background(targeted && hit.isFolder ? Color.accentColor.opacity(0.22) : Color.clear)
            .overlay {
                if targeted && hit.isFolder {
                    RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard hit.isFolder else { return false }
                return FileDrops.accept(providers, into: hit.url, model: model)
            }
    }
}
@MainActor enum FileDrops {
    static func accept(_ providers: [NSItemProvider], into folder: URL, model: SearchModel) -> Bool
    {
        guard !model.busy, !providers.isEmpty else { return false }
        let move = !NSEvent.modifierFlags.contains(.option)
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { value, _ in
                        continuation.resume(returning: value)
                    }
                }
                if let url { urls.append(url) }
            }
            model.transfer(urls, to: folder, move: move)
        }
        return true
    }
}

private struct DropBoundsKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}
private struct DropRowBounds: ViewModifier {
    let id: UUID
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DropBoundsKey.self, value: [proxy.frame(in: .named(id))])
            }
        }
    }
}
struct SafeBackgroundDropTarget: ViewModifier {
    @ObservedObject var model: SearchModel
    @State private var bounds: [CGRect] = []
    func body(content: Content) -> some View {
        content.coordinateSpace(name: model.id)
            .onPreferenceChange(DropBoundsKey.self) { bounds = $0 }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers, point in
                guard model.canWriteHere, model.viewMode == .icons,
                    Self.isBackground(point, bounds: bounds, mode: model.viewMode)
                else { return false }
                return FileDrops.accept(providers, into: model.location, model: model)
            }
    }
    static func isBackground(_ point: CGPoint, bounds: [CGRect], mode: FileViewMode) -> Bool {
        switch mode {
        case .icons: return !bounds.contains { $0.contains(point) }
        case .list:
            return point.y > 24 && !bounds.contains { point.y >= $0.minY && point.y <= $0.maxY }
        case .columns, .gallery: return false
        }
    }
}
