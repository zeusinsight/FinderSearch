import Foundation
import AppKit
import UniformTypeIdentifiers
import Darwin

enum FullDiskAccess {
    static func isGranted() -> Bool {
        // This protected file can be opened only with Full Disk Access. Opening
        // it does not read its contents or trigger a consent prompt.
        let url = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }
}

extension Hit {
    var isFolder: Bool {
        kind == "dir"
            && !(UTType(filenameExtension: url.pathExtension)?.conforms(to: .package) ?? false)
    }
    var typeName: String {
        if kind == "dir" { return isFolder ? "Folder" : "Application / Package" }
        return UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "Document"
    }
    var modified: Date { Date(timeIntervalSince1970: Double(mtime)) }
    static func read(_ url: URL, parent: URL? = nil) throws -> Hit {
        let v = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        return Hit(
            path: (parent?.appendingPathComponent(url.lastPathComponent) ?? url).path,
            kind: v.isDirectory == true ? "dir" : "file",
            size: UInt64(max(0, v.fileSize ?? 0)),
            mtime: UInt64(
                max(0, (v.contentModificationDate ?? .distantPast).timeIntervalSince1970)), score: 0
        )
    }
}

enum FileMutation: Equatable {
    case copy(URL, URL), move(URL, URL), trash(URL), folder(URL), textFile(URL), tags(URL, [String])
    case replace(URL, URL, move: Bool)
    case compress([URL], URL), extract(URL, URL)
    case renameBatch([RenameMove])
}
struct FileBatch {
    var inverse: [FileMutation] = []
    var errors: [String] = []
    var failed: [FileMutation] = []
    var cancelled = false
}

enum OptimisticFiles {
    static func applying(_ operations: [FileMutation], to hits: [Hit], in folder: URL?) -> [Hit] {
        guard !operations.isEmpty else { return hits }
        // Trash batches commute: remove their paths in one stable pass. Mixed
        // operations retain sequential semantics (a move can create a later target).
        if operations.allSatisfy({
            if case .trash = $0 { return true }; return false
        }) {
            guard !hits.isEmpty else { return hits }
            var removed = Set<String>()
            removed.reserveCapacity(operations.count)
            for case .trash(let source) in operations { removed.insert(source.path) }
            return hits.filter { !removed.contains($0.path) }
        }
        if let transferred = indexedTransfers(operations, hits: hits, folder: folder) {
            return transferred
        }
        var result = hits
        for operation in operations {
            switch operation {
            case .renameBatch(let moves):
                let mapping = Dictionary(
                    uniqueKeysWithValues: moves.map { ($0.source.path, $0.destination) })
                result = result.map { hit in
                    guard let destination = mapping[hit.path] else { return hit }
                    return Hit(
                        path: destination.path, kind: hit.kind, size: hit.size,
                        mtime: hit.mtime, score: hit.score, metadataPending: hit.metadataPending)
                }
            case .replace(let source, let destination, let move):
                result.removeAll { $0.path == destination.path }
                result = applying(
                    [move ? .move(source, destination) : .copy(source, destination)], to: result,
                    in: folder)
            case .trash(let source):
                result.removeAll { $0.path == source.path }
            case .move(let source, let destination):
                guard source.path != destination.path,
                    !result.contains(where: { $0.path == destination.path })
                else { continue }
                let original = result.first { $0.path == source.path }
                result.removeAll { $0.path == source.path }
                if let original,
                    destination.deletingLastPathComponent().path == folder?.path
                        || (folder == nil
                            && destination.deletingLastPathComponent().path
                                == source.deletingLastPathComponent().path)
                {
                    result.append(
                        Hit(
                            path: destination.path, kind: original.kind,
                            size: original.size, mtime: original.mtime, score: original.score,
                            metadataPending: original.metadataPending))
                }
            case .copy(let source, let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path }),
                    let original = result.first(where: { $0.path == source.path })
                else { continue }
                result.append(
                    Hit(
                        path: destination.path, kind: original.kind,
                        size: original.size, mtime: original.mtime, score: original.score,
                        metadataPending: original.metadataPending))
            case .folder(let destination), .extract(_, let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path })
                else { continue }
                result.append(
                    Hit(
                        path: destination.path, kind: "dir", size: 0,
                        mtime: UInt64(Date().timeIntervalSince1970), score: 0))
            case .textFile(let destination), .compress(_, let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path })
                else { continue }
                result.append(
                    Hit(
                        path: destination.path, kind: "file", size: 0,
                        mtime: UInt64(Date().timeIntervalSince1970), score: 0))
            case .tags: break
            }
        }
        return result
    }

    // Only transfer-only batches with unique paths use the index. Other inputs
    // keep the sequential implementation, including duplicate-row behavior.
    private static func indexedTransfers(_ operations: [FileMutation], hits: [Hit], folder: URL?)
        -> [Hit]?
    {
        guard !operations.isEmpty else { return hits }
        for operation in operations {
            switch operation {
            case .move, .copy: break
            default: return nil
            }
        }
        var index: [String: Int] = [:]
        index.reserveCapacity(hits.count + operations.count)
        for (i, hit) in hits.enumerated() {
            guard index.updateValue(i, forKey: hit.path) == nil else {
                return nil
            }
        }
        // Tombstones preserve the order of surviving rows; newly created paths
        // append in operation order, including chained moves and copies.
        var rows = hits.map(Optional.some)
        rows.reserveCapacity(hits.count + operations.count)
        let folderPath = folder?.path
        for operation in operations {
            let source: URL, destination: URL, moving: Bool
            switch operation {
            case .move(let from, let to): source = from; destination = to; moving = true
            case .copy(let from, let to): source = from; destination = to; moving = false
            default: return nil
            }
            let from = source.path, to = destination.path
            guard index[to] == nil, let row = index[from], let original = rows[row] else {
                continue
            }
            let destinationParent = destination.deletingLastPathComponent().path
            if moving {
                guard from != to else { continue }
                rows[row] = nil
                index.removeValue(forKey: from)
                guard
                    destinationParent == folderPath
                        || (folder == nil
                            && destinationParent == source.deletingLastPathComponent().path)
                else { continue }
            } else {
                guard destinationParent == folderPath else { continue }
            }
            let updated = Hit(
                path: to, kind: original.kind, size: original.size,
                mtime: original.mtime, score: original.score,
                metadataPending: original.metadataPending)
            index[to] = rows.count
            rows.append(updated)
        }
        return rows.compactMap { $0 }
    }

    static func selection(
        _ selection: Set<String>, after operations: [FileMutation], visibleHits: [Hit]
    ) -> Set<String> {
        var result = selection
        let visible = Set(visibleHits.map(\.path))
        for operation in operations {
            switch operation {
            case .move(let source, let destination),
                .replace(let source, let destination, move: true):
                guard !visible.contains(source.path) else { continue }
                if result.remove(source.path) != nil && visible.contains(destination.path) {
                    result.insert(destination.path)
                }
            case .renameBatch(let moves):
                let mapping = Dictionary(
                    uniqueKeysWithValues: moves.map { ($0.source.path, $0.destination.path) })
                result = Set(result.map { mapping[$0] ?? $0 })
            case .trash(let source): result.remove(source.path)
            default: break
            }
        }
        return result.intersection(visible)
    }
}

/// A path with symlinks in existing components resolved and the final
/// component kept as written, so two spellings of the same item compare
/// equal and a destination that does not exist yet is still comparable.
func canonicalPath(_ url: URL) -> String {
    url.deletingLastPathComponent()
        .resolvingSymlinksInPath()
        .appendingPathComponent(url.lastPathComponent)
        .path
}
/// Names Finder accepts but that break path round-trips (line breaks, colon,
/// control characters) are rejected before they reach the filesystem.
enum FileName {
    static func problem(_ name: String) -> String? {
        if name.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose a valid filename."
        }
        if name == "." || name == ".." { return "Choose a valid filename." }
        if name.contains("/") || name.contains(":") || name.contains("\0") {
            return "Choose a valid filename without slashes, colons, or null characters."
        }
        if name.rangeOfCharacter(from: .controlCharacters) != nil {
            return "Choose a valid filename without line breaks or control characters."
        }
        if name.utf8.count > 255 {
            return "Choose a filename of 255 characters or fewer."
        }
        return nil
    }
}
enum LocalFiles {
    /// Directory entries provide names and basic kinds without requesting every
    /// file's size, date, or provider metadata first.
    static func preview(_ folder: URL, hidden: Bool) async throws -> [Hit] {
        return try await BackgroundWork.run {
            guard let directory = opendir(folder.path) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { closedir(directory) }
            var hits: [Hit] = []
            while true {
                try Task.checkCancellation()
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1)
                    {
                        String(cString: $0)
                    }
                }
                guard name != ".", name != "..", hidden || !name.hasPrefix(".") else { continue }
                let kind: String
                switch Int32(entry.pointee.d_type) {
                case DT_DIR: kind = "dir"
                case DT_REG: kind = "file"
                default: kind = "pending"
                }
                let path = folder.path + (folder.path == "/" ? "" : "/") + name
                hits.append(
                    Hit(
                        path: path, kind: kind, size: 0, mtime: 0, score: 0,
                        metadataPending: true))
            }
            return hits
        }
    }

    static func load(_ folder: URL, hidden: Bool) async throws -> [Hit] {
        try await BackgroundWork.run { try list(folder, hidden: hidden) }
    }
    static func list(_ folder: URL, hidden: Bool) throws -> [Hit] {
        try Task.checkCancellation()
        do {
            if let hits = try BulkDirectory.list(folder, hidden: hidden) { return hits }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Discard partial bulk results and retry through Foundation.
            try Task.checkCancellation()
        }
        return try foundationList(folder, hidden: hidden)
    }
    static func foundationList(_ folder: URL, hidden: Bool) throws -> [Hit] {
        try Task.checkCancellation()
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ], options: hidden ? [] : [.skipsHiddenFiles])
        var hits: [Hit] = []; hits.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            // FileManager resolves parent aliases (including /var → /private/var).
            // Keep identities aligned with preview and optimistic mutation paths.
            if let hit = try? Hit.read(url, parent: folder) { hits.append(hit) }
        }
        return hits
    }
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) == 0 }
    }
    static func availableName(
        in folder: URL, name: String, suffix: String = "", reserved: Set<String> = []
    ) -> URL {
        let original = URL(fileURLWithPath: name)
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        var i = 0
        while true {
            // Name probing is called only from background command preparation.
            let tail = suffix + (i == 0 ? "" : " \(i + 1)")
            let candidate = folder.appendingPathComponent(
                base + tail + (ext.isEmpty ? "" : "." + ext))
            if !exists(candidate), !reserved.contains(candidate.path) { return candidate }
            i += 1
        }
    }
    /// Never overwrite. Successful mutations retain inverses even if another item fails.
    static func apply(_ operations: [FileMutation], control: FileOperationControl? = nil)
        -> FileBatch
    {
        var batch = FileBatch()
        for (index, op) in operations.enumerated() {
            if control?.isCancelled == true {
                batch.cancelled = true; batch.failed.append(contentsOf: operations[index...]); break
            }
            let source: URL?
            switch op {
            case .copy(let url, _), .move(let url, _), .trash(let url), .extract(let url, _),
                .replace(let url, _, _):
                source = url
            case .compress(let urls, _): source = urls.first
            default: source = nil
            }
            let size = source.flatMap {
                try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            }
            control?.start(
                item: source?.lastPathComponent ?? "Creating item…", completed: index,
                total: operations.count,
                expectedBytes: size?.isRegularFile == true ? Int64(size?.fileSize ?? 0) : 0)
            do {
                if case .renameBatch(let moves) = op {
                    let renamed = BatchRenames.apply(
                        moves, control: control ?? FileOperationControl())
                    batch.inverse.insert(contentsOf: renamed.inverse, at: 0)
                    batch.errors.append(contentsOf: renamed.errors);
                    batch.failed.append(contentsOf: renamed.failed)
                    if renamed.cancelled {
                        batch.cancelled = true;
                        batch.failed.append(contentsOf: operations.dropFirst(index + 1)); break
                    }
                    continue
                }
                if case .replace(let source, let destination, let move) = op {
                    let old = apply([.trash(destination)])
                    guard old.errors.isEmpty, let restore = old.inverse.first else {
                        batch.errors.append(contentsOf: old.errors); batch.failed.append(op);
                        continue
                    }
                    let replacement = apply(
                        [move ? .move(source, destination) : .copy(source, destination)],
                        control: control)
                    if replacement.failed.isEmpty {
                        batch.inverse.insert(contentsOf: replacement.inverse + [restore], at: 0)
                    } else {
                        let recovered = apply([restore])
                        if !recovered.errors.isEmpty { batch.inverse.insert(restore, at: 0) }
                        batch.errors.append(contentsOf: replacement.errors + recovered.errors)
                        batch.failed.append(op)
                        if replacement.cancelled {
                            batch.cancelled = true
                            batch.failed.append(contentsOf: operations.dropFirst(index + 1)); break
                        }
                    }
                    continue
                }
                let inverse: FileMutation
                switch op {
                case .copy(let source, let destination):
                    if let control {
                        try NativeFileCopy.copy(source, to: destination, control: control)
                    } else {
                        try FileManager.default.copyItem(at: source, to: destination)
                    }
                    inverse = .trash(destination)
                case .move(let source, let destination):
                    guard source.standardizedFileURL != destination.standardizedFileURL else {
                        continue
                    }
                    // APFS volumes are case-preserving but case-insensitive:
                    // fileExists reports the file's own old casing, so compare
                    // that case apart before refusing a case-only rename.
                    let caseOnlyRename =
                        canonicalPath(destination).lowercased()
                        == canonicalPath(source).lowercased()
                    guard caseOnlyRename
                        || !FileManager.default.fileExists(atPath: destination.path)
                    else {
                        throw NSError(
                            domain: "FinderSearch", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "An item named ‘\(destination.lastPathComponent)’ already exists."
                            ])
                    }
                    if let control {
                        try NativeFileCopy.move(source, to: destination, control: control)
                    } else {
                        try FileManager.default.moveItem(at: source, to: destination)
                    }
                    inverse = .move(destination, source)
                case .trash(let source):
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: source, resultingItemURL: &trashed)
                    guard let trashed else { throw CocoaError(.fileWriteUnknown) }
                    inverse = .move(trashed as URL, source)
                case .tags(let url, let tags):
                    let old = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                    try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
                    inverse = .tags(url, old)
                case .folder(let destination):
                    try FileManager.default.createDirectory(
                        at: destination, withIntermediateDirectories: false)
                    inverse = .trash(destination)
                case .textFile(let destination):
                    try Data().write(to: destination, options: .withoutOverwriting)
                    inverse = .trash(destination)
                case .compress(let sources, let destination):
                    try ArchiveFiles.compress(
                        sources, to: destination, control: control ?? FileOperationControl())
                    inverse = .trash(destination)
                case .extract(let source, let destination):
                    try ArchiveFiles.extract(
                        source, to: destination, control: control ?? FileOperationControl())
                    inverse = .trash(destination)
                case .replace, .renameBatch:
                    preconditionFailure("Replacement is handled as a recoverable transaction")
                }
                batch.inverse.insert(inverse, at: 0)
            } catch is CancellationError {
                batch.cancelled = true; batch.failed.append(contentsOf: operations[index...]); break
            } catch { batch.errors.append(error.localizedDescription); batch.failed.append(op) }
        }
        return batch
    }
}

enum FileOrdering {
    struct Cache {
        let source: [Hit]
        let ordered: [Hit]
        let sort: FileSort
        let ascending: Bool
        let showHidden: Bool
        let isSearch: Bool
        let locale: String
    }

    static func cached(
        _ hits: [Hit], sort: FileSort, ascending: Bool, showHidden: Bool, isSearch: Bool,
        previous: Cache? = nil
    ) throws -> Cache {
        try Task.checkCancellation()
        let locale = Locale.current.identifier
        func result(_ ordered: [Hit]) -> Cache {
            Cache(
                source: hits, ordered: ordered, sort: sort, ascending: ascending,
                showHidden: showHidden, isSearch: isSearch, locale: locale)
        }
        if let previous, previous.sort == sort, previous.showHidden == showHidden,
            previous.isSearch == isSearch, previous.locale == locale
        {
            if previous.source == hits {
                if previous.ascending == ascending || (isSearch && sort == .relevance) {
                    return result(previous.ordered)
                }
                // Reversing equal-key duplicates would violate stable sorting.
                var paths = Set<String>()
                paths.reserveCapacity(previous.ordered.count)
                var unique = true
                for hit in previous.ordered {
                    try Task.checkCancellation()
                    if !paths.insert(hit.path).inserted { unique = false; break }
                }
                if unique { return result(Array(previous.ordered.reversed())) }
            }
            if sort == .name && previous.ordered.count == hits.count {
                // Exact visible membership is required; metadata can change freely.
                // Inputs containing filtered rows conservatively take the full sort.
                var byPath: [String: Hit] = [:]
                byPath.reserveCapacity(hits.count)
                var unique = true
                for hit in hits {
                    try Task.checkCancellation()
                    if byPath.updateValue(hit, forKey: hit.path) != nil { unique = false; break }
                }
                if unique {
                    var ordered: [Hit] = []
                    ordered.reserveCapacity(previous.ordered.count)
                    for hit in previous.ordered {
                        try Task.checkCancellation()
                        guard let updated = byPath.removeValue(forKey: hit.path) else {
                            unique = false; break
                        }
                        ordered.append(updated)
                    }
                    if unique {
                        if previous.ascending != ascending { ordered.reverse() }
                        return result(ordered)
                    }
                }
            }
        }
        return result(
            try sorted(
                hits, sort: sort, ascending: ascending,
                showHidden: showHidden, isSearch: isSearch))
    }

    static func prepareCached(
        _ hits: [Hit], sort: FileSort, ascending: Bool, showHidden: Bool, isSearch: Bool,
        previous: Cache? = nil
    ) async throws -> Cache {
        try await BackgroundWork.run {
            try cached(
                hits, sort: sort, ascending: ascending, showHidden: showHidden,
                isSearch: isSearch, previous: previous)
        }
    }

    private struct Entry {
        let hit: Hit
        let name: String
        let type: String
    }

    static func sorted(
        _ hits: [Hit], sort: FileSort, ascending: Bool, showHidden: Bool, isSearch: Bool
    ) throws -> [Hit] {
        var types: [String: String] = [:]
        var entries: [Entry] = []
        entries.reserveCapacity(hits.count)
        for hit in hits {
            try Task.checkCancellation()
            let name = hit.name
            guard showHidden || !name.hasPrefix(".") else { continue }
            var type = ""
            if sort == .kind {
                let key = hit.kind + ":" + hit.url.pathExtension.lowercased()
                if let cached = types[key] {
                    type = cached
                } else {
                    type = hit.typeName; types[key] = type
                }
            }
            entries.append(Entry(hit: hit, name: name, type: type))
        }
        if isSearch && sort == .relevance { return entries.map(\.hit) }
        var comparisons = 0
        let ordered = try entries.sorted { a, b in
            comparisons += 1
            if comparisons % 1024 == 0 { try Task.checkCancellation() }
            let comparison: ComparisonResult
            switch sort {
            case .modified:
                comparison =
                    a.hit.mtime == b.hit.mtime
                    ? .orderedSame
                    : a.hit.mtime < b.hit.mtime ? .orderedAscending : .orderedDescending
            case .size:
                comparison =
                    a.hit.size == b.hit.size
                    ? .orderedSame
                    : a.hit.size < b.hit.size ? .orderedAscending : .orderedDescending
            case .kind: comparison = a.type.localizedStandardCompare(b.type)
            default: comparison = a.name.localizedStandardCompare(b.name)
            }
            if comparison == .orderedSame {
                return ascending ? a.hit.path < b.hit.path : a.hit.path > b.hit.path
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        return ordered.map(\.hit)
    }

    static func prepare(
        _ hits: [Hit], sort: FileSort, ascending: Bool, showHidden: Bool, isSearch: Bool
    ) async throws -> [Hit] {
        try await BackgroundWork.run {
            try sorted(
                hits, sort: sort, ascending: ascending, showHidden: showHidden, isSearch: isSearch)
        }
    }
}

/// Pixel sizes for 16-point rows and large previews on Retina displays.
enum FileIconSize: Int, Sendable {
    case row = 32
    case compact = 128
    case preview = 256
}

final class FileIcons: @unchecked Sendable {
    static let shared = FileIcons()
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "FinderSearch.icons";
        queue.qualityOfService = .utility; queue.maxConcurrentOperationCount = 4; return queue
    }()
    private init() { cache.countLimit = 1024; cache.totalCostLimit = 16 * 1024 * 1024 }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }
    func load(_ hit: Hit, size: FileIconSize = .preview) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = (hit.path + ":" + String(hit.mtime) + ":" + String(size.rawValue)) as NSString
        if let image = cache.object(forKey: key) { return image }
        let request = Request()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    // A cancelled view still resumes its continuation, but skips
                    // the expensive filesystem/icon lookup when its job starts.
                    continuation.resume(
                        returning: request.isCancelled ? nil : self.icon(hit, size: size))
                }
            }
        } onCancel: {
            request.cancel()
        }
    }
    func placeholder(_ hit: Hit, size: FileIconSize = .preview) -> NSImage {
        let type =
            hit.kind == "dir"
            ? UTType.folder : UTType(filenameExtension: hit.url.pathExtension) ?? .data
        let key = "type:" + type.identifier + ":" + String(size.rawValue)
        if let image = cache.object(forKey: key as NSString) { return image }
        let image = ImageRasterizer.bitmap(
            NSWorkspace.shared.icon(for: type), pixels: size.rawValue)
        cache.setObject(image, forKey: key as NSString, cost: ImageRasterizer.cost(image))
        return image
    }
    /// Runs on the icon queue. IconServices images otherwise rasterize lazily on
    /// the main thread the first time each grid cell draws.
    func icon(_ hit: Hit, size: FileIconSize = .preview) -> NSImage {
        let key = (hit.path + ":" + String(hit.mtime) + ":" + String(size.rawValue)) as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = ImageRasterizer.bitmap(
            NSWorkspace.shared.icon(forFile: hit.path), pixels: size.rawValue)
        cache.setObject(image, forKey: key, cost: ImageRasterizer.cost(image))
        return image
    }
}

/// Produces fully decoded bitmap images off the main thread so drawing a cell
/// only uploads pixels instead of decoding or rasterizing them.
enum ImageRasterizer {
    static let iconPixels = 256
    static func bitmap(_ image: NSImage, pixels: Int = iconPixels) -> NSImage {
        var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
            let decoded = decode(source, maxPixels: pixels)
        else { return image }
        return NSImage(cgImage: decoded, size: aspectSize(decoded, points: Double(pixels) / 2))
    }
    static func decode(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
    static func aspectSize(_ image: CGImage, points: Double) -> NSSize {
        let longest = Double(max(image.width, image.height, 1))
        return NSSize(
            width: points * Double(image.width) / longest,
            height: points * Double(image.height) / longest)
    }
    static func cost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 1 }
        return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
    }
}
