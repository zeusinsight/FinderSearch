import XCTest
import AppKit
@testable import FinderSearch

final class PerformanceTests: XCTestCase {
    @MainActor func testLargeFolderSelectionBudget() {
        let model = SearchModel()
        model.hits = (0..<10000).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: 1, mtime: 0, score: 0)
        }
        _ = model.sortedHits
        model.selection = ["/fixture/file-5000.txt"]
        let start = Date()
        for _ in 0..<100 { XCTAssertEqual(model.selected?.path, "/fixture/file-5000.txt") }
        let milliseconds = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(
            milliseconds, 100, "Selection reads must stay within the responsiveness budget")
        print("PERFORMANCE selection: 100 reads / 10,000 files = \(milliseconds) ms")
    }
    @MainActor func testSelectionCacheInvalidatesAndKeyboardRangeShrinks() {
        let model = SearchModel()
        model.hits = (0..<6).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: 1, mtime: 0, score: 0)
        }
        model.moveSelection(by: 1, extending: false)
        XCTAssertEqual(model.focusedPath, "/fixture/file-0.txt")
        model.moveSelection(by: 1, extending: false)
        XCTAssertEqual(model.selected?.path, "/fixture/file-1.txt")
        model.moveSelection(by: 2, extending: true)
        XCTAssertEqual(model.selection.count, 3)
        model.moveSelection(by: -1, extending: true)
        XCTAssertEqual(model.selection.count, 2)
        XCTAssertEqual(model.focusedPath, "/fixture/file-2.txt")
        model.hits = []
        XCTAssertTrue(model.selectedItems.isEmpty)
    }
    @MainActor func testBackRestoresFolderImmediatelyAndRefreshes() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FinderSearch-flow-" + UUID().uuidString)
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = a.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: original)
        let model = SearchModel(); model.navigate(a)
        for _ in 0..<100 {
            if !model.loading { break }; try await Task.sleep(for: .milliseconds(10))
        }
        let displayedOriginal = try XCTUnwrap(model.hits.first?.path)
        model.selection = [displayedOriginal]; model.navigate(b)
        for _ in 0..<100 {
            if !model.loading { break }; try await Task.sleep(for: .milliseconds(10))
        }
        let added = a.appendingPathComponent("added.txt"); try Data().write(to: added)
        model.goBack()
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.hits.map(\.path), [displayedOriginal])
        XCTAssertEqual(model.selection, [displayedOriginal])
        for _ in 0..<100 {
            if model.hits.count == 2 { break }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.hits.count, 2)
    }

    @MainActor func testNativeListRestoresRowsWithoutAutomaticHeightLayout() throws {
        let model = SearchModel()
        model.hits = (0..<782).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: 1, mtime: 0, score: 0)
        }
        let list = FileList(model: model, focusFiles: {}, newTab: { _ in })
        let coordinator = FileList.Coordinator(list)
        let scroll = list.makeView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? BrowserTable)
        coordinator.update()
        XCTAssertEqual(table.numberOfRows, 782)
        XCTAssertFalse(table.usesAutomaticRowHeights)
        XCTAssertEqual(table.rowHeight, 24)
        model.query = "search"
        model.hits = Array(model.hits.prefix(500))
        coordinator.update()
        XCTAssertEqual(table.numberOfRows, 500)
        model.query = ""
        let start = Date()
        coordinator.update()
        let milliseconds = Date().timeIntervalSince(start) * 1000
        XCTAssertEqual(table.numberOfRows, 782)
        XCTAssertTrue(
            try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("where")))
                .isHidden)
        XCTAssertLessThan(milliseconds, 200)
        print("PERFORMANCE native list restore: 500 → 782 rows = \(milliseconds) ms")
    }

}
