import Foundation
import Darwin

struct Hit: Decodable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let kind: String
    let size: UInt64
    let mtime: UInt64
    let score: Int64
    var metadataPending: Bool? = nil
    var url: URL { URL(fileURLWithPath: path, isDirectory: kind == "dir") }
    var name: String { (path as NSString).lastPathComponent }
    var imageKey: String { path + ":" + String(mtime) + ":" + String(metadataPending == true) }
    var parent: String {
        (path as NSString).deletingLastPathComponent.replacingOccurrences(
            of: NSHomeDirectory(), with: "~", options: .anchored)
    }
}
/// One matching line inside a file, from a content search.
struct ContentMatch: Decodable, Hashable {
    let line: Int
    let text: String
}
/// A file that matched a content search, with its matching lines.
struct ContentFile: Decodable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let matches: [ContentMatch]
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}
struct Reply: Decodable {
    let ok: Bool
    let error: String?
    let hits: [Hit]?
    let took_us: UInt64?
    let entries: Int?
    let full_disk_access: Bool?
    /// Content-search replies carry files with matching lines.
    var files: [ContentFile]? = nil
    /// "index" when the content index answered, "scan" when files were read.
    var source: String? = nil
    /// Files the engine looked at, and whether the time budget ran out first.
    var read: Int? = nil
    var complete: Bool? = nil
    /// Text files still waiting to enter the content index.
    var indexing: Int? = nil
}

protocol SearchService: Sendable {
    func request(_ fields: [String: Any]) async throws -> Reply
}

/// Minimal reply shape used to correlate responses with requests.
private struct ReplyTag: Decodable { let id: String? }

/// A single warm stdio client. Blocking I/O stays on its own serial queue.
final class Engine: SearchService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FinderSearch.engine", qos: .userInitiated)
    private let binaryOverride: String?
    init(binary: String? = nil) { binaryOverride = binary }
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    /// Replies still owed to cancelled requests. The helper answers in order,
    /// so each one is discarded by the next reader before its own reply.
    private var staleReplies = 0
    /// Whether a helper process is attached; a cancelled request leaves it running.
    var helperAttached: Bool { process != nil }
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }; return nil
        }
    }
    private func connect() throws {
        // The helper is a child process: writing after it exits raises SIGPIPE,
        // which kills the app outright unless writes are told to expect it.
        signal(SIGPIPE, SIG_IGN)
        if process?.isRunning == true { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fsearch").path
        let candidates = [
            binaryOverride ?? "", bundled,
            ProcessInfo.processInfo.environment["FSEARCH_BINARY"] ?? "",
            NSHomeDirectory() + "/.local/bin/fsearch",
            FileManager.default.currentDirectoryPath + "/vendor/fsearch/target/release/fsearch",
        ]
        guard
            let binary = candidates.first(where: {
                !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0)
            })
        else {
            throw Failure.message("Search engine missing. Run scripts/build.sh to bundle fsearch.")
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["stdio"]
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        buffer.removeAll(); staleReplies = 0
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }
    func request(_ fields: [String: Any]) async throws -> Reply {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var sent = false
                queue.async {
                    do {
                        try cancellation.check()
                        try self.connect()
                        // Requests carry an id the daemon echoes back. The
                        // count of replies owed to cancelled requests is the
                        // fallback for helpers that do not echo ids: because
                        // replies arrive in request order, each stale line can
                        // be identified well enough to discard it.
                        var payload = fields
                        let id = UUID().uuidString
                        payload["id"] = id
                        let data = try JSONSerialization.data(withJSONObject: payload)
                        guard self.process?.isRunning == true, let input = self.input else {
                            throw Failure.message("Engine disconnected.")
                        }
                        try input.write(contentsOf: data + Data([10]))
                        sent = true
                        guard let output = self.output else {
                            throw Failure.message("Engine disconnected.")
                        }
                        let deadline = Date().addingTimeInterval(15)
                        while true {
                            while !self.buffer.contains(10) {
                                try cancellation.check()
                                let remaining = deadline.timeIntervalSinceNow
                                guard remaining > 0 else {
                                    throw Failure.message("Search engine timed out. Try again.")
                                }
                                var fd = pollfd(
                                    fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
                                let result = poll(&fd, 1, Int32(min(remaining, 0.1) * 1000))
                                if result == 0 { continue }
                                if result < 0 {
                                    // A signal can interrupt poll; anything else means
                                    // the descriptor went away, not that we were slow.
                                    if errno == EINTR { continue }
                                    throw Failure.message("Search engine stopped. Try again.")
                                }
                                if Int32(fd.revents) & (POLLHUP | POLLERR | POLLNVAL) != 0 {
                                    throw Failure.message("Search engine stopped. Try again.")
                                }
                                let chunk = output.availableData
                                guard !chunk.isEmpty else {
                                    throw Failure.message("Search engine stopped. Try again.")
                                }
                                self.buffer.append(chunk)
                            }
                            try cancellation.check()
                            let newline = self.buffer.firstIndex(of: 10)!
                            let line = self.buffer.prefix(upTo: newline)
                            self.buffer.removeSubrange(...newline)
                            let tag = try? JSONDecoder().decode(ReplyTag.self, from: line)
                            if tag?.id == id {
                                self.staleReplies = 0
                                continuation.resume(
                                    returning: try JSONDecoder().decode(Reply.self, from: line))
                                break
                            }
                            if tag?.id != nil || self.staleReplies > 0 {
                                // Either a reply carrying another request's id, or a
                                // line the helper owes an abandoned request. Neither
                                // may be answered to this request.
                                self.staleReplies = max(0, self.staleReplies - 1)
                                try cancellation.check()
                                guard Date() < deadline else {
                                    throw Failure.message("Search engine timed out. Try again.")
                                }
                                continue
                            }
                            // A reply that cannot be correlated: the helper does
                            // not echo ids and nothing suggests it is stale.
                            self.staleReplies = 0
                            continuation.resume(
                                returning: try JSONDecoder().decode(Reply.self, from: line))
                            break
                        }
                    } catch {
                        // Cancellation is not a fault: the helper stays warm for
                        // the next request. Only real I/O failures replace it.
                        if error is CancellationError {
                            if sent {
                                // This request's reply still belongs to the
                                // stream. Complete lines are left for the next
                                // reader to discard; a partial line is dropped so
                                // it cannot corrupt the next request's line.
                                if self.buffer.contains(10) {
                                    self.staleReplies += 1
                                } else {
                                    self.buffer.removeAll(); self.staleReplies += 1
                                }
                            }
                            continuation.resume(throwing: error)
                        } else {
                            // Drop the state first so the next request reconnects,
                            // then reap off this queue: a helper that ignores
                            // SIGTERM must never block the engine.
                            let dying = self.process
                            self.process = nil
                            self.input = nil; self.output = nil; self.buffer.removeAll()
                            self.staleReplies = 0
                            dying?.terminate()
                            if let dying {
                                DispatchQueue.global(qos: .utility).async {
                                    dying.waitUntilExit()
                                }
                            }
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    deinit { process?.terminate() }
}
