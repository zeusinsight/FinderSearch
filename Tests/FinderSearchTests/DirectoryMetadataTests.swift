import XCTest
@testable import FinderSearch

// Previous production loader, retained as the performance baseline.
import Darwin
import Foundation

/// Bulk metadata for ordinary local files. Foundation handles providers,
/// other filesystems, and entries whose URL semantics need special handling.
private enum FileOnlyBulkBaseline {
    enum ReadError: Error { case invalidRecord }

    private static func hiddenFlagMapsFinderInfo(_ fd: Int32) -> Bool {
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES)
        var buffer = [UInt8](repeating: 0, count: 4 + MemoryLayout<vol_capabilities_attr_t>.size)
        return buffer.withUnsafeMutableBytes { bytes in
            guard fgetattrlist(fd, &attrs, bytes.baseAddress!, bytes.count, 0) == 0,
                bytes.loadUnaligned(as: UInt32.self) == UInt32(bytes.count)
            else { return false }
            let caps = bytes.loadUnaligned(fromByteOffset: 4, as: vol_capabilities_attr_t.self)
            // VOL_CAP_FMT_HIDDEN_FILES promises that UF_HIDDEN reflects the
            // filesystem's native invisible bit, including FinderInfo.
            return caps.valid.0 & caps.capabilities.0 & UInt32(VOL_CAP_FMT_HIDDEN_FILES) != 0
        }
    }

    static func supports(path: String, fileSystem: String, local: Bool) -> Bool {
        local && (fileSystem == "apfs" || fileSystem == "hfs") && !isProviderPath(path)
    }

    private static func isProviderPath(_ path: String) -> Bool {
        path == "/Network" || path.hasPrefix("/Network/")
            || path.contains("/Library/CloudStorage") || path.contains("/Library/Mobile Documents")
    }

    static func list(_ folder: URL, hidden: Bool) throws -> [Hit]? {
        try Task.checkCancellation()
        let resolved = folder.resolvingSymlinksInPath().path
        guard !isProviderPath(resolved) else { return nil }
        var info = stat()
        guard lstat(resolved, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            return nil
        }
        let fd = open(resolved, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0 else { return nil }
        let fileSystem = withUnsafeBytes(of: volume.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard
            supports(
                path: resolved, fileSystem: fileSystem,
                local: volume.f_flags & UInt32(MNT_LOCAL) != 0)
        else { return nil }

        let needsFinderInfo = !hidden && !hiddenFlagMapsFinderInfo(fd)
        var attrs = attrlist()
        attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrs.commonattr =
            UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR)
            | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME)
            | UInt32(ATTR_CMN_FLAGS)
        if needsFinderInfo { attrs.commonattr |= UInt32(ATTR_CMN_FNDRINFO) }
        attrs.fileattr = UInt32(ATTR_FILE_DATALENGTH)
        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        let path = folder.path
        let prefix = path + (path == "/" ? "" : "/")
        var hits: [Hit] = []
        while true {
            try Task.checkCancellation()
            let count = getattrlistbulk(fd, &attrs, buffer, capacity, 0)
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if count == 0 { return hits }
            var offset = 0
            for _ in 0..<count {
                try Task.checkCancellation()
                guard offset + 4 <= capacity else { throw ReadError.invalidRecord }
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard length >= 24, length <= capacity - offset else {
                    throw ReadError.invalidRecord
                }
                let record = UnsafeRawBufferPointer(start: buffer + offset, count: length)
                let entry = try decode(record, finderInfoRequired: needsFinderInfo)
                offset += length
                guard hidden || !entry.name.hasPrefix(".") else { continue }
                if let hit = entry.regularHit(prefix: prefix, hidden: hidden) {
                    hits.append(hit)
                } else if entry.isOrdinaryFile {
                    // A fully described but hidden regular file needs no fallback.
                    continue
                } else {
                    let url = folder.appendingPathComponent(entry.name)
                    if !hidden {
                        let values = try? url.resourceValues(forKeys: [.isHiddenKey])
                        if values?.isHidden == true { continue }
                    }
                    if let hit = try? Hit.read(url, parent: folder) { hits.append(hit) }
                }
            }
        }
    }

    struct Entry {
        let name: String
        let type: UInt32?
        let modified: Int?
        let flags: UInt32?
        let finderHidden: Bool?
        let size: UInt64?
        let error: UInt32

        var isOrdinaryFile: Bool {
            error == 0 && type == 1 && modified != nil && size != nil && finderHidden != nil
                && flags.map { $0 & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 } == true
        }
        func regularHit(prefix: String, hidden: Bool) -> Hit? {
            guard isOrdinaryFile, let flags, let modified, let size,
                hidden || (flags & UInt32(UF_HIDDEN) == 0 && finderHidden == false)
            else {
                return nil
            }
            return Hit(
                path: prefix + name, kind: "file", size: size,
                mtime: UInt64(max(0, modified)), score: 0)
        }
    }

    /// Returned attributes are packed at four-byte boundaries, not Swift alignment.
    static func decode(_ record: UnsafeRawBufferPointer, finderInfoRequired: Bool = true) throws
        -> Entry
    {
        var cursor = 4
        func read<T>(_ type: T.Type) throws -> T {
            guard cursor <= record.count, MemoryLayout<T>.size <= record.count - cursor else {
                throw ReadError.invalidRecord
            }
            defer { cursor += MemoryLayout<T>.size }
            return record.loadUnaligned(fromByteOffset: cursor, as: T.self)
        }
        let returned = try read(attribute_set_t.self)
        func has(_ flag: Int32) -> Bool { returned.commonattr & UInt32(flag) != 0 }
        let error = try has(ATTR_CMN_ERROR) ? read(UInt32.self) : 0
        guard has(ATTR_CMN_NAME) else { throw ReadError.invalidRecord }
        let referenceStart = cursor
        let reference = try read(attrreference_t.self)
        let start = referenceStart + Int(reference.attr_dataoffset)
        let length = Int(reference.attr_length)
        guard start >= 0, start <= record.count, length > 1, length <= record.count - start,
            record[start + length - 1] == 0
        else { throw ReadError.invalidRecord }
        let nameBytes = record[start..<(start + length - 1)]
        guard !nameBytes.contains(0), !nameBytes.contains(47),
            let name = String(validating: nameBytes, as: UTF8.self), name != ".", name != ".."
        else {
            throw ReadError.invalidRecord
        }
        let type = try has(ATTR_CMN_OBJTYPE) ? read(UInt32.self) : nil
        let modified = try has(ATTR_CMN_MODTIME) ? read(timespec.self).tv_sec : nil
        var finderHidden: Bool? = finderInfoRequired ? nil : false
        if has(ATTR_CMN_FNDRINFO) {
            guard cursor + 32 <= record.count else { throw ReadError.invalidRecord }
            // Finder flags are a big-endian UInt16 at byte 8 of the FinderInfo field.
            finderHidden = record[cursor + 8] & 0x40 != 0
            cursor += 32
        }
        let flags = try has(ATTR_CMN_FLAGS) ? read(UInt32.self) : nil
        let size =
            try returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0
            ? read(UInt64.self) : nil
        return Entry(
            name: name, type: type, modified: modified, flags: flags,
            finderHidden: finderHidden, size: size, error: error)
    }
}

final class DirectoryMetadataTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FinderSearch-dir-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDirectoryMetadataAndSpecialEntriesMatchFoundation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [
            "empty", "populated", ".hidden", "flag-hidden", "finder-hidden", "Fake.app", "é😀",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name),
                withIntermediateDirectories: false)
        }
        for i in 0..<20 {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent("populated/file-\(i)"))
        }
        try Data([4, 5]).write(to: root.appendingPathComponent("regular.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("directory-link"),
            withDestinationURL: root.appendingPathComponent("populated"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("broken-link"),
            withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertEqual(
            chflags(root.appendingPathComponent("flag-hidden").path, UInt32(UF_HIDDEN)), 0)
        var info = [UInt8](repeating: 0, count: 32); info[8] = 0x40
        XCTAssertEqual(
            info.withUnsafeBytes {
                setxattr(
                    root.appendingPathComponent("finder-hidden").path, "com.apple.FinderInfo",
                    $0.baseAddress, $0.count, 0, 0)
            }, 0)
        for hidden in [false, true] {
            let expected = try LocalFiles.foundationList(root, hidden: hidden)
            let candidate = try XCTUnwrap(BulkDirectory.list(root, hidden: hidden))
            XCTAssertTrue(Set(candidate) == Set(expected), "Metadata differs from Foundation")
            XCTAssertEqual(candidate.count, expected.count)
        }
    }

    func testSpecialDirectoryEntriesRequireFallback() {
        func entry(
            type: UInt32? = 2, flags: UInt32? = 0, mount: UInt32? = 0,
            modified: Int? = 123, hidden: Bool? = false, error: UInt32 = 0
        ) -> BulkDirectory.Entry {
            BulkDirectory.Entry(
                name: "directory", type: type, modified: modified,
                flags: flags, finderHidden: hidden, size: 0, error: error, mountStatus: mount)
        }
        XCTAssertEqual(
            entry().metadataHit(prefix: "/fixture/", hidden: false),
            Hit(path: "/fixture/directory", kind: "dir", size: 0, mtime: 123, score: 0))
        for special in [
            entry(mount: UInt32(DIR_MNTSTATUS_MNTPOINT)),
            entry(mount: UInt32(DIR_MNTSTATUS_TRIGGER)), entry(mount: nil),
            entry(flags: UInt32(SF_DATALESS)), entry(flags: UInt32(SF_FIRMLINK)),
            entry(flags: nil), entry(modified: nil), entry(hidden: nil),
            entry(type: 5), entry(type: nil), entry(error: 5),
        ] {
            XCTAssertFalse(special.isOrdinaryEntry)
            XCTAssertNil(special.metadataHit(prefix: "/fixture/", hidden: true))
        }
        for hidden in [entry(flags: UInt32(UF_HIDDEN)), entry(hidden: true)] {
            XCTAssertTrue(hidden.isOrdinaryEntry)
            XCTAssertNil(hidden.metadataHit(prefix: "/fixture/", hidden: false))
            XCTAssertNotNil(hidden.metadataHit(prefix: "/fixture/", hidden: true))
        }
    }

    func testPackedDirectoryAttributesAndTruncation() throws {
        func append<T>(_ value: T, to data: inout Data) {
            var value = value
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        var record = Data()
        append(UInt32(64), to: &record)
        var attrs = attribute_set_t()
        attrs.commonattr =
            UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FLAGS)
        attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        append(attrs, to: &record)
        var name = attrreference_t()
        name.attr_dataoffset = 36; name.attr_length = 4
        append(name, to: &record)
        append(UInt32(2), to: &record)
        append(timespec(tv_sec: 123, tv_nsec: 0), to: &record)
        append(UInt32(0), to: &record)
        append(UInt32(0), to: &record)
        record.append(contentsOf: [100, 105, 114, 0])
        let decoded = try record.withUnsafeBytes {
            try BulkDirectory.decode($0, finderInfoRequired: false)
        }
        XCTAssertEqual(decoded.mountStatus, 0)
        XCTAssertEqual(
            decoded.metadataHit(prefix: "/fixture/", hidden: false),
            Hit(path: "/fixture/dir", kind: "dir", size: 0, mtime: 123, score: 0))
        for length in 0..<record.count {
            XCTAssertThrowsError(
                try record.prefix(length).withUnsafeBytes {
                    try BulkDirectory.decode($0, finderInfoRequired: false)
                })
        }
        record[56] = UInt8(DIR_MNTSTATUS_MNTPOINT)
        let mounted = try record.withUnsafeBytes {
            try BulkDirectory.decode($0, finderInfoRequired: false)
        }
        XCTAssertFalse(mounted.isOrdinaryEntry)
    }

    func testFolderHeavyListingPerformance() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<10000 {
            let child = root.appendingPathComponent("folder-\(i)")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            if i.isMultiple(of: 100) {
                try Data([1]).write(to: child.appendingPathComponent("child.txt"))
            }
        }
        var samples = [[Double]](repeating: [], count: 2)
        var ready = [[Double]](repeating: [], count: 2)
        func millis(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds)
                / 1e15
        }
        for round in 0..<7 {
            var outputs: [[Hit]] = [[], []]
            for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                try autoreleasepool {
                    let start = ContinuousClock.now
                    let hits =
                        try method == 0
                        ? XCTUnwrap(FileOnlyBulkBaseline.list(root, hidden: false))
                        : XCTUnwrap(BulkDirectory.list(root, hidden: false))
                    let listed = millis(start.duration(to: .now))
                    outputs[method] = try FileOrdering.sorted(
                        hits, sort: .name, ascending: true,
                        showHidden: false, isSearch: false)
                    let ordered = millis(start.duration(to: .now))
                    if round > 0 {
                        samples[method].append(listed)
                        ready[method].append(ordered)
                    }
                }
            }
            XCTAssertTrue(outputs[0] == outputs[1], "Ordered directory metadata differs")
            XCTAssertEqual(outputs[1].count, 10000)
        }
        let before = samples[0].sorted()[3], after = samples[1].sorted()[3]
        let beforeReady = ready[0].sorted()[3], afterReady = ready[1].sorted()[3]
        print(
            "DIRECTORY PRODUCTION 10,000 subfolders metadata: \(before) -> \(after) ms (\(before / after)x)"
        )
        print(
            "DIRECTORY PRODUCTION metadata + name sort: \(beforeReady) -> \(afterReady) ms (\(beforeReady / afterReady)x)"
        )
    }
}
