import Darwin
import Foundation

/// Bulk metadata for ordinary local files and APFS directories. Foundation handles
/// providers, mount points, and entries whose URL semantics need special handling.
enum BulkDirectory {
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
        // Directory size semantics have been verified on APFS. Other supported
        // filesystems retain Foundation's directory metadata handling.
        if fileSystem == "apfs" { attrs.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS) }
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
                if let hit = entry.metadataHit(prefix: prefix, hidden: hidden) {
                    hits.append(hit)
                } else if entry.isOrdinaryEntry {
                    // A fully described but hidden entry needs no fallback.
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
        let mountStatus: UInt32?

        var isOrdinaryEntry: Bool {
            error == 0 && (type == 1 || (type == 2 && mountStatus == 0))
                && modified != nil && size != nil && finderHidden != nil
                && flags.map { $0 & UInt32(SF_DATALESS | SF_FIRMLINK) == 0 } == true
        }
        func metadataHit(prefix: String, hidden: Bool) -> Hit? {
            guard isOrdinaryEntry, let flags, let modified, let size,
                hidden || (flags & UInt32(UF_HIDDEN) == 0 && finderHidden == false)
            else {
                return nil
            }
            return Hit(
                path: prefix + name, kind: type == 2 ? "dir" : "file", size: size,
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
        let mountStatus =
            try returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0
            ? read(UInt32.self) : nil
        let fileSize =
            try returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0
            ? read(UInt64.self) : nil
        // Foundation-backed Hit.read records zero for APFS directories.
        let size: UInt64? = type == 2 ? 0 : fileSize
        return Entry(
            name: name, type: type, modified: modified, flags: flags,
            finderHidden: finderHidden, size: size, error: error, mountStatus: mountStatus)
    }
}
