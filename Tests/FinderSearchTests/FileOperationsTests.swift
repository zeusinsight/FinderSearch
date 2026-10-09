import XCTest
import AppKit
@testable import FinderSearch

final class FileOperationsTests: XCTestCase {
    @MainActor func testNewTextFileAvoidsCollisionsAndSupportsUndoRedo() async throws {
        let existing = try write("untitled.txt")
        let model = SearchModel(); model.location = folder; model.route = folder.path
        model.newTextFile(); try await waitForOperation(model)
        let created = folder.appendingPathComponent("untitled 2.txt")
        XCTAssertEqual(try Data(contentsOf: created), Data())
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        XCTAssertTrue(model.hits.contains { $0.path == created.path && $0.kind == "file" })
        model.undo(); try await waitForOperation(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        model.redo(); try await waitForOperation(model)
        XCTAssertEqual(try Data(contentsOf: created), Data())
        let collision = LocalFiles.apply([.textFile(existing)])
        XCTAssertEqual(collision.failed.count, 1)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
    }
    @MainActor func testInlineRenameValidatesAndCancelsWithoutChangingFile() throws {
        let url = try write("original.txt")
        let hit = try Hit.read(url)
        let model = SearchModel(); model.hits = [hit]; model.selection = [hit.path]
        model.rename()
        XCTAssertEqual(model.renaming, hit)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.commitRename("bad/name"))
        XCTAssertEqual(model.renaming, hit)
        XCTAssertNotNil(model.error)
        model.cancelRename()
        XCTAssertNil(model.renaming)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }
    @MainActor func testInlineRenameCommitsOptimisticallyAndSupportsUndo() async throws {
        let url = try write("original.txt")
        let hit = try Hit.read(url)
        let model = SearchModel(); model.location = folder; model.route = folder.path
        model.hits = [hit]; model.selection = [hit.path]
        model.rename()
        XCTAssertTrue(model.commitRename("renamed.txt"))
        XCTAssertNil(model.renaming)
        let destination = folder.appendingPathComponent("renamed.txt")
        XCTAssertEqual(model.hits.first?.path, destination.path)
        try await waitForOperation(model)
        XCTAssertEqual(model.selection, [destination.path])
        for _ in 0..<100 {
            if !model.loading && !model.sorting { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.selection, [destination.path])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        model.undo(); try await waitForOperation(model)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }
    @MainActor func testRenamingCurrentFolderUpdatesItsLocationAndUndo() async throws {
        let child = folder.appendingPathComponent("child", isDirectory: true)
        let renamed = folder.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let hit = try Hit.read(child)
        let model = SearchModel(); model.location = child; model.route = child.path
        model.extraHits = [hit]; model.selection = [hit.path]
        model.rename(); XCTAssertTrue(model.commitRename("renamed"))
        try await waitForOperation(model)
        XCTAssertEqual(model.location.path, renamed.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        model.undo(); try await waitForOperation(model)
        XCTAssertEqual(model.location.path, child.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }
    @MainActor func testNativeRenameEditorHandlesReturnAndEscape() throws {
        let url = try write("report😀.txt")
        let hit = try Hit.read(url)
        XCTAssertEqual(RenameTextField.selectedNameRange(hit), NSRange(location: 0, length: 8))
        let model = SearchModel(); model.hits = [hit]; model.selection = [hit.path]; model.rename()
        let field = RenameTextField(string: hit.name)
        field.begin(hit, commit: { model.commitRename($0) }, cancel: { model.cancelRename() })
        let editor = NSTextView(); editor.string = "bad/name"
        XCTAssertTrue(field.control(field, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertNotNil(model.renaming, "Invalid input keeps editing active")
        field.stringValue = "bad/name"
        XCTAssertTrue(field.control(field, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertNil(model.renaming)
        XCTAssertNil(field.editingPath)
        XCTAssertEqual(field.stringValue, hit.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "FinderSearch-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func write(_ name: String, _ text: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name); try Data(text.utf8).write(to: url);
        return url
    }
    func testCopyConflictNeverOverwrites() throws {
        let a = try write("a.txt"), b = try write("b.txt", "keep me")
        let result = LocalFiles.apply([.copy(a, b)])
        XCTAssertEqual(result.errors.count, 1); XCTAssertTrue(result.inverse.isEmpty)
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "keep me")
    }
    func testMoveAndUndoPreserveContents() throws {
        let a = try write("a.txt"), b = folder.appendingPathComponent("renamed.txt")
        let move = LocalFiles.apply([.move(a, b)])
        XCTAssertTrue(move.errors.isEmpty);
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        let undo = LocalFiles.apply(move.inverse)
        XCTAssertTrue(undo.errors.isEmpty);
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "original")
        let redo = LocalFiles.apply(undo.inverse)
        XCTAssertTrue(redo.errors.isEmpty);
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "original")
    }
    func testTrashAndRestore() throws {
        let a = try write("trash-restore.txt")
        let result = LocalFiles.apply([.trash(a)])
        XCTAssertTrue(result.errors.isEmpty);
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        let restore = LocalFiles.apply(result.inverse)
        XCTAssertTrue(restore.errors.isEmpty);
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "original")
    }
    func testBatchFailureRetainsSuccessfulUndo() throws {
        let a = try write("a.txt"), b = folder.appendingPathComponent("b.txt")
        let batch = LocalFiles.apply([
            .move(a, b),
            .move(
                folder.appendingPathComponent("missing.txt"),
                folder.appendingPathComponent("never.txt")),
        ])
        XCTAssertEqual(batch.errors.count, 1); XCTAssertEqual(batch.inverse.count, 1)
        XCTAssertTrue(LocalFiles.apply(batch.inverse).errors.isEmpty);
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "original")
    }
    func testFolderListingHiddenFilesAndUniqueNames() throws {
        _ = try write(".secret"); _ = try write("notes.txt"); _ = try write("notes copy.txt")
        XCTAssertEqual(try LocalFiles.list(folder, hidden: false).count, 2)
        XCTAssertEqual(try LocalFiles.list(folder, hidden: true).count, 3)
        XCTAssertEqual(
            LocalFiles.availableName(in: folder, name: "notes.txt", suffix: " copy")
                .lastPathComponent, "notes copy 2.txt")
    }
    func testTagsRetainUndo() throws {
        let a = try write("tagged.txt")
        let tagged = LocalFiles.apply([.tags(a, ["FinderSearchVerification"])])
        XCTAssertTrue(tagged.errors.isEmpty)
        XCTAssertEqual(
            try a.resourceValues(forKeys: [.tagNamesKey]).tagNames, ["FinderSearchVerification"])
        XCTAssertTrue(LocalFiles.apply(tagged.inverse).errors.isEmpty)
        XCTAssertTrue((try a.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []).isEmpty)
    }
    @MainActor func waitForOperation(_ model: SearchModel) async throws {
        for _ in 0..<100 { if !model.busy { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("File operation timed out")
    }
    @MainActor func testSlowCommandPreparationKeepsMainActorAvailable() async throws {
        let model = SearchModel()
        model.navigate(folder)
        let destination = folder.appendingPathComponent("prepared folder")
        model.prepareOperations(name: "New Folder") {
            XCTAssertFalse(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.15)
            return [.folder(destination)]
        }
        XCTAssertTrue(model.busy)
        var heartbeats = 0
        for _ in 0..<200 {
            if !model.busy { break }
            heartbeats += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.busy)
        XCTAssertGreaterThan(heartbeats, 5, "Slow filesystem preparation must allow UI work to run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(model.undoStack.last?.name, "New Folder")
    }
    @MainActor func testCommandPreparationFailurePreservesFilesAndReportsError() async throws {
        let source = try write("source.txt")
        let child = folder.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let model = SearchModel()
        model.navigate(folder)
        model.transfer([folder], to: child, move: true)
        try await waitForOperation(model)
        XCTAssertEqual(model.error, "A folder cannot be moved or copied inside itself.")
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
    }
    @MainActor func testOptimisticRenameAndPartialFailureReconcileWithUndo() async throws {
        let a = try write("a.txt"), b = try write("b.txt"), existing = try write("existing.txt", "keep")
        let renamed = folder.appendingPathComponent("renamed.txt")
        let model = SearchModel(); model.navigate(folder)
        for _ in 0..<100 {
            if !model.loading { break }; try await Task.sleep(for: .milliseconds(10))
        }
        model.selection = [a.path]
        model.perform([.move(a, renamed), .move(b, existing)], name: "Move")
        XCTAssertTrue(model.busy)
        XCTAssertTrue(model.hits.contains { $0.path == renamed.path })
        XCTAssertFalse(model.hits.contains { $0.path == a.path })
        XCTAssertEqual(model.selection, [renamed.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        try await waitForOperation(model)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.hits.contains { $0.path == b.path })
        XCTAssertTrue(model.hits.contains { $0.path == renamed.path })
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
        XCTAssertEqual(model.undoStack.count, 1)
        model.undo()
        XCTAssertTrue(model.hits.contains { $0.path == a.path })
        XCTAssertFalse(model.hits.contains { $0.path == renamed.path })
        try await waitForOperation(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    @MainActor func testOptimisticTrashImmediatelyRemovesRowAndUndoRestoresIt() async throws {
        let source = try write("optimistic-trash.txt")
        let model = SearchModel(); model.navigate(folder)
        for _ in 0..<100 {
            if !model.loading { break }; try await Task.sleep(for: .milliseconds(10))
        }
        model.selection = [source.path]
        model.trash()
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try await waitForOperation(model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        model.undo()
        try await waitForOperation(model)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor func testFailedOptimisticMoveRestoresOriginalRowAndSelection() async throws {
        let source = try write("source.txt"), collision = try write("collision.txt", "keep")
        let model = SearchModel(); model.navigate(folder)
        for _ in 0..<100 {
            if !model.loading { break }; try await Task.sleep(for: .milliseconds(10))
        }
        model.selection = [source.path]
        model.perform([.move(source, collision)], name: "Rename")
        try await waitForOperation(model)
        XCTAssertTrue(model.hits.contains { $0.path == source.path })
        XCTAssertEqual(model.selection, [source.path])
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertEqual(try String(contentsOf: collision, encoding: .utf8), "keep")
    }

    @MainActor func testPrefetchedFolderAppearsImmediatelyThenRefreshes() async throws {
        let target = URL(fileURLWithPath: "/tmp/FinderSearch-prefetch-" + UUID().uuidString)
        let loader = PreviewFolderLoader(folder: target)
        let model = SearchModel(folderLoader: { try await loader.load($0, $1) })
        await model.prefetchFolder(target)?.value
        model.navigate(target)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.hits.map(\.name), ["cached.txt"])
        for _ in 0..<100 {
            if model.hits.first?.name == "fresh.txt" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.hits.map(\.name), ["fresh.txt"])
    }

    @MainActor func testUncachedFolderShowsNamesBeforeMetadataArrives() async throws {
        let target = URL(fileURLWithPath: "/tmp/FinderSearch-progressive-" + UUID().uuidString)
        let path = target.appendingPathComponent("example.txt").path
        let model = SearchModel(
            folderLoader: { _, _ in
                try await Task.sleep(for: .milliseconds(300))
                return [Hit(path: path, kind: "file", size: 42, mtime: 1234, score: 0)]
            },
            folderPreviewLoader: { _, _ in
                [Hit(path: path, kind: "file", size: 0, mtime: 0, score: 0, metadataPending: true)]
            })
        model.navigate(target)
        XCTAssertTrue(model.loading)
        for _ in 0..<100 {
            if !model.hits.isEmpty { break }; try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.hits.map(\.name), ["example.txt"])
        XCTAssertTrue(model.loading, "Names must be visible while metadata is still loading")
        XCTAssertEqual(model.hits.first?.metadataPending, true)
        model.selection = [path]
        for _ in 0..<100 {
            if !model.loading { break }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.hits.first?.size, 42)
        XCTAssertEqual(model.hits.first?.mtime, 1234)
        XCTAssertNotEqual(model.hits.first?.metadataPending, true)
        XCTAssertEqual(model.selection, [path])
    }

    func testDirectoryPreviewIncludesNamesAndBasicKindsWithoutMetadata() async throws {
        let child = folder.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        _ = try write("visible.txt"); _ = try write(".hidden.txt")
        let preview = try await LocalFiles.preview(folder, hidden: false)
        XCTAssertEqual(Set(preview.map(\.name)), ["Child", "visible.txt"])
        XCTAssertEqual(preview.first { $0.name == "Child" }?.kind, "dir")
        XCTAssertTrue(preview.allSatisfy { $0.metadataPending == true })
    }

    @MainActor func testPrefetchedPermissionFailureClearsPreviewAndShowsError() async throws {
        let target = URL(fileURLWithPath: "/tmp/FinderSearch-prefetch-" + UUID().uuidString)
        let loader = PreviewFolderLoader(folder: target, failRefresh: true)
        let model = SearchModel(folderLoader: { try await loader.load($0, $1) })
        await model.prefetchFolder(target)?.value
        model.navigate(target)
        XCTAssertEqual(model.hits.map(\.name), ["cached.txt"])
        for _ in 0..<100 {
            if model.error != nil { break }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.hits.isEmpty)
    }
    @MainActor func testFailedUndoRemainsRecoverable() async throws {
        let a = try write("a.txt"), b = folder.appendingPathComponent("b.txt")
        let model = SearchModel(); model.navigate(folder)
        model.perform([.move(a, b)], name: "Move")
        try await waitForOperation(model)
        _ = try write("a.txt", "conflict")
        model.undo(); try await waitForOperation(model)
        XCTAssertEqual(model.undoStack.count, 1)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "conflict")
        try FileManager.default.removeItem(at: a)
        model.undo(); try await waitForOperation(model)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "original")
    }
    @MainActor func testTransferRejectsFolderInsideItself() async throws {
        let child = folder.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let model = SearchModel(); model.navigate(folder)
        model.transfer([folder], to: child, move: true)
        try await waitForOperation(model)
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor func testBusyTabCannotClose() {
        let workspace = BrowserWorkspace(); workspace.newTab(folder)
        let active = workspace.current; active.busy = true
        workspace.closeTab(active.id)
        XCTAssertEqual(workspace.tabs.count, 2)
        active.busy = false; workspace.closeTab(active.id)
        XCTAssertEqual(workspace.tabs.count, 1)
    }
    func testBackgroundDropNeverConsumesFolderRows() {
        let rect = CGRect(x: 10, y: 40, width: 100, height: 24)
        XCTAssertFalse(
            SafeBackgroundDropTarget.isBackground(
                CGPoint(x: 20, y: 50), bounds: [rect], mode: .icons))
        XCTAssertFalse(
            SafeBackgroundDropTarget.isBackground(
                CGPoint(x: 300, y: 50), bounds: [rect], mode: .list))
        XCTAssertTrue(
            SafeBackgroundDropTarget.isBackground(
                CGPoint(x: 20, y: 100), bounds: [rect], mode: .list))
        XCTAssertFalse(
            SafeBackgroundDropTarget.isBackground(
                CGPoint(x: 20, y: 100), bounds: [], mode: .columns))
    }
    @MainActor func testVirtualViewsClearSearchScope() {
        let model = SearchModel(); model.scope = folder.path
        model.sidebar("recents")
        XCTAssertEqual(model.scope, ""); XCTAssertFalse(model.canWriteHere)
    }
    @MainActor func testClearingSearchRestoresDefaultSynchronouslyAndRefreshes() async throws {
        let original = try write("original.txt")
        let model = SearchModel(engine: RecordingSearchEngine())
        model.navigate(folder)
        for _ in 0..<100 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.hits.map(\.path), [original.path])
        model.query = "something"
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.hits.isEmpty)
        let added = try write("added.txt")
        model.query = ""
        XCTAssertEqual(model.hits.map(\.path), [original.path])
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.searching)
        for _ in 0..<100 {
            if model.hits.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(model.hits.map(\.path)), Set([original.path, added.path]))
        model.query = "cancel me"
        model.query = ""
        XCTAssertEqual(model.hits.count, 2)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.hits.count, 2)
    }

    @MainActor func testSortedCacheTracksSortAndHiddenChanges() async throws {
        let model = SearchModel()
        model.hits = [
            Hit(path: "/b.txt", kind: "file", size: 2, mtime: 0, score: 0),
            Hit(path: "/a.txt", kind: "file", size: 1, mtime: 0, score: 0),
            Hit(path: "/.hidden", kind: "file", size: 0, mtime: 0, score: 0),
        ]
        for _ in 0..<100 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.sorting)
        XCTAssertEqual(model.sortedHits.map(\.name), ["a.txt", "b.txt"])
        model.ascending = false
        XCTAssertEqual(model.sortedHits.map(\.name), ["a.txt", "b.txt"], "Keep rows until the new order is ready")
        for _ in 0..<100 {
            if !model.sorting { break }; try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.sorting)
        XCTAssertEqual(model.sortedHits.map(\.name), ["b.txt", "a.txt"])
        model.showHidden = true
        XCTAssertEqual(model.sortedHits.count, 3)
        model.hits = []
        XCTAssertTrue(model.sortedHits.isEmpty)
    }

    func testStalledEngineCancelsWithoutWaitingForTimeout() async throws {
        let binary = try write("stalled-engine", "#!/bin/sh\nexec /bin/sleep 30\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = Engine(binary: binary.path)
        let request = Task { try await engine.request(["q": "test"]) }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        request.cancel()
        do {
            _ = try await request.value; XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    @MainActor func testSearchDebouncesToFinalQuery() async throws {
        let engine = RecordingSearchEngine()
        let model = SearchModel(engine: engine)
        model.query = "f"
        try await Task.sleep(for: .milliseconds(100))
        model.query = "fi"
        try await Task.sleep(for: .milliseconds(100))
        model.query = "finder"
        try await Task.sleep(for: .milliseconds(50))
        let early = await engine.queries
        XCTAssertTrue(early.isEmpty)
        for _ in 0..<50 {
            if !(await engine.queries).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let final = await engine.queries
        XCTAssertEqual(final, ["finder"])
    }

    @MainActor func testDiskAccessRefreshesAfterGrantAndRevocationWithStaleDaemon() async {
        let probe = DiskAccessProbe()
        let model = SearchModel(
            engine: StatusSearchEngine(fullDiskAccess: false),
            diskAccessCheck: { probe.isGranted })
        await model.refreshStatus()
        XCTAssertTrue(model.ready)
        XCTAssertFalse(model.fullDiskAccess)

        probe.isGranted = true
        await model.refreshStatus()
        XCTAssertTrue(model.fullDiskAccess)

        probe.isGranted = false
        await model.refreshStatus()
        XCTAssertFalse(model.fullDiskAccess)
    }

    @MainActor func testMissingDaemonPermissionFieldDoesNotHideGrantedAppAccess() async {
        let model = SearchModel(
            engine: StatusSearchEngine(fullDiskAccess: nil), diskAccessCheck: { true })
        await model.refreshStatus()
        XCTAssertTrue(model.fullDiskAccess)
    }

    @MainActor func testDaemonPermissionDoesNotOverrideDeniedAppAccess() async {
        let model = SearchModel(
            engine: StatusSearchEngine(fullDiskAccess: true), diskAccessCheck: { false })
        await model.refreshStatus()
        XCTAssertFalse(model.fullDiskAccess)
    }

}

private actor PreviewFolderLoader {
    let folder: URL
    let failRefresh: Bool
    private var requests = 0
    init(folder: URL, failRefresh: Bool = false) {
        self.folder = folder; self.failRefresh = failRefresh
    }
    func load(_ folder: URL, _ hidden: Bool) throws -> [Hit] {
        requests += 1
        if requests > 1 && failRefresh { throw CocoaError(.fileReadNoPermission) }
        return [Hit(path: folder.appendingPathComponent(requests == 1 ? "cached.txt" : "fresh.txt").path,
            kind: "file", size: 1, mtime: 0, score: 0)]
    }
}

private final class DiskAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    var isGranted: Bool {
        get { lock.withLock { granted } }
        set { lock.withLock { granted = newValue } }
    }
}

private struct StatusSearchEngine: SearchService {
    let fullDiskAccess: Bool?
    func request(_ fields: [String: Any]) async throws -> Reply {
        Reply(ok: true, error: nil, hits: nil, took_us: nil, entries: 1,
              full_disk_access: fullDiskAccess)
    }
}

private actor RecordingSearchEngine: SearchService {
    var queries: [String] = []
    func request(_ fields: [String: Any]) async throws -> Reply {
        queries.append(fields["q"] as? String ?? "")
        return Reply(
            ok: true, error: nil, hits: [], took_us: 1, entries: nil, full_disk_access: nil)
    }
}
