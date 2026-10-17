import AppKit
import XCTest
@testable import FinderSearch

final class SidebarNavigationTests: XCTestCase {
    @MainActor func testFinderSyncIsOptInPersistsAndKeepsLocalFavoritesWhenDisabled() async throws {
        let domain = "FinderSearch.SyncPreferenceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["/local/custom"], forKey: FavoriteFolders.key)
        let workspace = BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: FinderFavorites.syncEnabledKey))
        await workspace.syncFinderFavorites(
            enabled: defaults.bool(forKey: FinderFavorites.syncEnabledKey)
        ) { _ in
            XCTFail("The default must not read or import Finder favorites"); return []
        }
        XCTAssertEqual(workspace.favorites, ["/local/custom"])

        defaults.set(true, forKey: FinderFavorites.syncEnabledKey)
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        XCTAssertTrue(reopenedDefaults.bool(forKey: FinderFavorites.syncEnabledKey))
        await workspace.syncFinderFavorites(
            enabled: reopenedDefaults.bool(forKey: FinderFavorites.syncEnabledKey)
        ) { _ in
            [.init(id: 1, path: "/finder/first")]
        }
        XCTAssertEqual(workspace.favorites, ["/finder/first"])

        defaults.set(false, forKey: FinderFavorites.syncEnabledKey)
        await workspace.syncFinderFavorites(enabled: false) { _ in
            XCTFail("Disabling sync must not overwrite the current sidebar"); return []
        }
        let restarted = BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: reopenedDefaults)
        XCTAssertFalse(reopenedDefaults.bool(forKey: FinderFavorites.syncEnabledKey))
        XCTAssertEqual(restarted.favorites, ["/finder/first"])
        // Re-enabling in an already-open window must refresh, rather than keep its launch snapshot.
        await workspace.syncFinderFavorites(enabled: true) { _ in
            [.init(id: 2, path: "/finder/new")]
        }
        XCTAssertEqual(workspace.favorites, ["/finder/new"])
    }

    func testFinderFavoritesOnlyImportVisibleFoldersInFinderOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        let app = root.appendingPathComponent("Example.app", isDirectory: true)
        for folder in [first, second, app] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let file = root.appendingPathComponent("query.savedSearch")
        try Data().write(to: file)
        let entries = try FinderFavorites.folders(
            from: [
                .init(id: 1, url: second),
                .init(id: 2, url: URL(string: "x-apple-finder:AirDrop")),
                .init(id: 3, url: file),
                .init(id: 4, url: first, hidden: true),
                .init(id: 5, url: app),
                .init(id: 6, url: first),
                .init(id: 7, url: second.appendingPathComponent(".")),
            ], cached: [])
        XCTAssertEqual(entries, [.init(id: 1, path: second.path), .init(id: 6, path: first.path)])
    }

    func testFinderFavoritesKeepOfflineItemsByIDButDropRemovedAndHiddenItems() throws {
        let entries = try FinderFavorites.folders(
            from: [
                .init(id: 2, url: nil),
                .init(id: 3, url: nil, hidden: true),
                .init(id: 99, url: nil),
                .init(id: 1, url: URL(fileURLWithPath: "/unmounted/first")),
            ],
            cached: [
                .init(id: 1, path: "/unmounted/first"),
                .init(id: 2, path: "/unmounted/second"),
                .init(id: 3, path: "/hidden"),
                .init(id: 4, path: "/removed"),
            ])
        XCTAssertEqual(
            entries,
            [
                .init(id: 2, path: "/unmounted/second"), .init(id: 1, path: "/unmounted/first"),
            ])
        XCTAssertThrowsError(
            try FinderFavorites.folders(from: [.init(id: 99, url: nil)], cached: []))
        XCTAssertEqual(try FinderFavorites.folders(from: [], cached: entries), [])
    }

    @MainActor func testFinderSyncUpdatesWindowsAndRefreshesOrderAndRemovalsAtNextLaunch()
        async throws
    {
        let suite = "FinderSearch.finder-sync.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/local/custom"], forKey: FavoriteFolders.key)
        func workspace() -> BrowserWorkspace {
            BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: defaults)
        }
        let first = workspace(), second = workspace()
        let snapshot: [FinderFavorites.Entry] = [
            .init(id: 2, path: "/finder/second"), .init(id: 1, path: "/finder/first"),
        ]
        await first.syncFinderFavorites(enabled: true) { cached in
            XCTAssertTrue(cached.isEmpty)
            return snapshot
        }
        XCTAssertEqual(first.favorites, snapshot.map(\.path))
        XCTAssertEqual(second.favorites, first.favorites)
        XCTAssertEqual(defaults.stringArray(forKey: FinderFavorites.originalKey), ["/local/custom"])
        await first.syncFinderFavorites(enabled: true) { _ in
            XCTFail("A tab redraw must not sync the same workspace again")
            return []
        }
        // Existing local sidebar operations still work during the session.
        first.addFavorite(URL(fileURLWithPath: "/local/extra"))
        XCTAssertEqual(second.favorites.last, "/local/extra")
        let next = workspace()
        await next.syncFinderFavorites(enabled: true) { cached in
            XCTAssertEqual(cached, snapshot)
            return [.init(id: 1, path: "/finder/first")]
        }
        XCTAssertEqual(next.favorites, ["/finder/first"])
        XCTAssertEqual(first.favorites, next.favorites)
        XCTAssertEqual(defaults.stringArray(forKey: FinderFavorites.originalKey), ["/local/custom"])
    }

    @MainActor func testFinderSyncFailureAndCancellationKeepCacheAndEmptyFinderClearsIt()
        async throws
    {
        let suite = "FinderSearch.finder-sync.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cached: [FinderFavorites.Entry] = [.init(id: 1, path: "/last/success")]
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: FinderFavorites.cacheKey)
        defaults.set(cached.map(\.path), forKey: FavoriteFolders.key)
        let workspace = BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: defaults)
        await workspace.syncFinderFavorites(enabled: true) { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        XCTAssertEqual(workspace.favorites, cached.map(\.path))
        XCTAssertEqual(defaults.data(forKey: FinderFavorites.cacheKey), data)
        await workspace.syncFinderFavorites(enabled: true) { _ in throw CancellationError() }
        XCTAssertEqual(workspace.favorites, cached.map(\.path))
        await workspace.syncFinderFavorites(enabled: true) { _ in [] }
        XCTAssertTrue(workspace.favorites.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: FavoriteFolders.key), [])
    }

    @MainActor func testFavoritesMigrationOrderingRemovalAndWindowSynchronization() throws {
        let suite = "FinderSearch.sidebar.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let custom = "/fixture/custom"
        defaults.set([custom, custom, "/Applications"], forKey: "favorites")
        func workspace() -> BrowserWorkspace {
            BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: defaults)
        }
        let first = workspace(), second = workspace()
        XCTAssertEqual(first.favorites, FavoriteFolders.defaults() + [custom])
        let initial = first.favorites
        first.moveFavorites(from: IndexSet(integer: initial.count - 1), to: 0)
        XCTAssertEqual(first.favorites, [custom] + FavoriteFolders.defaults())
        XCTAssertEqual(second.favorites, first.favorites)
        first.removeFavorite("/Applications")
        XCTAssertFalse(first.favorites.contains("/Applications"))
        XCTAssertEqual(workspace().favorites, first.favorites)
        XCTAssertEqual(
            defaults.stringArray(forKey: "favorites"), [custom, custom, "/Applications"])
        // Re-add uses the same persistent list and refuses duplicates.
        first.addFavorite(URL(fileURLWithPath: "/Applications"))
        first.addFavorite(URL(fileURLWithPath: "/Applications"))
        XCTAssertEqual(first.favorites.filter { $0 == "/Applications" }.count, 1)
        XCTAssertEqual(first.favorites.last, "/Applications")
        for path in first.favorites { first.removeFavorite(path) }
        XCTAssertTrue(workspace().favorites.isEmpty)
    }

    @MainActor func testRemovedShortcutDoesNotRemainSelectedAndInvalidReorderIsIgnored() throws {
        let suite = "FinderSearch.sidebar.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = BrowserWorkspace(volumeLoader: { [] }, favoritesDefaults: defaults)
        let initial = workspace.favorites
        workspace.moveFavorites(from: IndexSet(integer: 999), to: 0)
        workspace.moveFavorites(from: IndexSet(integer: 0), to: -1)
        XCTAssertEqual(workspace.favorites, initial)
        workspace.removeFavorite("/Applications")
        let state = SidebarState(
            route: "/Applications", favorites: workspace.favorites,
            volumes: [], ejectingVolumes: [], showDiskAccessHint: false)
        XCTAssertNil(state.selection)
    }

    func testMouseButtonMappingLeavesMiddleClickAndUnrelatedEventsAlone() {
        XCTAssertEqual(MouseNavigationCommand.command(type: .otherMouseDown, button: 3), .back)
        XCTAssertEqual(MouseNavigationCommand.command(type: .otherMouseDown, button: 4), .forward)
        for button in [0, 1, 2, 5] {
            XCTAssertNil(MouseNavigationCommand.command(type: .otherMouseDown, button: button))
        }
        XCTAssertNil(MouseNavigationCommand.command(type: .otherMouseUp, button: 3))
        XCTAssertNil(MouseNavigationCommand.command(type: .keyDown, button: 3))
    }

    @MainActor func testMouseNavigationTargetsItsWindowAndUpdatedTab() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        var first: [MouseNavigationCommand] = [], second: [MouseNavigationCommand] = []
        let view = MouseNavigationView {
            first.append($0); return true
        }
        window.contentView = view
        XCTAssertFalse(view.handle(.back, in: other))
        XCTAssertFalse(view.handle(.back, in: nil))
        XCTAssertFalse(view.handle(nil, in: window))
        XCTAssertTrue(view.handle(.back, in: window))
        XCTAssertEqual(first, [.back])
        view.navigate = {
            second.append($0); return true
        }
        XCTAssertTrue(view.handle(.forward, in: window))
        XCTAssertEqual(first, [.back])
        XCTAssertEqual(second, [.forward])
        view.navigate = { _ in false }
        XCTAssertFalse(view.handle(.back, in: window))
        window.contentView = nil
        XCTAssertFalse(view.handle(.back, in: window))
    }
    @MainActor func testFavoriteDragOnlyReordersAfterDraggingOntoAnotherRow() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let source = FavoriteDragView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let target = FavoriteDragView(frame: NSRect(x: 0, y: 50, width: 200, height: 30))
        source.path = "/source"; target.path = "/target"
        container.addSubview(source); container.addSubview(target); window.contentView = container
        var moves: [(String, String)] = []
        source.move = { moves.append(($0, $1)) }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0))
        }
        let start = CGPoint(x: 20, y: 15), end = CGPoint(x: 20, y: 65)
        XCTAssertFalse(source.handle(try event(.leftMouseDown, start)))
        XCTAssertFalse(source.handle(try event(.leftMouseUp, start)))
        XCTAssertTrue(moves.isEmpty)
        XCTAssertFalse(source.handle(try event(.leftMouseDown, start)))
        XCTAssertTrue(source.handle(try event(.leftMouseDragged, end)))
        XCTAssertTrue(moves.isEmpty)
        let preview = try XCTUnwrap(source.dragPreview)
        let marker = try XCTUnwrap(source.insertionMarker)
        XCTAssertTrue(preview.superview === container)
        XCTAssertFalse(marker.isHidden)
        let previousOrigin = preview.frame.origin
        XCTAssertTrue(source.handle(try event(.leftMouseDragged, CGPoint(x: 30, y: 66))))
        XCTAssertNotEqual(preview.frame.origin, previousOrigin)
        XCTAssertTrue(source.handle(try event(.leftMouseUp, end)))
        XCTAssertNil(source.dragPreview)
        XCTAssertNil(source.insertionMarker)
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.0, "/source")
        XCTAssertEqual(moves.first?.1, "/target")
        XCTAssertFalse(source.handle(try event(.leftMouseUp, end)))
        XCTAssertFalse(source.handle(try event(.leftMouseDown, start)))
        XCTAssertTrue(source.handle(try event(.leftMouseDragged, end)))
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                keyCode: 53))
        XCTAssertTrue(source.handle(escape))
        XCTAssertNil(source.dragPreview)
        XCTAssertNil(source.insertionMarker)
        XCTAssertFalse(source.handle(try event(.leftMouseUp, end)))
        XCTAssertEqual(moves.count, 1)
        window.contentView = nil
    }

}
