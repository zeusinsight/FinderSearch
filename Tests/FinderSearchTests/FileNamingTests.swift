import XCTest
import AppKit
@testable import FinderSearch

/// File naming and clipboard guards: what a rename accepts, when a case-only
/// rename is legal, and when Copy must leave the clipboard alone.
final class FileNamingTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "FinderSearch-naming-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func write(_ name: String, _ text: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name); try Data(text.utf8).write(to: url);
        return url
    }

    func testFileNameValidation() {
        for bad in ["", "   ", ".", "..", "a/b", "a:b", "a\0b", "a\nb", "a\tb"] {
            XCTAssertNotNil(FileName.problem(bad), "‘\(bad)’ should be rejected")
        }
        for long in [String(repeating: "b", count: 256), String(repeating: "é", count: 128)] {
            XCTAssertNotNil(FileName.problem(long), "names over 255 bytes should be rejected")
        }
        for good in ["report.pdf", "my file (1).txt", "2024-01-01.txt", "a-b_c~!.swift",
                     String(repeating: "b", count: 255)] {
            XCTAssertNil(FileName.problem(good), "‘\(good)’ should be accepted")
        }
    }

    func testCaseOnlyRenameSucceeds() throws {
        let file = try write("CaseFile.txt", "case")
        let result = LocalFiles.apply([
            .move(file, folder.appendingPathComponent("CASEFILE.txt"))
        ])
        XCTAssertTrue(result.errors.isEmpty)
        // On case-insensitive volumes the old spelling still resolves, so check
        // the name as it is stored on disk.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["CASEFILE.txt"])
        XCTAssertEqual(
            try String(
                contentsOf: folder.appendingPathComponent("CASEFILE.txt"), encoding: .utf8),
            "case")
    }

    func testRealNameClashStillRefused() throws {
        let file = try write("clash.txt", "keep")
        _ = try write("other.txt", "keep too")
        let result = LocalFiles.apply([
            .move(file, folder.appendingPathComponent("other.txt"))
        ])
        XCTAssertEqual(result.errors.count, 1)
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("other.txt"), encoding: .utf8),
            "keep too")
    }

    @MainActor func testCommitRenameRejectsHostileNames() async throws {
        let file = try write("hostile.txt")
        let model = SearchModel(); model.navigate(folder)
        for _ in 0..<250 {
            if !model.loading, !model.busy, !model.sorting { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for bad in ["", " ", "a\nb", "a:b", ".."] {
            model.beginRename(try Hit.read(file))
            XCTAssertFalse(model.commitRename(bad), "‘\(bad)’ should be rejected")
            XCTAssertNotNil(model.error)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testCopyWithEmptySelectionKeepsClipboard() {
        let model = SearchModel()
        let url = folder.appendingPathComponent("clipboard.txt")
        _ = try? Data("x".utf8).write(to: url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        model.copy()
        let read = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) ?? []
        XCTAssertEqual(read.count, 1)
        XCTAssertFalse(model.busy)
    }

    @MainActor func testCopyWithSelectionFilteredOutKeepsClipboard() throws {
        let model = SearchModel()
        let secret = folder.appendingPathComponent(".secret")
        _ = try? Data("x".utf8).write(to: secret)
        model.hits = [Hit(path: secret.path, kind: "file", size: 1, mtime: 0, score: 0)]
        model.selection = [secret.path]
        model.showHidden = false
        XCTAssertEqual(model.selectedItems.count, 0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("PRECIOUS", forType: .string)
        model.copy()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "PRECIOUS")
    }
}
