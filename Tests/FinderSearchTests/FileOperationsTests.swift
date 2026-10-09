import XCTest
@testable import FinderSearch

final class FileOperationsTests: XCTestCase {
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

    @MainActor func testSortedCacheTracksSortAndHiddenChanges() {
        let model = SearchModel()
        model.hits = [
            Hit(path: "/b.txt", kind: "file", size: 2, mtime: 0, score: 0),
            Hit(path: "/a.txt", kind: "file", size: 1, mtime: 0, score: 0),
            Hit(path: "/.hidden", kind: "file", size: 0, mtime: 0, score: 0),
        ]
        XCTAssertEqual(model.sortedHits.map(\.name), ["a.txt", "b.txt"])
        model.ascending = false
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
        try await Task.sleep(for: .milliseconds(200))
        let early = await engine.queries
        XCTAssertTrue(early.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
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
