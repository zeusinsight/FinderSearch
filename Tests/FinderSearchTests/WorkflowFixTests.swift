import AppKit
import XCTest
@testable import FinderSearch

final class WorkflowFixTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FinderSearch-workflow-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    @MainActor func testModalFieldSelectAllAndShortcutRouting() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 50),
            styleMask: [.titled], backing: .buffered, defer: false)
        let field = EditingTextField(string: "/fixture/folder")
        field.frame = NSRect(x: 10, y: 10, width: 420, height: 24)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectedRange = NSRange(location: 0, length: 0)
        func key(_ text: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero,
                    modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: text, charactersIgnoringModifiers: text,
                    isARepeat: false, keyCode: 0))
        }
        XCTAssertTrue(field.performKeyEquivalent(with: try key("a")))
        XCTAssertEqual(
            editor.selectedRange, NSRange(location: 0, length: editor.string.utf16.count))
        for (text, expected) in [
            ("x", EditingShortcut.cut), ("c", .copy), ("v", .paste), ("z", .undo),
        ] {
            XCTAssertEqual(EditingShortcut(try key(text)), expected)
        }
        XCTAssertEqual(EditingShortcut(try key("Z", [.command, .shift])), .redo)
        XCTAssertNil(EditingShortcut(try key("a", [.command, .option])))
        XCTAssertNil(EditingShortcut(try key("v", [])))
    }

    @MainActor func testFavoriteDropsValidateFoldersAndPersistWithoutMovingThem() async throws {
        let a = folder.appendingPathComponent("A"), b = folder.appendingPathComponent("B")
        let package = folder.appendingPathComponent("Test.app"),
            file = folder.appendingPathComponent("file.txt")
        for url in [a, b, package] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try Data("original".utf8).write(to: file)
        let suite = "FinderSearch.drop.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: defaults)
        let other = BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: defaults)
        let added = await workspace.addFavoriteFolders([
            a, file, a, URL(string: "https://example.com/")!, package,
            folder.appendingPathComponent("missing"), b,
        ])
        XCTAssertTrue(added)
        XCTAssertEqual(workspace.favorites.suffix(2), [a.path, b.path])
        XCTAssertEqual(other.favorites, workspace.favorites)
        XCTAssertEqual(defaults.stringArray(forKey: FavoriteFolders.key), workspace.favorites)
        let invalid = await workspace.addFavoriteFolders([file, package])
        XCTAssertFalse(invalid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    @MainActor func testDropProvidersDeliverFileURLsAndIgnoreText() async throws {
        let expectation = expectation(description: "Folder URLs loaded")
        let provider = NSItemProvider(object: folder as NSURL)
        XCTAssertTrue(
            FavoriteFolderDrop.perform([provider]) { urls in
                XCTAssertEqual(urls, [self.folder!]); expectation.fulfill(); return true
            })
        XCTAssertFalse(
            FavoriteFolderDrop.perform([NSItemProvider(object: "text" as NSString)]) { _ in
                XCTFail("Text is not a file URL"); return false
            })
        await fulfillment(of: [expectation], timeout: 2)
    }

    @MainActor func testFileDropLoadsPDFURLsAndRejectsText() async throws {
        let file = folder.appendingPathComponent("correspondence with spaces.pdf")
        try Data("fixture".utf8).write(to: file)
        let loaded = expectation(description: "File URLs loaded")
        XCTAssertTrue(
            FileDrops.load([NSItemProvider(object: file as NSURL)]) { urls in
                XCTAssertEqual(urls, [file])
                loaded.fulfill()
            })
        XCTAssertFalse(
            FileDrops.load([NSItemProvider(object: "text" as NSString)]) { _ in
                XCTFail("Text is not a file drop")
            })
        await fulfillment(of: [loaded], timeout: 2)
    }

    func testListDropsResolveWindowBackgroundAndFolders() {
        let file = Hit(path: "/fixture/file.pdf", kind: "file", size: 1, mtime: 1, score: 0)
        let child = Hit(path: "/fixture/biz", kind: "dir", size: 0, mtime: 1, score: 0)
        let location = URL(fileURLWithPath: "/fixture")
        for items in [[], [file, child]] {
            XCTAssertEqual(
                FileListDrop.destination(
                    row: -1, operation: .on, items: items, location: location), location)
            XCTAssertEqual(
                FileListDrop.destination(
                    row: items.count, operation: .above, items: items, location: location), location
            )
            XCTAssertNil(
                FileListDrop.destination(
                    row: -1, operation: .on, items: items, location: nil))
        }
        XCTAssertEqual(
            FileListDrop.destination(
                row: 1, operation: .on, items: [file, child], location: nil), child.url)
        XCTAssertNil(
            FileListDrop.destination(
                row: 0, operation: .on, items: [file, child], location: location))
        XCTAssertEqual(
            FileListDrop.destination(
                row: 1, operation: .above, items: [file, child], location: location), location)
    }

    @MainActor func testTagViewsRefreshAfterTaggingUndoAndReuse() async throws {
        let url = folder.appendingPathComponent("tagged.txt"),
            other = folder.appendingPathComponent("other.txt")
        try Data().write(to: url); try Data().write(to: other)
        let first = FileTagView(), second = FileTagView()
        XCTAssertNil(first.hitTest(.zero))
        first.configure(url); second.configure(url)
        let initial = await FileTagCache.shared.load(url)
        XCTAssertTrue(initial.isEmpty)
        let model = SearchModel(folderLoader: { url, _ in
            try await LocalFiles.load(url, hidden: false)
        })
        model.location = folder; model.route = folder.path
        model.hits = [try Hit.read(url)]; model.selection = [url.path]
        model.tag("Red")
        for _ in 0..<300 {
            if !model.busy && !model.undoStack.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.busy)
        for _ in 0..<100 {
            if first.tags.contains(where: { $0.name == "Red" }) && first.tags == second.tags {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(first.tags.map(\.name), ["Red"])
        XCTAssertEqual(first.tags.first?.color, 6)
        XCTAssertEqual(second.tags, first.tags)
        XCTAssertGreaterThan(first.intrinsicContentSize.width, 0)
        model.undo()
        for _ in 0..<300 {
            if !model.busy && first.tags.isEmpty && second.tags.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(first.tags.isEmpty); XCTAssertTrue(second.tags.isEmpty)
        first.configure(other)
        for _ in 0..<100 {
            if FileTagCache.shared.cached(other) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(first.tags.isEmpty)
        XCTAssertEqual(first.intrinsicContentSize.width, 0)
    }

    func testTagWritesAndUndoPreserveCustomColorsAndFinderNames() throws {
        let url = folder.appendingPathComponent("colors.txt")
        try Data().write(to: url)
        try FileTag.write(["Client\n4"], to: url)
        let result = LocalFiles.apply([.tags(url, ["Client\n4", "Red\n6"])])
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(FileTag.read(url).map(\.color), [4, 6])
        XCTAssertEqual(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Client", "Red"])
        let undo = LocalFiles.apply(result.inverse)
        XCTAssertTrue(undo.errors.isEmpty)
        XCTAssertEqual(FileTag.read(url), [FileTag("Client\n4")])
        XCTAssertEqual(try url.resourceValues(forKeys: [.tagNamesKey]).tagNames, ["Client"])
    }

    func testFinderTagColorsAndNames() {
        XCTAssertEqual(FileTag("Client\n6").name, "Client")
        XCTAssertEqual(FileTag("Client\n6").color, 6)
        XCTAssertEqual(FileTag("Uncolored").color, 0)
        XCTAssertEqual(FileTag("Malformed\nwrong").color, 0)
    }
}
