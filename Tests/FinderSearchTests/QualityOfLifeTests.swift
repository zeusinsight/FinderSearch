import XCTest
import AppKit
@testable import FinderSearch

final class QualityOfLifeTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        // Home-volume fixtures let the real macOS Trash/restore path be tested.
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "FinderSearch-qol-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func write(_ name: String, _ text: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url); return url
    }
    @MainActor func wait(_ model: SearchModel) async throws {
        for _ in 0..<300 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Operation did not finish")
    }
    func testNativeCopyPublishesProgressAndPreservesLinks() throws {
        let source = try write("source.txt"),
            destination = folder.appendingPathComponent("copy.txt")
        let probe = CopyProbe()
        let control = FileOperationControl { probe.record($0) }
        control.start(item: "source.txt", completed: 0, total: 1, expectedBytes: 8)
        try NativeFileCopy.copy(source, to: destination, control: control)
        XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
        XCTAssertGreaterThan(probe.bytes, 0)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let copiedLink = folder.appendingPathComponent("link-copy")
        try NativeFileCopy.copy(link, to: copiedLink, control: FileOperationControl())
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: copiedLink.path), source.path)
        XCTAssertThrowsError(try NativeFileCopy.copy(source, to: destination, control: control))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
    }
    func testCopyCancellationRemovesStagingAndLeavesSource() throws {
        let source = folder.appendingPathComponent("large.bin"),
            destination = folder.appendingPathComponent("cancelled.bin")
        try Data(repeating: 42, count: 16 * 1024 * 1024).write(to: source)
        let probe = CopyProbe()
        let control = FileOperationControl { progress in
            probe.record(progress)
            if progress.bytes > 0 { probe.control?.cancel() }
        }
        probe.control = control
        XCTAssertThrowsError(try NativeFileCopy.copy(source, to: destination, control: control)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertGreaterThan(probe.bytes, 0)
        XCTAssertEqual(
            try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, 16 * 1024 * 1024)
        XCTAssertFalse(LocalFiles.exists(destination))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path), ["large.bin"])
    }
    func testReplaceAndUndoRedoPreserveBothVersions() throws {
        let source = try write("source.txt", "new"),
            destination = try write("destination.txt", "old")
        let applied = LocalFiles.apply(
            [.replace(source, destination, move: false)], control: FileOperationControl())
        XCTAssertTrue(applied.errors.isEmpty, applied.errors.description)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        let undo = LocalFiles.apply(applied.inverse, control: FileOperationControl())
        XCTAssertTrue(undo.errors.isEmpty, undo.errors.description)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        let redo = LocalFiles.apply(undo.inverse, control: FileOperationControl())
        XCTAssertTrue(redo.errors.isEmpty, redo.errors.description)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        // Restore both fixture versions, including Trash items, before cleanup.
        XCTAssertTrue(LocalFiles.apply(redo.inverse).errors.isEmpty)
    }
    func testFailedReplacementRestoresOldDestination() throws {
        let destination = try write("destination.txt", "old")
        let result = LocalFiles.apply(
            [.replace(folder.appendingPathComponent("missing"), destination, move: false)],
            control: FileOperationControl())
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
    }
    @MainActor func testConflictKeepBothAndSkip() async throws {
        let sourceFolder = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(
            at: sourceFolder, withIntermediateDirectories: false)
        let source = sourceFolder.appendingPathComponent("same.txt")
        try Data("new".utf8).write(to: source)
        let existing = try write("same.txt", "old")
        let model = SearchModel(); model.navigate(folder)
        model.transfer([source], to: folder, move: false)
        for _ in 0..<100 {
            if model.conflict != nil { break }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.conflict)
        model.resolveConflict(.keepBoth); try await wait(model)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("same 2.txt"), encoding: .utf8),
            "new")
        model.transfer([source], to: folder, move: true)
        for _ in 0..<100 {
            if model.conflict != nil { break }; try await Task.sleep(for: .milliseconds(10))
        }
        model.resolveConflict(.skip); try await wait(model)
        XCTAssertTrue(LocalFiles.exists(source))
        XCTAssertNil(model.conflict)
    }
    func testTransferCanonicalSelfAndReservedNames() throws {
        let source = try write("source.txt")
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        XCTAssertTrue(try TransferPlan.candidates([source], into: alias, move: true).isEmpty)
        XCTAssertEqual(
            try TransferPlan.candidates([source], into: alias, move: false).first?.destination
                .lastPathComponent, "source copy.txt")
        XCTAssertEqual(
            LocalFiles.availableName(
                in: folder, name: "new.txt",
                reserved: [folder.appendingPathComponent("new.txt").path]
            ).lastPathComponent, "new 2.txt")
    }
    func testBatchRenameSwapAndUndo() throws {
        let a = try write("a.txt", "A"), b = try write("b.txt", "B")
        let moves = [RenameMove(source: a, destination: b), RenameMove(source: b, destination: a)]
        let result = LocalFiles.apply([.renameBatch(moves)], control: FileOperationControl())
        XCTAssertTrue(result.errors.isEmpty, result.errors.description)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "B")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "A")
        XCTAssertTrue(LocalFiles.apply(result.inverse).errors.isEmpty)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "B")
    }
    func testCancelledBatchRenameRestoresStagedSources() throws {
        let a = try write("a.txt", "A"), b = try write("b.txt", "B")
        let probe = CopyProbe()
        let control = FileOperationControl { progress in
            if progress.completed == 1 { probe.control?.cancel() }
        }
        probe.control = control
        let result = BatchRenames.apply(
            [
                RenameMove(source: a, destination: folder.appendingPathComponent("new-a.txt")),
                RenameMove(source: b, destination: folder.appendingPathComponent("new-b.txt")),
            ], control: control)
        XCTAssertTrue(result.cancelled); XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "B")
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
            ["a.txt", "b.txt"])
    }
    func testCancelledReplacementRestoresDestination() throws {
        let source = try write("source.txt", "new"),
            destination = try write("destination.txt", "old")
        let probe = CopyProbe()
        let control = FileOperationControl { progress in
            if progress.bytes > 0 { probe.control?.cancel() }
        }
        probe.control = control
        let result = LocalFiles.apply(
            [.replace(source, destination, move: false)], control: control)
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
    }
    @MainActor func testNativeRenameSelectsNewRowWithoutCancellingEditor() async throws {
        let a = try Hit.read(write("a.txt")), b = try Hit.read(write("b.txt"))
        let model = SearchModel(); model.hits = [a, b]; model.selection = [a.path]
        for _ in 0..<100 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(10))
        }
        let list = FileList(model: model, focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator(), scroll = list.makeView(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 240), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = scroll
        coordinator.update()
        model.beginRename(b); coordinator.update()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.renaming?.path, b.path)
        XCTAssertEqual(coordinator.table?.selectedRowIndexes, IndexSet(integer: 1))
        model.cancelRename(); coordinator.update()
        window.contentView = nil
    }
    @MainActor func testNativeListRestoresScrollAnchorAndOffset() async throws {
        let model = SearchModel(); model.location = folder; model.route = folder.path
        model.hits = (0..<60).map {
            Hit(
                path: folder.appendingPathComponent(String(format: "%03d.txt", $0)).path,
                kind: "file", size: 1, mtime: 0, score: 0)
        }
        for _ in 0..<100 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(10))
        }
        model.scrollAnchor = model.sortedHits[30].path; model.scrollOffset = 7
        let list = FileList(model: model, focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator()
        let scroll = list.makeView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 240)
        scroll.layoutSubtreeIfNeeded(); coordinator.update(); scroll.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(coordinator.table)
        XCTAssertEqual(scroll.contentView.bounds.minY, table.rect(ofRow: 30).minY + 7, accuracy: 1)
    }
    func testBatchRenameCollisionAndExtensionPreview() throws {
        let a = try write("report.txt"), b = try write("other.txt", "keep")
        let hits = [try Hit.read(a), try Hit.read(b)]
        let numbered = try BatchRenames.plan(
            hits, spec: BatchRenameSpec(mode: .number, text: "Notes", start: 4))
        XCTAssertEqual(
            numbered.map { $0.destination.lastPathComponent }, ["Notes 4.txt", "Notes 5.txt"])
        XCTAssertThrowsError(
            try BatchRenames.plan(hits, spec: BatchRenameSpec(mode: .add, text: "/")))
        XCTAssertThrowsError(try BatchRenames.validate([RenameMove(source: a, destination: b)]))
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "keep")
        let cancelled = FileOperationControl(); cancelled.cancel()
        let result = LocalFiles.apply([.renameBatch(numbered)], control: cancelled)
        XCTAssertTrue(result.cancelled); XCTAssertTrue(LocalFiles.exists(a));
        XCTAssertTrue(LocalFiles.exists(b))
    }
    func testArchiveRoundTripAndNoOverwrite() throws {
        let a = try write("a.txt", "A"), b = try write("b.txt", "B")
        let zip = folder.appendingPathComponent("Archive.zip"),
            extracted = folder.appendingPathComponent("Extracted")
        let compressed = LocalFiles.apply(
            [.compress([a, b], zip)], control: FileOperationControl())
        XCTAssertTrue(compressed.errors.isEmpty, compressed.errors.description)
        try ArchiveFiles.validateZIP(zip)
        let result = LocalFiles.apply([.extract(zip, extracted)], control: FileOperationControl())
        XCTAssertTrue(result.errors.isEmpty, result.errors.description)
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("b.txt"), encoding: .utf8), "B")
        XCTAssertThrowsError(
            try ArchiveFiles.extract(zip, to: extracted, control: FileOperationControl()))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).contains {
                $0.hasPrefix(".FinderSearch-")
            })
    }
    func testArchiveCannotContainItsOwnOutput() throws {
        let output = folder.appendingPathComponent("recursive.zip")
        XCTAssertThrowsError(
            try ArchiveFiles.compress([folder], to: output, control: FileOperationControl()))
        XCTAssertFalse(LocalFiles.exists(output))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertThrowsError(try TransferPlan.candidates([folder], into: folder, move: false))
    }
    func testArchiveProcessCancellationStopsPromptly() async throws {
        let control = FileOperationControl()
        let process = Task.detached { try control.run("/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date(); control.cancel()
        do { _ = try await process.value; XCTFail("Expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
    func testInvalidAndUnsafeArchivesAreRejected() throws {
        let invalid = try write("invalid.zip", "bad data")
        XCTAssertThrowsError(try ArchiveFiles.validateZIP(invalid))
        // A minimal central directory is enough to exercise path/type validation.
        for (name, mode) in [
            ("../escape.txt", UInt32(0x8000)), ("/absolute", 0x8000), ("link", 0xa000),
        ] {
            var central = Data(repeating: 0, count: 46)
            func put(_ value: UInt64, at offset: Int, bytes: Int, into data: inout Data) {
                for index in 0..<bytes {
                    data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
                }
            }
            put(0x02014b50, at: 0, bytes: 4, into: &central)
            put(UInt64(name.utf8.count), at: 28, bytes: 2, into: &central)
            put(UInt64(mode) << 16, at: 38, bytes: 4, into: &central)
            central.append(contentsOf: name.utf8)
            var end = Data(repeating: 0, count: 22)
            put(0x06054b50, at: 0, bytes: 4, into: &end)
            put(1, at: 8, bytes: 2, into: &end); put(1, at: 10, bytes: 2, into: &end)
            put(UInt64(central.count), at: 12, bytes: 4, into: &end)
            central.append(end)
            let zip = folder.appendingPathComponent(UUID().uuidString + ".zip")
            try central.write(to: zip)
            XCTAssertThrowsError(try ArchiveFiles.validateZIP(zip))
        }
    }
    @MainActor func testOptimisticCreationKeepsExistingRowOrder() async throws {
        let model = SearchModel(); model.location = folder; model.route = folder.path
        let a = try Hit.read(write("a.txt")), b = try Hit.read(write("b.txt"))
        model.hits = [b, a]
        for _ in 0..<100 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(10))
        }
        let destination = folder.appendingPathComponent("new folder")
        model.perform([.folder(destination)], name: "New Folder")
        XCTAssertEqual(
            model.sortedHits.filter { $0.path != destination.path }.map(\.path), [a.path, b.path])
        try await wait(model)
    }
    @MainActor func testCreationThroughFolderAliasKeepsRenameAndSelection() async throws {
        let target = folder.appendingPathComponent("Target"),
            alias = folder.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let model = SearchModel(); model.navigate(alias)
        model.newFolder(); try await wait(model)
        let created = alias.appendingPathComponent("untitled folder")
        for _ in 0..<100 {
            if !model.loading && !model.sorting { break };
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.renaming?.path, created.path)
        XCTAssertEqual(model.selection, [created.path])
        XCTAssertEqual(try LocalFiles.list(alias, hidden: false).first?.path, created.path)
        model.cancelRename()
    }
    @MainActor func testCreationStartsInlineRenameAndPreparationCanCancel() async throws {
        let model = SearchModel(); model.navigate(folder)
        model.newFolder(); try await wait(model)
        XCTAssertEqual(model.renaming?.name, "untitled folder")
        model.cancelRename()
        let destination = folder.appendingPathComponent("must-not-exist")
        model.prepareOperations(name: "Slow preparation") {
            Thread.sleep(forTimeInterval: 0.08); return [.folder(destination)]
        }
        model.cancelOperation(); try await wait(model)
        XCTAssertFalse(LocalFiles.exists(destination))
    }
    @MainActor func testTabShortcutsDoNotInterceptTypingOrOtherCommands() throws {
        func event(_ flags: NSEvent.ModifierFlags, code: UInt16 = 17) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "t",
                    charactersIgnoringModifiers: "t", isARepeat: false, keyCode: code))
        }
        XCTAssertEqual(TabShortcut.command(for: try event(.command)), .new)
        XCTAssertEqual(TabShortcut.command(for: try event([.command, .shift])), .reopen)
        XCTAssertNil(TabShortcut.command(for: try event([])))
        XCTAssertNil(TabShortcut.command(for: try event([.command, .option])))
        XCTAssertNil(TabShortcut.command(for: try event(.command, code: 12)))
    }
    @MainActor func testScrollPositionPersistsWithoutInvalidatingBrowser() async throws {
        let suite = "FinderSearch.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = BrowserWorkspace(
            volumeLoader: { [] }, volumeEjector: { _ in }, sessionDefaults: defaults)
        // Let startup publication and its debounced save finish first.
        try await Task.sleep(for: .milliseconds(350))
        let model = workspace.current
        var changes = 0
        let observer = model.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }
        for index in 0..<200 {
            model.scrollAnchor = "/fixture/file-\(index).png"
            model.scrollOffset = 7
        }
        XCTAssertEqual(changes, 0, "Scrolling must not redraw the whole browser")
        try await Task.sleep(for: .milliseconds(350))
        let data = try XCTUnwrap(defaults.data(forKey: WorkspaceSession.key))
        let saved = try JSONDecoder().decode(WorkspaceSession.self, from: data)
        XCTAssertEqual(saved.tabs[0].scrollAnchor, "/fixture/file-199.png")
        XCTAssertEqual(saved.tabs[0].scrollOffset, 7)
        let restored = BrowserWorkspace(
            volumeLoader: { [] }, volumeEjector: { _ in }, sessionDefaults: defaults)
        XCTAssertEqual(restored.current.scrollAnchor, model.scrollAnchor)
    }
    @MainActor func testSessionAndClosedTabRestoration() async throws {
        let suite = "FinderSearch.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalMode = UserDefaults.standard.string(forKey: "viewMode")
        defer { UserDefaults.standard.set(originalMode, forKey: "viewMode") }
        let workspace = BrowserWorkspace(sessionDefaults: defaults)
        workspace.current.navigate(folder)
        let hit = try Hit.read(write("anchor.txt"))
        workspace.current.viewMode = .list; workspace.current.sort = .size
        workspace.current.ascending = false; workspace.current.scrollAnchor = hit.path
        workspace.current.scrollOffset = 7
        workspace.newTab(folder); workspace.current.viewMode = .gallery
        let first = workspace.tabs[0].id, second = workspace.tabs[1].id
        workspace.moveTab(first, to: second)
        XCTAssertEqual(workspace.tabs.map(\.id), [second, first])
        workspace.selectedTab = first; workspace.saveSession()
        let restored = BrowserWorkspace(sessionDefaults: defaults)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.current.location.path, folder.path)
        XCTAssertEqual(restored.current.viewMode, .list)
        XCTAssertEqual(restored.current.sort, .size)
        XCTAssertFalse(restored.current.ascending)
        XCTAssertEqual(restored.current.scrollAnchor, hit.path)
        XCTAssertEqual(restored.current.scrollOffset, 7)
        restored.closeTab(restored.current.id); XCTAssertEqual(restored.tabs.count, 1)
        restored.reopenClosedTab(); XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.current.viewMode, .list)
        XCTAssertEqual(restored.current.scrollAnchor, hit.path)
    }
    @MainActor func testQuickLookNavigationUsesStableOrderedSnapshot() async throws {
        let model = SearchModel()
        let a = try Hit.read(write("a.txt")), b = try Hit.read(write("b.txt"))
        model.hits = [a, b]
        for _ in 0..<100 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(10))
        }
        model.preview = a
        XCTAssertFalse(model.canAdvancePreview(-1)); XCTAssertTrue(model.canAdvancePreview(1))
        model.hits = []  // Refreshes do not change the active preview sequence.
        model.advancePreview(1)
        XCTAssertEqual(model.preview, b); XCTAssertEqual(model.selection, [b.path])
        XCTAssertFalse(model.canAdvancePreview(1))
        model.preview = nil; XCTAssertTrue(model.previewItems.isEmpty)
    }
    @MainActor func testSpringHoverDeduplicationAndLeaving() async throws {
        let loader = SpringLoader(); var opened: [URL] = []
        let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
        loader.hover(a, delay: .milliseconds(40)) { opened.append($0) }
        try await Task.sleep(for: .milliseconds(25))
        loader.hover(a, delay: .milliseconds(40)) { opened.append($0) }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(opened, [a])
        loader.hover(a, delay: .milliseconds(20)) { opened.append($0) }
        loader.hover(b, delay: .milliseconds(20)) { opened.append($0) }
        loader.leave(a)  // Leaving the old row cannot cancel the new row's hover.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(opened, [a, b])
        loader.hover(a, delay: .milliseconds(20)) { opened.append($0) }; loader.cancel()
        try await Task.sleep(for: .milliseconds(40)); XCTAssertEqual(opened, [a, b])
    }
}

private final class CopyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var copied: Int64 = 0
    weak var control: FileOperationControl?
    var bytes: Int64 { lock.withLock { copied } }
    func record(_ progress: FileOperationProgress) {
        lock.withLock { copied = max(copied, progress.bytes) }
    }
}
