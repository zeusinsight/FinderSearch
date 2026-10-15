import XCTest
import AppKit
@testable import FinderSearch

final class NewFolderRenameTests: XCTestCase {
    @MainActor func testRapidNewFolderTypingAndReturnReachNameEditorInOriginalFolder() async throws
    {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Current")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SearchModel()
        let oldMode = model.viewMode
        defer { model.viewMode = oldMode }
        model.navigate(folder)
        model.viewMode = .list
        model.newFolder()
        XCTAssertTrue(
            model.awaitingCreatedRename,
            "Naming must own typing before asynchronous creation finishes")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (text, code) in [("w", UInt16(13)), ("o", 31), ("r", 15), ("k", 40), ("\r", 36)] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: text,
                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            XCTAssertTrue(model.bufferRenameInput(event, editorIsActive: false))
        }
        for _ in 0..<200 {
            if model.renaming != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let hit = try XCTUnwrap(model.renaming)
        XCTAssertEqual(hit.url.deletingLastPathComponent().path, folder.path)
        let field = RenameTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
        window.contentView?.addSubview(field)
        field.begin(
            hit, commit: { model.commitRename($0) }, cancel: { model.cancelRename() },
            pendingInput: { model.takeRenameInput(for: hit.path) })
        let expected = folder.appendingPathComponent("work")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: expected.path), !model.busy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: expected.path),
            "All early letters and Return must reach the actual native rename editor")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("work").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("untitled folder").path))
        XCTAssertFalse(model.awaitingCreatedRename)
        XCTAssertNil(model.renaming)
    }

    @MainActor func testFailedEmptyOrCancelledPreparationReleasesNamingInput() async throws {
        for outcome in 0..<3 {
            let model = SearchModel()
            model.prepareOperations(name: "New Folder", renameCreated: true) {
                if outcome == 0 { throw CocoaError(.fileWriteNoPermission) }
                if outcome == 1 { throw CancellationError() }
                return []
            }
            XCTAssertTrue(model.awaitingCreatedRename)
            let event = try key("x", code: 7)
            XCTAssertTrue(model.bufferRenameInput(event, editorIsActive: false))
            for _ in 0..<200 {
                if !model.busy { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(model.busy)
            XCTAssertFalse(model.awaitingCreatedRename)
            XCTAssertNil(model.renaming)
            XCTAssertFalse(model.bufferRenameInput(event, editorIsActive: false))
            let target = Hit(path: "/fixture/next", kind: "dir", size: 0, mtime: 0, score: 0)
            model.beginRename(target)
            XCTAssertTrue(model.takeRenameInput(for: target.path).isEmpty)
            model.cancelRename()
        }
    }

    @MainActor func testActiveEditorAndCommandShortcutsAreNotBufferedAndInputDrainsOnce() throws {
        let model = SearchModel()
        let target = Hit(path: "/fixture/new", kind: "dir", size: 0, mtime: 0, score: 0)
        model.beginRename(target)
        let text = try key("x", code: 7)
        XCTAssertFalse(model.bufferRenameInput(text, editorIsActive: true))
        XCTAssertFalse(
            model.bufferRenameInput(
                try key("a", code: 0, modifiers: .command), editorIsActive: false))
        XCTAssertTrue(model.bufferRenameInput(text, editorIsActive: false))
        XCTAssertTrue(model.takeRenameInput(for: "/fixture/other").isEmpty)
        XCTAssertEqual(model.takeRenameInput(for: target.path).map(\.characters), ["x"])
        XCTAssertTrue(model.takeRenameInput(for: target.path).isEmpty)
        model.cancelRename()
    }

    @MainActor private func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [])
        throws -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
}
