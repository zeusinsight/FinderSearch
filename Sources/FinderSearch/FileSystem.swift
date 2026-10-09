import Foundation
import AppKit
import UniformTypeIdentifiers

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

enum FileMutation {
    case copy(URL, URL), move(URL, URL), trash(URL), folder(URL), tags(URL, [String])
}
struct FileBatch {
    var inverse: [FileMutation] = []
    var errors: [String] = []
    var failed: [FileMutation] = []
}
enum LocalFiles {
    static func load(_ folder: URL, hidden: Bool) async throws -> [Hit] {
        let task = Task.detached(priority: .userInitiated) { try list(folder, hidden: hidden) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
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
                }
                batch.inverse.insert(inverse, at: 0)
            } catch { batch.errors.append(error.localizedDescription); batch.failed.append(op) }
        }
        return batch
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
    func load(_ hit: Hit) async -> NSImage {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: self.icon(hit)) }
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
