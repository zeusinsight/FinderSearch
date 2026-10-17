import Darwin
import Foundation

/// A daemon keeps its executable and startup permissions across app launches.
/// Restart only our own executable; the shared index is preserved and fsearch
/// rescans previously skipped folders when it starts with Full Disk Access.
enum RestrictedDaemon {
    private static let lock = NSLock()
    private static var attempted: Set<String> = []

    static func recover(
        binary: String,
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FSearch"),
        ifStartedBefore replacementDate: Date? = nil
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let path = directory.appendingPathComponent("socket.lock").path
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        // No owner: reconnect and let the helper start a fresh daemon.
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return true
        }
        guard errno == EWOULDBLOCK else { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0,
            let pid = pid_t(
                String(decoding: bytes.prefix(count), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)),
            pid > 1, pid != getpid()
        else { return false }
        var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &executable, UInt32(executable.count)) > 0 else { return false }
        let actual = URL(fileURLWithPath: String(cString: executable)).resolvingSymlinksInPath()
            .path
        let expected = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        guard actual == expected else { return false }
        if let replacementDate {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
                return false
            }
            let started =
                TimeInterval(info.pbi_start_tvsec)
                + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            guard started < replacementDate.timeIntervalSince1970 else { return false }
        }
        // A helper may have a separate permission grant. Never restart it in a
        // loop if it still reports restricted access after this one attempt.
        guard attempted.insert(expected).inserted else { return false }
        guard kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw Engine.Failure.message(
                L10n.string("Could not restart the search engine. Try again shortly."))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Engine.Failure.message(
            L10n.string("Search engine is still stopping. Try again shortly."))
    }
}
