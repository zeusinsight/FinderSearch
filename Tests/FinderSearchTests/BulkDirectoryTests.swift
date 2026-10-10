import Darwin
import XCTest
@testable import FinderSearch

final class BulkDirectoryTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FinderSearch-bulk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testMixedEntriesMatchFoundationIncludingHiddenFlagsAndLinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["regular.txt", "é 😀.txt", ".hidden", "flag-hidden", "finder-hidden"] {
            try Data("contents".utf8).write(to: root.appendingPathComponent(name))
        }
        for name in ["folder", "Fake.app"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        for (name, target) in [
            ("file-link", "regular.txt"), ("dir-link", "folder"), ("broken-link", "missing"),
        ] {
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(name),
                withDestinationURL: root.appendingPathComponent(target))
        }
        try FileManager.default.linkItem(
            at: root.appendingPathComponent("regular.txt"),
            to: root.appendingPathComponent("hard-link"))
        XCTAssertEqual(
            chflags(root.appendingPathComponent("flag-hidden").path, UInt32(UF_HIDDEN)), 0)
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x40
        XCTAssertEqual(
            finderInfo.withUnsafeBytes {
                setxattr(
                    root.appendingPathComponent("finder-hidden").path, "com.apple.FinderInfo",
                    $0.baseAddress, $0.count, 0, 0)
            }, 0)
        for hidden in [false, true] {
            let expected = try LocalFiles.foundationList(root, hidden: hidden)
            let actual = try XCTUnwrap(BulkDirectory.list(root, hidden: hidden))
            XCTAssertEqual(Set(actual), Set(expected))
            XCTAssertEqual(actual.count, expected.count)
        }
        let alias = root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertEqual(
            Set(try LocalFiles.list(alias, hidden: true)),
            Set(try LocalFiles.foundationList(alias, hidden: true)))
        XCTAssertTrue(
            try LocalFiles.list(alias, hidden: true).allSatisfy {
                $0.path.hasPrefix(alias.path + "/")
            })
    }

    func testProviderAndFilesystemFallbackAndEmptyDirectory() throws {
        XCTAssertFalse(
            BulkDirectory.supports(path: "/Volumes/Server", fileSystem: "smbfs", local: false))
        XCTAssertFalse(
            BulkDirectory.supports(path: "/Volumes/USB", fileSystem: "exfat", local: true))
        XCTAssertTrue(
            BulkDirectory.supports(path: "/Volumes/Local", fileSystem: "apfs", local: true))
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try XCTUnwrap(BulkDirectory.list(root, hidden: false)), [])
        let provider = root.appendingPathComponent("Library/CloudStorage/Provider")
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: provider.appendingPathComponent("file"))
        XCTAssertNil(try BulkDirectory.list(provider, hidden: false))
        XCTAssertEqual(
            try LocalFiles.list(provider, hidden: false),
            try LocalFiles.foundationList(provider, hidden: false))
        XCTAssertThrowsError(
            try LocalFiles.list(root.appendingPathComponent("missing"), hidden: false))
    }

    func testCancellationDoesNotFallBackToFoundation() async throws {
        let task = Task { () throws -> [Hit] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try LocalFiles.list(URL(fileURLWithPath: "/missing"), hidden: false)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testLargeLogicalSizeAndOldModificationDateMatchFoundation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sparse")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let size: UInt64 = 5 * 1024 * 1024 * 1024
        try handle.truncate(atOffset: size)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: -10)],
            ofItemAtPath: file.path)
        let bulk = try XCTUnwrap(BulkDirectory.list(root, hidden: true))
        XCTAssertEqual(bulk, try LocalFiles.foundationList(root, hidden: true))
        XCTAssertEqual(bulk.first?.size, size)
        XCTAssertEqual(bulk.first?.mtime, 0)
    }

    func testParserRejectsTruncatedAndInvalidNameRecords() throws {
        func append<T>(_ value: T, to data: inout Data) {
            var value = value
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        var record = Data()
        append(UInt32(0), to: &record)
        var returned = attribute_set_t()
        returned.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME)
        append(returned, to: &record)
        var reference = attrreference_t()
        reference.attr_dataoffset = 8
        reference.attr_length = 5
        append(reference, to: &record)
        record.append(contentsOf: [102, 105, 108, 101, 0])
        let decoded = try record.withUnsafeBytes { try BulkDirectory.decode($0) }
        XCTAssertEqual(decoded.name, "file")
        XCTAssertFalse(decoded.isOrdinaryEntry, "Missing attributes must use Foundation")
        for invalid: [UInt8] in [
            [46, 46, 47, 120], [97, 47, 98, 99], [97, 0, 98, 99], [255, 98, 99, 100],
        ] {
            var invalidRecord = record.prefix(32)
            invalidRecord.append(contentsOf: invalid + [0])
            XCTAssertThrowsError(try invalidRecord.withUnsafeBytes { try BulkDirectory.decode($0) })
        }
        for length in 0..<record.count {
            XCTAssertThrowsError(
                try record.prefix(length).withUnsafeBytes { try BulkDirectory.decode($0) })
        }
        record[record.count - 1] = 1
        XCTAssertThrowsError(try record.withUnsafeBytes { try BulkDirectory.decode($0) })
        record[record.count - 1] = 0
        record[24] = 0xff; record[25] = 0xff; record[26] = 0xff; record[27] = 0x7f
        XCTAssertThrowsError(try record.withUnsafeBytes { try BulkDirectory.decode($0) })
    }

    func testBulkFolderMetadataPerformance() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FinderSearch-bulk-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<10000 {
            try Data(repeating: UInt8(i % 256), count: i % 257).write(
                to: root.appendingPathComponent("file-\(i)-é.txt"))
        }
        try Data().write(to: root.appendingPathComponent(".hidden"))
        let expected = try LocalFiles.foundationList(root, hidden: false)
        XCTAssertEqual(expected.count, 10000)
        var listing = [[Double]](repeating: [], count: 2)
        var ready = [[Double]](repeating: [], count: 2)
        func millis(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds)
                / 1e15
        }
        for round in 0..<7 {
            for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                try autoreleasepool {
                    let start = ContinuousClock.now
                    let hits =
                        try method == 0
                        ? LocalFiles.foundationList(root, hidden: false)
                        : LocalFiles.list(root, hidden: false)
                    let listed = millis(start.duration(to: .now))
                    let ordered = try FileOrdering.sorted(
                        hits, sort: .name, ascending: true,
                        showHidden: false, isSearch: false)
                    let total = millis(start.duration(to: .now))
                    XCTAssertEqual(
                        Set(hits), Set(expected), "Both readers must return identical metadata")
                    XCTAssertEqual(ordered.count, 10000)
                    if round > 0 { listing[method].append(listed); ready[method].append(total) }
                }
            }
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print(
            "FOLDER PERFORMANCE 10,000 regular files: listing \(median(listing[0])) → \(median(listing[1])) ms (\(median(listing[0]) / median(listing[1]))x)"
        )
        print(
            "FOLDER PERFORMANCE listing + existing name sort: \(median(ready[0])) → \(median(ready[1])) ms (\(median(ready[0]) / median(ready[1]))x)"
        )
        print("FOLDER PERFORMANCE samples listing \(listing); ready \(ready)")
    }
}
