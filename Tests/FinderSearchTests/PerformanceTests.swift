import XCTest
import AppKit
import SwiftUI
@testable import FinderSearch

final class PerformanceTests: XCTestCase {
    @MainActor func testBackgroundMenuRespectsFolderAndBusyStateWithoutReplacingFileMenu() throws {
        let model = SearchModel()
        model.hits = [Hit(path: "/fixture/example.txt", kind: "file", size: 1, mtime: 0, score: 0)]
        let list = FileList(model: model, focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator()
        let scroll = list.makeView(coordinator: coordinator)
        XCTAssertNotNil(scroll.documentView)
        coordinator.update()
        let background = coordinator.menu(for: -1)
        XCTAssertTrue(try XCTUnwrap(background.item(withTitle: "New Folder")).isEnabled)
        XCTAssertTrue(try XCTUnwrap(background.item(withTitle: "New Text File")).isEnabled)
        XCTAssertNotNil(background.item(withTitle: "Paste Items"))
        XCTAssertNotNil(background.item(withTitle: "View")?.submenu)
        let file = coordinator.menu(for: 0)
        XCTAssertNotNil(file.item(withTitle: "Rename…"))
        XCTAssertNil(file.item(withTitle: "New Folder"))
        model.busy = true
        XCTAssertFalse(try XCTUnwrap(coordinator.menu(for: -1).item(withTitle: "New Folder")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(coordinator.menu(for: -1).item(withTitle: "New Text File")).isEnabled)
        model.busy = false; model.query = "search"
        XCTAssertFalse(try XCTUnwrap(coordinator.menu(for: -1).item(withTitle: "Paste Items")).isEnabled)
    }
    @MainActor func testToolbarViewPickerKeepsGeometryAndImagesAcrossUpdates() {
        var mode: FileViewMode = .icons
        let picker = ViewModePicker(selection: Binding(get: { mode }, set: { mode = $0 }))
        let coordinator = picker.makeCoordinator()
        let control = picker.makeControl(coordinator: coordinator)
        let originalSize = control.intrinsicContentSize
        let originalFrame = control.frame
        let images = FileViewMode.allCases.indices.map { control.image(forSegment: $0) }
        for (index, value) in FileViewMode.allCases.enumerated() {
            mode = value
            for _ in 0..<20 { coordinator.update(control) }
            XCTAssertEqual(control.selectedSegment, index)
            XCTAssertEqual(control.intrinsicContentSize, originalSize)
            XCTAssertEqual(control.frame, originalFrame)
            for segment in FileViewMode.allCases.indices {
                XCTAssertTrue(control.image(forSegment: segment) === images[segment], "Navigation updates must reuse symbol images")
            }
        }
        control.selectedSegment = 0
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
        XCTAssertEqual(mode, .icons, "Native segment clicks update the bound view mode")
    }
    @MainActor func testLargeFolderPreparationKeepsMainActorAvailable() async throws {
        let hits = (0..<30000).map {
            Hit(path: "/fixture/file-\(($0 * 7919) % 30000).txt", kind: "file",
                size: 1, mtime: 0, score: 0)
        }
        var completed = false
        let start = Date()
        let preparation = Task {
            defer { completed = true }
            return try await FileOrdering.prepare(
                hits, sort: .name, ascending: true, showHidden: false, isSearch: false)
        }
        var heartbeats = 0
        while !completed {
            heartbeats += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        let ordered = try await preparation.value
        XCTAssertGreaterThan(heartbeats, 1, "Folder sorting must allow UI work to run")
        XCTAssertEqual(ordered.count, 30000)
        XCTAssertEqual(ordered.first?.name, "file-0.txt")
        XCTAssertEqual(ordered.last?.name, "file-29999.txt")
        print("PERFORMANCE folder sort: 30,000 files = \(Date().timeIntervalSince(start) * 1000) ms; \(heartbeats) UI heartbeats")
    }

    @MainActor func testColdFolderLoadUsesCurrentSortAndIgnoresAbandonedNavigation() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FinderSearch-cold-" + UUID().uuidString)
        let large = root.appendingPathComponent("Large"), small = root.appendingPathComponent("Small")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2000 {
            try Data(repeating: 0, count: index % 10).write(
                to: large.appendingPathComponent("file-\(index).txt"))
        }
        try Data().write(to: large.appendingPathComponent(".hidden"))
        try Data().write(to: small.appendingPathComponent("only.txt"))
        let model = SearchModel()
        let start = Date()
        model.navigate(large)
        model.sort = .size; model.ascending = false
        for _ in 0..<500 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.sortedHits.count, 2000)
        XCTAssertEqual(model.sortedHits.first?.size, 9)
        XCTAssertEqual(model.sortedHits.last?.size, 0)
        print("PERFORMANCE cold folder: 2,000 files = \(Date().timeIntervalSince(start) * 1000) ms")
        model.navigate(small)
        model.navigate(large)
        model.navigate(small)
        for _ in 0..<500 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sortedHits.map(\.name), ["only.txt"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.sortedHits.map(\.name), ["only.txt"])
    }

    func testPreparedOrderingPreservesRelevanceAndNaturalNames() async throws {
        let hits = [
            Hit(path: "/fixture/file-10.txt", kind: "file", size: 2, mtime: 1, score: 20),
            Hit(path: "/fixture/.hidden.txt", kind: "file", size: 3, mtime: 3, score: 30),
            Hit(path: "/fixture/file-2.txt", kind: "file", size: 1, mtime: 2, score: 10),
        ]
        let natural = try await FileOrdering.prepare(
            hits, sort: .name, ascending: true, showHidden: false, isSearch: false)
        XCTAssertEqual(natural.map(\.name), ["file-2.txt", "file-10.txt"])
        let relevance = try await FileOrdering.prepare(
            hits, sort: .relevance, ascending: false, showHidden: false, isSearch: true)
        XCTAssertEqual(relevance.map(\.name), ["file-10.txt", "file-2.txt"])
        let modified = try await FileOrdering.prepare(
            hits, sort: .modified, ascending: false, showHidden: true, isSearch: false)
        XCTAssertEqual(modified.map(\.mtime), [3, 2, 1])
    }

    @MainActor func testLargeFolderSelectionBudget() async throws {
        let model = SearchModel()
        model.hits = (0..<10000).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: 1, mtime: 0, score: 0)
        }
        for _ in 0..<200 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.sorting)
        model.selection = ["/fixture/file-5000.txt"]
        let start = Date()
        for _ in 0..<100 { XCTAssertEqual(model.selected?.path, "/fixture/file-5000.txt") }
        let milliseconds = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(
            milliseconds, 100, "Selection reads must stay within the responsiveness budget")
        print("PERFORMANCE selection: 100 reads / 10,000 files = \(milliseconds) ms")
    }
    @MainActor func testModelResortingKeepsRowsAndRejectsStaleResults() async throws {
        let model = SearchModel()
        model.hits = (0..<30000).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: UInt64($0),
                mtime: UInt64($0 % 7), score: 0)
        }
        model.sort = .size; model.ascending = false
        XCTAssertEqual(model.sortedHits.count, 30000, "Rows remain visible during sorting")
        var heartbeats = 0
        for _ in 0..<1000 {
            if !model.sorting { break }
            heartbeats += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(model.sorting)
        XCTAssertGreaterThan(heartbeats, 1, "Model sorting must let UI work run")
        XCTAssertEqual(model.sortedHits.first?.size, 29999)
        model.sort = .name
        model.ascending = true
        model.hits = [Hit(path: "/fixture/replacement.txt", kind: "file", size: 1, mtime: 0, score: 0)]
        for _ in 0..<200 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.sorting)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.sortedHits.map(\.name), ["replacement.txt"], "An abandoned sort cannot replace new rows")
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
