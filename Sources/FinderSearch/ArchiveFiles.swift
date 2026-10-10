import Foundation

/// Validate ZIP entry paths before handing extraction to ditto. Extraction is
/// staged in an owned directory and published only after the tool succeeds.
enum ArchiveFiles {
    static func validateZIP(_ source: URL, control: FileOperationControl? = nil) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: size - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        func number(_ data: Data, _ offset: Int, _ bytes: Int) -> UInt64 {
            guard offset >= 0, offset + bytes <= data.count else { return UInt64.max }
            return (0..<bytes).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        guard tail.count >= 22,
            let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
                number(tail, $0, 4) == 0x06054b50
                    && $0 + 22 + Int(number(tail, $0 + 20, 2)) == tail.count
            })
        else { throw Engine.Failure.message("This ZIP archive is incomplete.") }
        let count = number(tail, end + 10, 2)
        let length = number(tail, end + 12, 4), offset = number(tail, end + 16, 4)
        guard number(tail, end + 4, 2) == 0, number(tail, end + 6, 2) == 0,
            number(tail, end + 8, 2) == count, count != 0xffff,
            length <= 32 * 1024 * 1024, offset + length <= size - tailSize + UInt64(end)
        else {
            throw Engine.Failure.message(
                "This archive format is not supported. Use a standard ZIP archive.")
        }
        try handle.seek(toOffset: offset)
        let central = try handle.read(upToCount: Int(length)) ?? Data()
        var cursor = 0
        for _ in 0..<count {
            try Task.checkCancellation(); try control?.checkCancellation()
            guard cursor + 46 <= central.count, number(central, cursor, 4) == 0x02014b50 else {
                throw Engine.Failure.message("This ZIP archive is incomplete.")
            }
            let flags = number(central, cursor + 8, 2)
            let nameLength = Int(number(central, cursor + 28, 2))
            let extraLength = Int(number(central, cursor + 30, 2)),
                commentLength = Int(number(central, cursor + 32, 2))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= central.count, flags & 1 == 0 else {
                throw Engine.Failure.message(
                    "Encrypted or incomplete ZIP archives cannot be extracted.")
            }
            let nameData = central.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard
                let name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1),
                !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                !name.split(separator: "/").contains("..")
            else {
                throw Engine.Failure.message("The archive contains an unsafe file path.")
            }
            let mode = number(central, cursor + 38, 4) >> 16 & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else {
                throw Engine.Failure.message(
                    "Archives containing symbolic links or special files cannot be extracted.")
            }
            let localOffset = number(central, cursor + 42, 4)
            let compressedSize = number(central, cursor + 20, 4)
            guard localOffset < offset, compressedSize != 0xffff_ffff else {
                throw Engine.Failure.message("This archive format is not supported.")
            }
            try handle.seek(toOffset: localOffset)
            let local = try handle.read(upToCount: 30) ?? Data()
            guard local.count == 30, number(local, 0, 4) == 0x04034b50,
                number(local, 6, 2) == flags, number(local, 26, 2) == UInt64(nameLength)
            else {
                throw Engine.Failure.message("The archive contains inconsistent file headers.")
            }
            let localName = try handle.read(upToCount: nameLength) ?? Data()
            guard localName == nameData,
                localOffset + 30 + UInt64(nameLength) + number(local, 28, 2) + compressedSize
                    <= offset
            else {
                throw Engine.Failure.message(
                    "The archive contains inconsistent file paths or data.")
            }
            cursor = next
        }
        guard cursor == central.count else {
            throw Engine.Failure.message("This ZIP archive is incomplete.")
        }
    }

    static func compress(_ sources: [URL], to destination: URL, control: FileOperationControl)
        throws
    {
        guard !sources.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().path
        for source in sources {
            let path = source.resolvingSymlinksInPath().path
            let prefix = path == "/" ? "/" : path + "/"
            if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                parent == path || parent.hasPrefix(prefix)
            {
                throw Engine.Failure.message(
                    "An archive cannot be created inside a folder it contains.")
            }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".FinderSearch-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = staging.appendingPathComponent("output.zip")
        if sources.count == 1 {
            _ = try control.run(
                "/usr/bin/ditto",
                arguments: ["-c", "-k", "--keepParent", sources[0].path, output.path])
        } else {
            let contents = staging.appendingPathComponent("contents")
            try FileManager.default.createDirectory(
                at: contents, withIntermediateDirectories: false)
            for source in sources {
                let target = LocalFiles.availableName(in: contents, name: source.lastPathComponent)
                try NativeFileCopy.copy(source, to: target, control: control)
            }
            _ = try control.run(
                "/usr/bin/ditto", arguments: ["-c", "-k", contents.path, output.path])
        }
        try control.checkCancellation()
        try FileManager.default.moveItem(at: output, to: destination)
    }

    static func extract(_ source: URL, to destination: URL, control: FileOperationControl) throws {
        try control.checkCancellation(); try validateZIP(source, control: control)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            ".FinderSearch-extract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try control.run("/usr/bin/ditto", arguments: ["-x", "-k", source.path, staging.path])
        try control.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
    }
}

extension SearchModel {
    func compress() {
        let urls = selectedItems.map(\.url)
        guard let first = urls.first, canWriteHere else { return }
        let parent = first.deletingLastPathComponent()
        let folder =
            urls.allSatisfy { $0.deletingLastPathComponent().path == parent.path }
            ? parent : location
        prepareOperations(name: "Compress") {
            let name =
                urls.count == 1
                ? urls[0].deletingPathExtension().lastPathComponent + ".zip" : "Archive.zip"
            return [.compress(urls, LocalFiles.availableName(in: folder, name: name))]
        }
    }
    func extract() {
        let urls = selectedItems.filter { $0.url.pathExtension.lowercased() == "zip" }.map(\.url)
        guard !urls.isEmpty else { return }
        prepareOperations(name: "Extract") {
            var reserved = Set<String>()
            return urls.map { source in
                let destination = LocalFiles.availableName(
                    in: source.deletingLastPathComponent(),
                    name: source.deletingPathExtension().lastPathComponent, reserved: reserved)
                reserved.insert(destination.path)
                return .extract(source, destination)
            }
        }
    }
}
