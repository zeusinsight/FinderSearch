import AppKit
import CoreServices
import XCTest
@testable import FinderSearch

final class ListColumnsTests: XCTestCase {
    @MainActor func testMenusTogglePersistAndSyncWithoutChangingSelection() throws {
        let suite = "ListColumnsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SearchModel()
        model.hits = [Hit(path: "/fixture/example.txt", kind: "file", size: 1, mtime: 0, score: 0)]
        let list = FileList(model: model, focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator()
        let scroll = list.makeView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? BrowserTable)
        table.configureColumns(defaults: defaults)
        coordinator.update()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let otherCoordinator = list.makeCoordinator()
        let otherScroll = list.makeView(coordinator: otherCoordinator)
        let otherTable = try XCTUnwrap(otherScroll.documentView as? BrowserTable)
        otherTable.configureColumns(defaults: defaults)
        let headerMenu = try XCTUnwrap(table.headerView?.menu)
        let sizeItem = try XCTUnwrap(headerMenu.items.first { $0.representedObject as? String == "size" })
        let nameItem = try XCTUnwrap(headerMenu.items.first { $0.representedObject as? String == "name" })
        XCTAssertFalse(nameItem.isEnabled)
        XCTAssertEqual(nameItem.state, .on)
        XCTAssertNil(defaults.object(forKey: BrowserTable.columnVisibilityKey))
        for row in [-1, 0] {
            XCTAssertNotNil(coordinator.menu(for: row).items.first { $0.submenu?.items.count == 8 })
        }

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sizeItem.action), to: sizeItem.target, from: sizeItem))
        let identifier = NSUserInterfaceItemIdentifier("size")
        XCTAssertTrue(try XCTUnwrap(table.tableColumn(withIdentifier: identifier)).isHidden)
        XCTAssertTrue(try XCTUnwrap(otherTable.tableColumn(withIdentifier: identifier)).isHidden)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 0))
        table.menuNeedsUpdate(headerMenu)
        XCTAssertEqual(sizeItem.state, .off)
        coordinator.update()
        XCTAssertTrue(try XCTUnwrap(table.tableColumn(withIdentifier: identifier)).isHidden)

        let restoredCoordinator = list.makeCoordinator()
        let restoredScroll = list.makeView(coordinator: restoredCoordinator)
        let restoredTable = try XCTUnwrap(restoredScroll.documentView as? BrowserTable)
        restoredTable.configureColumns(defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(restoredTable.tableColumn(withIdentifier: identifier)).isHidden)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sizeItem.action), to: sizeItem.target, from: sizeItem))
        XCTAssertFalse(try XCTUnwrap(restoredTable.tableColumn(withIdentifier: identifier)).isHidden)
    }

    @MainActor func testAdditionalDatesAreOptionalAndPersistWhenEnabled() throws {
        let suite = "ListColumnsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = FileList(model: SearchModel(), focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator()
        let scroll = list.makeView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? BrowserTable)
        table.configureColumns(defaults: defaults)
        for key in ["created", "opened", "added"] {
            let column = try XCTUnwrap(table.tableColumn(withIdentifier: .init(key)))
            XCTAssertTrue(column.isHidden)
            XCTAssertNil(column.sortDescriptorPrototype)
            let item = try XCTUnwrap(table.columnsMenu().items.first { $0.representedObject as? String == key })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertFalse(column.isHidden)
            table.configureColumns(defaults: defaults)
            XCTAssertFalse(column.isHidden)
        }
    }

    func testCreationDateAndMissingSpotlightMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("date-fixture.txt")
        try Data("fixture".utf8).write(to: file)
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: expected], ofItemAtPath: file.path)
        XCTAssertEqual(try XCTUnwrap(FileCell.fileDate(at: file, column: "created")).timeIntervalSince1970,
            expected.timeIntervalSince1970, accuracy: 1)
        let missing = folder.appendingPathComponent("missing")
        for key in ["created", "opened", "added"] {
            XCTAssertNil(FileCell.fileDate(at: missing, column: key))
        }
        let item = try XCTUnwrap(MDItemCreateWithURL(kCFAllocatorDefault, file as CFURL))
        XCTAssertEqual(FileCell.fileDate(at: file, column: "opened"),
            MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date)
        XCTAssertEqual(FileCell.fileDate(at: file, column: "added"),
            MDItemCopyAttribute(item, kMDItemDateAdded) as? Date)
    }

    @MainActor func testVisibleDateCellsLoadAndFitNarrowWindows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Date column example.txt")
        try Data("fixture".utf8).write(to: file)
        let model = SearchModel()
        model.hits = [try Hit.read(file)]
        let list = FileList(model: model, focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator()
        let scroll = list.makeView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? BrowserTable)
        let suite = "ListColumnsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["created": true, "opened": true, "added": true], forKey: BrowserTable.columnVisibilityKey)
        table.configureColumns(defaults: defaults)
        coordinator.update()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 470),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let column = table.column(withIdentifier: .init("created"))
        let cell = try XCTUnwrap(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? FileCell)
        for _ in 0..<40 where cell.textField?.stringValue == "—" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(cell.textField?.stringValue, "—")
        XCTAssertFalse(cell.textField?.stringValue.isEmpty ?? true)
        for width in [1050, 850] {
            window.setContentSize(NSSize(width: width, height: 470))
            scroll.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            XCTAssertTrue(scroll.hasHorizontalScroller)
            if let directory = ProcessInfo.processInfo.environment["FINDERSEARCH_TEST_SCREENSHOTS"] {
                let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("list-dates-\(width).png"))
            }
        }
    }

    @MainActor func testLocationDefaultsFollowSearchUntilExplicitlyChosen() throws {
        let suite = "ListColumnsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = FileList(model: SearchModel(), focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator()
        let scroll = list.makeView(coordinator: coordinator)
        let table = try XCTUnwrap(scroll.documentView as? BrowserTable)
        table.configureColumns(defaults: defaults)
        let location = try XCTUnwrap(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("where")))
        XCTAssertTrue(location.isHidden)
        table.isSearch = true
        XCTAssertFalse(location.isHidden)
        let menu = table.columnsMenu()
        let item = try XCTUnwrap(menu.items.first { $0.representedObject as? String == "where" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        table.isSearch = false; table.isSearch = true
        XCTAssertTrue(location.isHidden)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        table.isSearch = false
        XCTAssertFalse(location.isHidden)
    }
}
