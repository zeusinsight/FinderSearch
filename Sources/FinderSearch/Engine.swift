import Foundation
import Darwin

struct Hit: Decodable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let kind: String
    let size: UInt64
    let mtime: UInt64
    let score: Int64
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var parent: String {
        url.deletingLastPathComponent().path.replacingOccurrences(
            of: NSHomeDirectory(), with: "~", options: .anchored)
    }
}
struct Reply: Decodable {
    let ok: Bool
    let error: String?
    let hits: [Hit]?
    let took_us: UInt64?
    let entries: Int?
    let full_disk_access: Bool?
}

protocol SearchService: Sendable {
    func request(_ fields: [String: Any]) async throws -> Reply
}

/// A single warm stdio client. Blocking I/O stays on its own serial queue.
final class Engine: SearchService, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FinderSearch.engine", qos: .userInitiated)
    private let binaryOverride: String?
    init(binary: String? = nil) { binaryOverride = binary }
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }; return nil
        }
    }
    private func connect() throws {
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
        buffer.removeAll()
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
                queue.async {
                    do {
                        try cancellation.check()
                        try self.connect()
                        let data = try JSONSerialization.data(withJSONObject: fields)
                        try self.input?.write(contentsOf: data + Data([10]))
                        guard let output = self.output else {
                            throw Failure.message("Engine disconnected.")
                        }
                        let deadline = Date().addingTimeInterval(15)
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
                            guard result > 0 else {
                                throw Failure.message("Search engine timed out. Try again.")
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
                        continuation.resume(
                            returning: try JSONDecoder().decode(Reply.self, from: line))
                    } catch {
                        self.process?.terminate(); self.process = nil
                        self.input = nil; self.output = nil; self.buffer.removeAll()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    deinit { process?.terminate() }
}
