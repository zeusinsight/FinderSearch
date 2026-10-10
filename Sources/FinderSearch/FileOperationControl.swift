import Foundation
import Darwin

struct FileOperationProgress: Sendable {
    var completed = 0
    var total = 0
    var item = "Preparing…"
    var bytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var fraction: Double? {
        guard total > 0, expectedBytes > 0 else { return nil }
        return min(
            1, (Double(completed) + min(1, Double(bytes) / Double(expectedBytes))) / Double(total))
    }
}

/// One cancellation token owns a batch, its copyfile callbacks, and any archive process.
final class FileOperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    private var progress = FileOperationProgress()
    private var lastReport = Date.distantPast
    private let report: @Sendable (FileOperationProgress) -> Void

    init(report: @escaping @Sendable (FileOperationProgress) -> Void = { _ in }) {
        self.report = report
    }
    var isCancelled: Bool { lock.withLock { cancelled } }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }
    func cancel() {
        let active = lock.withLock {
            cancelled = true; return process
        }
        if let active, active.isRunning { active.terminate() }
    }
    func start(item: String, completed: Int, total: Int, expectedBytes: Int64 = 0) {
        let value = lock.withLock {
            progress = FileOperationProgress(
                completed: completed, total: total, item: item,
                expectedBytes: expectedBytes)
            lastReport = .distantPast; return progress
        }
        report(value)
    }
    func copied(_ bytes: Int64) {
        let value: FileOperationProgress? = lock.withLock {
            progress.bytes = bytes
            guard Date().timeIntervalSince(lastReport) >= 0.08 else { return nil }
            lastReport = .distantPast; return progress
        }
        if let value { report(value) }
    }
    func run(_ executable: String, arguments: [String], directory: URL? = nil) throws -> Data {
        try checkCancellation()
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments; task.currentDirectoryURL = directory
        // A temporary log avoids pipe-buffer deadlocks on verbose tools.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        task.standardOutput = handle; task.standardError = handle
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try task.run(); process = task
        }
        task.waitUntilExit()
        lock.withLock { process = nil }
        try checkCancellation()
        let reader = try FileHandle(forReadingFrom: log)
        defer { try? reader.close() }
        let output = try reader.read(upToCount: 4096) ?? Data()
        guard task.terminationStatus == 0 else {
            throw Engine.Failure.message(
                String(data: output.prefix(4096), encoding: .utf8) ?? "The operation failed.")
        }
        return output
    }
}

private let copyProgress: copyfile_callback_t = { what, stage, state, _, _, context in
    guard let context else { return COPYFILE_QUIT }
    let control = Unmanaged<FileOperationControl>.fromOpaque(context).takeUnretainedValue()
    if control.isCancelled { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
            control.copied(copied)
        }
    }
    // Returning CONTINUE for a data error asks copyfile to retry indefinitely.
    return stage == COPYFILE_ERR ? COPYFILE_QUIT : COPYFILE_CONTINUE
}

enum NativeFileCopy {
    static func copy(_ source: URL, to destination: URL, control: FileOperationControl) throws {
        try control.checkCancellation()
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".FinderSearch-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let state = copyfile_state_alloc() else { throw CocoaError(.fileWriteUnknown) }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passUnretained(control).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
        let callback = unsafeBitCast(copyProgress, to: UnsafeRawPointer.self)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), callback)
        let flags = copyfile_flags_t(
            COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
        let status = source.path.withCString { src in
            staging.path.withCString { dst in copyfile(src, dst, state, flags) }
        }
        let failure = errno
        try control.checkCancellation()
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    static func move(_ source: URL, to destination: URL, control: FileOperationControl) throws {
        try control.checkCancellation()
        let status = source.path.withCString { src in
            destination.path.withCString { dst in renamex_np(src, dst, UInt32(RENAME_EXCL)) }
        }
        guard status != 0 else { return }
        guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try copy(source, to: destination, control: control)
        do { try control.checkCancellation() } catch {
            try? FileManager.default.removeItem(at: destination); throw error
        }
        // Once source removal starts, retain the complete copy if removal fails.
        // Removing the destination here could lose files after a partial directory removal.
        try FileManager.default.removeItem(at: source)
    }
}
