import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct FileIcon: View {
    let hit: Hit
    @State private var image: NSImage?
    var body: some View {
        Image(nsImage: image ?? FileIcons.shared.placeholder(hit)).resizable()
            .task(id: hit.imageKey) {
                guard hit.metadataPending != true else { return }
                guard let loaded = await FileIcons.shared.load(hit) else { return }
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
            .task(id: hit.imageKey) {
                guard hit.metadataPending != true else { return }
                if let cached = ThumbnailCache.shared.image(hit) { image = cached; return }
                guard let icon = await FileIcons.shared.load(hit) else { return }
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
                let completion = ThumbnailCompletion(request: request)
                let thumbnail: NSImage? = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        guard completion.start(continuation) else { return }
                        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                            result, _ in completion.finish(result?.nsImage)
                        }
                        // Cancellation can race the call that starts generation.
                        if completion.isCancelled { QLThumbnailGenerator.shared.cancel(request) }
                    }
                } onCancel: {
                    completion.cancel()
                    Task { @MainActor in completion.cancelGeneration() }
                }
                if let thumbnail {
                    ThumbnailCache.shared.store(thumbnail, for: hit);
                    guard !Task.isCancelled else { return }; image = thumbnail
                }
            }
    }
}

/// Quick Look may finish after cancellation. Resume the waiting view exactly once.
private final class ThumbnailCompletion: @unchecked Sendable {
    private let request: QLThumbnailGenerator.Request
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<NSImage?, Never>?
    init(request: QLThumbnailGenerator.Request) { self.request = request }
    @MainActor func cancelGeneration() { QLThumbnailGenerator.shared.cancel(request) }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func start(_ continuation: CheckedContinuation<NSImage?, Never>) -> Bool {
        let accepted = lock.withLock {
            guard !cancelled else { return false }
            self.continuation = continuation
            return true
        }
        if !accepted { continuation.resume(returning: nil) }
        return accepted
    }
    func finish(_ image: NSImage?) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: image)
    }
    func cancel() {
        lock.withLock { cancelled = true }
        finish(nil)
    }
}

struct GalleryBrowser<RowMenu: View>: View {
    @ObservedObject var model: SearchModel
    let select: (Hit) -> Void
    let rowMenu: (Hit) -> RowMenu
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
                                FileNameLabel(model: model, hit: hit, centered: true).frame(
                                    width: 100)
                            }.padding(7)
                                .background(
                                    model.selection.contains(hit.path)
                                        ? Color.accentColor.opacity(0.22) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                ).contentShape(Rectangle())
                                .contextMenu { rowMenu(hit) }
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
struct ColumnBrowser<RowMenu: View>: View {
    @ObservedObject var model: SearchModel
    let focusFiles: () -> Void
    let rowMenu: (Hit) -> RowMenu
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
                                        FileNameLabel(model: model, hit: hit);
                                        Spacer(minLength: 2);
                                        if hit.isFolder {
                                            Image(systemName: "chevron.right").font(
                                                .system(size: 9)
                                            ).foregroundStyle(.secondary)
                                        }
                                    }.frame(maxWidth: .infinity).contentShape(Rectangle()).tag(
                                        hit.path
                                    ).contextMenu { rowMenu(hit) }.draggable(hit.url).modifier(
                                        FolderDropTarget(hit: hit, model: model)
                                    ).modifier(ColumnOpenGesture(hit: hit, model: model))
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
        .onChange(of: model.sortedHits) { _, _ in
            if let index = columns.firstIndex(where: { $0.url.path == model.location.path }) {
                columns[index].items = model.sortedHits
                if let selected = columns[index].items.first(where: { model.selection.contains($0.path) }) {
                    columns[index].selected = selected.path
                } else if let selected = columns[index].selected,
                    !columns[index].items.contains(where: { $0.path == selected }) {
                    columns[index].selected = nil
                }
                model.extraHits = columns.flatMap(\.items)
            }
        }
        .task(id: model.location) {
            guard lastNavigation?.path != model.location.path else { return }
            lastNavigation = model.location
            columns = [FileColumn(url: model.location, items: model.sortedHits)]
        }
    }
    private func pick(_ hit: Hit, at index: Int) {
        guard !model.busy else { return }
        guard model.renaming?.path != hit.path else { return }
        guard columns.indices.contains(index), columns[index].selected != hit.path else { return }
        if columns[index].url.path == model.location.path {
            guard model.hits.contains(where: { $0.path == hit.path }) else { return }
        }
        focusFiles()
        columns[index].selected = hit.path; columns = Array(columns.prefix(index + 1))
        model.extraHits = columns.flatMap(\.items); model.selection = [hit.path]
        guard hit.isFolder else { return }
        model.navigate(hit.url);
        lastNavigation = model.location
        model.extraHits = columns.flatMap(\.items); model.selection = [hit.path]
        columns.append(FileColumn(url: model.location, items: model.sortedHits))
        model.extraHits = columns.flatMap(\.items); model.selection = [hit.path]
    }
}

/// Column folders navigate through native selection on the first click. A
/// double-tap recognizer on those rows delays selection while it waits.
private struct ColumnOpenGesture: ViewModifier {
    let hit: Hit
    let model: SearchModel
    @ViewBuilder func body(content: Content) -> some View {
        if hit.isFolder {
            content.onHover { hovering in if hovering { model.prefetchFolder(hit.url) } }
        } else {
            content.simultaneousGesture(TapGesture(count: 2).onEnded { model.open(hit) })
        }
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
