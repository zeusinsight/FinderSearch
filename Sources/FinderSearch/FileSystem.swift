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
    static func read(_ url: URL) throws -> Hit {
        let v = try url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        return Hit(
            path: url.path, kind: v.isDirectory == true ? "dir" : "file",
            size: UInt64(max(0, v.fileSize ?? 0)),
            mtime: UInt64(
                max(0, (v.contentModificationDate ?? .distantPast).timeIntervalSince1970)), score: 0
        )
    }
}

enum FileMutation: Equatable {
    case copy(URL, URL), move(URL, URL), trash(URL), folder(URL), textFile(URL), tags(URL, [String])
}
struct FileBatch {
    var inverse: [FileMutation] = []
    var errors: [String] = []
    var failed: [FileMutation] = []
}

enum OptimisticFiles {
    static func applying(_ operations: [FileMutation], to hits: [Hit], in folder: URL?) -> [Hit] {
        var result = hits
        for operation in operations {
            switch operation {
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
                        || (folder == nil && destination.deletingLastPathComponent().path
                            == source.deletingLastPathComponent().path)
                {
                    result.append(Hit(path: destination.path, kind: original.kind,
                        size: original.size, mtime: original.mtime, score: original.score,
                        metadataPending: original.metadataPending))
                }
            case .copy(let source, let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path }),
                    let original = result.first(where: { $0.path == source.path })
                else { continue }
                result.append(Hit(path: destination.path, kind: original.kind,
                    size: original.size, mtime: original.mtime, score: original.score,
                    metadataPending: original.metadataPending))
            case .folder(let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path })
                else { continue }
                result.append(Hit(path: destination.path, kind: "dir", size: 0,
                    mtime: UInt64(Date().timeIntervalSince1970), score: 0))
            case .textFile(let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path }) else { continue }
                result.append(Hit(path: destination.path, kind: "file", size: 0,
                    mtime: UInt64(Date().timeIntervalSince1970), score: 0))
            case .tags: break
            }
        }
        return result
    }

    static func selection(
        _ selection: Set<String>, after operations: [FileMutation], visibleHits: [Hit]
    ) -> Set<String> {
        var result = selection
        let visible = Set(visibleHits.map(\.path))
        for operation in operations {
            switch operation {
            case .move(let source, let destination):
                guard !visible.contains(source.path) else { continue }
                if result.remove(source.path) != nil && visible.contains(destination.path) {
                    result.insert(destination.path)
                }
            case .trash(let source): result.remove(source.path)
            default: break
            }
        }
        return result.intersection(visible)
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
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
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
                hits.append(Hit(path: path, kind: kind, size: 0, mtime: 0, score: 0,
                    metadataPending: true))
            }
            return hits
        }
    }

    static func load(_ folder: URL, hidden: Bool) async throws -> [Hit] {
        try await BackgroundWork.run { try list(folder, hidden: hidden) }
    }
    static func list(_ folder: URL, hidden: Bool) throws -> [Hit] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ], options: hidden ? [] : [.skipsHiddenFiles])
        var hits: [Hit] = []; hits.reserveCapacity(urls.count)
        for url in urls {
            try Task.checkCancellation()
            if let hit = try? Hit.read(url) { hits.append(hit) }
        }
        return hits
    }
    static func availableName(in folder: URL, name: String, suffix: String = "") -> URL {
        let original = URL(fileURLWithPath: name)
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        var i = 0
        while true {
            // Name probing is called only from background command preparation.
            let tail = suffix + (i == 0 ? "" : " \(i + 1)")
            let candidate = folder.appendingPathComponent(
                base + tail + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
    /// Never overwrite. Successful mutations retain inverses even if another item fails.
    static func apply(_ operations: [FileMutation]) -> FileBatch {
        var batch = FileBatch()
        for op in operations {
            do {
                let inverse: FileMutation
                switch op {
                case .copy(let source, let destination):
                    try FileManager.default.copyItem(at: source, to: destination)
                    inverse = .trash(destination)
                case .move(let source, let destination):
                    guard source.standardizedFileURL != destination.standardizedFileURL else {
                        continue
                    }
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw NSError(
                            domain: "FinderSearch", code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "An item named ‘\(destination.lastPathComponent)’ already exists."
                            ])
                    }
                    try FileManager.default.moveItem(at: source, to: destination)
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
                }
                batch.inverse.insert(inverse, at: 0)
            } catch { batch.errors.append(error.localizedDescription); batch.failed.append(op) }
        }
        return batch
    }
}

enum FileOrdering {
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
                if let cached = types[key] { type = cached }
                else { type = hit.typeName; types[key] = type }
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
                comparison = a.hit.mtime == b.hit.mtime ? .orderedSame
                    : a.hit.mtime < b.hit.mtime ? .orderedAscending : .orderedDescending
            case .size:
                comparison = a.hit.size == b.hit.size ? .orderedSame
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
            try sorted(hits, sort: sort, ascending: ascending, showHidden: showHidden, isSearch: isSearch)
        }
    }
}

final class FileIcons: @unchecked Sendable {
    static let shared = FileIcons()
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "FinderSearch.icons";
        queue.qualityOfService = .utility; queue.maxConcurrentOperationCount = 4; return queue
    }()
    private init() { cache.countLimit = 1024 }
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }
    func load(_ hit: Hit) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = (hit.path + ":" + String(hit.mtime)) as NSString
        if let image = cache.object(forKey: key) { return image }
        let request = Request()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    // A cancelled view still resumes its continuation, but skips
                    // the expensive filesystem/icon lookup when its job starts.
                    continuation.resume(returning: request.isCancelled ? nil : self.icon(hit))
                }
            }
        } onCancel: {
            request.cancel()
        }
    }
    func placeholder(_ hit: Hit) -> NSImage {
        let type =
            hit.kind == "dir"
            ? UTType.folder : UTType(filenameExtension: hit.url.pathExtension) ?? .data
        let key = "type:" + type.identifier
        if let image = cache.object(forKey: key as NSString) { return image }
        let image = NSWorkspace.shared.icon(for: type)
        cache.setObject(image, forKey: key as NSString)
        return image
    }
    func icon(_ hit: Hit) -> NSImage {
        let key = (hit.path + ":" + String(hit.mtime)) as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: hit.path)
        cache.setObject(image, forKey: key)
        return image
    }
}
