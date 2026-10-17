import XCTest
import SwiftUI
@testable import FinderSearch

final class PaneLayoutTests: XCTestCase {
    func testAllTwelvePresetsTileTheAvailableSpace() {
        XCTAssertEqual(PaneLayout.allCases.count, 12)
        for layout in PaneLayout.allCases {
            for size in [CGSize(width: 640, height: 390), CGSize(width: 1400, height: 850)] {
                let geometry = PaneGeometry(tree: layout.tree, size: size)
                XCTAssertEqual(Set(geometry.panes.keys), Set(0..<layout.paneCount), layout.title)
                XCTAssertEqual(geometry.dividers.count, layout.paneCount - 1)
                let frames = Array(geometry.panes.values) + geometry.dividers.map(\.frame)
                var area: CGFloat = 0
                for (i, frame) in frames.enumerated() {
                    XCTAssertGreaterThan(frame.width, 0, layout.title)
                    XCTAssertGreaterThan(frame.height, 0, layout.title)
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.001)
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.001)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.001)
                    XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.001)
                    area += frame.width * frame.height
                    for other in frames.dropFirst(i + 1) {
                        let intersection = frame.intersection(other)
                        XCTAssertTrue(
                            intersection.isNull || intersection.width * intersection.height < 0.001)
                    }
                }
                XCTAssertEqual(area, size.width * size.height, accuracy: 0.01, layout.title)
            }
        }
    }

    func testAsymmetricPresetsHaveTheExpectedFullSpanPane() throws {
        let size = CGSize(width: 1000, height: 700)
        for (layout, index, axis) in [
            (PaneLayout.leftOneRightTwo, 0, Axis.horizontal),
            (.leftTwoRightOne, 2, .horizontal),
            (.topOneBottomTwo, 0, .vertical),
            (.topTwoBottomOne, 2, .vertical),
        ] {
            let frame = try XCTUnwrap(PaneGeometry(tree: layout.tree, size: size).panes[index])
            XCTAssertEqual(
                axis == .horizontal ? frame.height : frame.width,
                axis == .horizontal ? size.height : size.width)
        }
    }

    func testEveryDividerResizesAdjacentPanesAndClampsAtMinimum() {
        for layout in PaneLayout.allCases {
            let size = CGSize(width: 1800, height: 1200)
            let original = PaneGeometry(tree: layout.tree, size: size)
            for divider in original.dividers {
                for delta: CGFloat in [-10000, -40, 40, 10000] {
                    let weights = divider.weights(movingBy: delta)
                    XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 0.00001)
                    let result = PaneGeometry(
                        tree: layout.tree, size: size, weights: [divider.splitID: weights])
                    let resized = result.dividers.first { $0.id == divider.id }!
                    XCTAssertNotEqual(
                        resized.lengths[divider.index], divider.lengths[divider.index])
                    for i in resized.lengths.indices {
                        XCTAssertGreaterThanOrEqual(resized.lengths[i] + 0.001, resized.minimums[i])
                        if i != divider.index && i != divider.index + 1 {
                            XCTAssertEqual(resized.lengths[i], divider.lengths[i], accuracy: 0.001)
                        }
                    }
                }
            }
        }
    }

    func testInvalidSavedRatiosFallBackToEqualSizes() {
        let layout = PaneLayout.columns2
        let size = CGSize(width: 1000, height: 600)
        let expected = PaneGeometry(tree: layout.tree, size: size)
        for weights in [
            [Double.nan, 1], [0, 1], [-1, 2], [1], [Double.infinity, 1],
            [Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude],
        ] {
            let actual = PaneGeometry(tree: layout.tree, size: size, weights: ["root": weights])
            XCTAssertEqual(actual.panes, expected.panes)
        }
    }

    @MainActor func testSwitchingAllLayoutsRetainsPaneAndTabObjects() {
        let workspace = BrowserWorkspace(volumeLoader: { [] })
        workspace.setLayout(.grid)
        let panes = workspace.panes
        let models = panes.map(\.current)
        for (index, model) in models.enumerated() {
            model.location = URL(fileURLWithPath: "/fixture/\(index)")
            model.route = model.location.path
            model.selection = ["/fixture/\(index)/selected.txt"]
            model.scrollAnchor = "/fixture/\(index)/selected.txt"
            model.scrollOffset = Double(index * 7)
            model.backStack = [URL(fileURLWithPath: "/fixture/back-\(index)")]
        }
        for layout in PaneLayout.allCases + [.grid] {
            workspace.setLayout(layout)
            XCTAssertEqual(workspace.panes.map(\.id), panes.map(\.id))
            for index in models.indices {
                XCTAssertTrue(workspace.panes[index] === panes[index])
                XCTAssertTrue(workspace.panes[index].current === models[index])
                XCTAssertEqual(models[index].scrollOffset, Double(index * 7))
                XCTAssertEqual(models[index].selection, ["/fixture/\(index)/selected.txt"])
                XCTAssertEqual(models[index].backStack.count, 1)
            }
        }
    }

    @MainActor func testReducingLayoutKeepsActivePaneAndCannotHideFileOperations() {
        let workspace = BrowserWorkspace(volumeLoader: { [] })
        workspace.setLayout(.columns4)
        let last = workspace.panes[3]
        workspace.activatePane(last.id)
        workspace.panes[1].current.busy = true
        XCTAssertFalse(workspace.canSetLayout(.single))
        workspace.setLayout(.single)
        XCTAssertEqual(workspace.layout, .columns4)
        workspace.panes[1].current.busy = false
        workspace.setLayout(.single)
        XCTAssertEqual(workspace.layout, .single)
        XCTAssertTrue(workspace.panes[0] === last)
        XCTAssertTrue(workspace.activePane === last)
        let activeID = workspace.activePaneID
        workspace.activatePane(workspace.panes[1].id)
        XCTAssertEqual(workspace.activePaneID, activeID, "Hidden panes cannot take keyboard focus")
    }

    @MainActor func testPaneTabsAndActionsStayIndependent() {
        let workspace = BrowserWorkspace(volumeLoader: { [] })
        workspace.setLayout(.columns2)
        let left = workspace.panes[0], right = workspace.panes[1]
        workspace.activatePane(right.id)
        workspace.activePane.newTab(URL(fileURLWithPath: "/fixture/right"))
        XCTAssertEqual(left.tabs.count, 1)
        XCTAssertEqual(right.tabs.count, 2)
        XCTAssertTrue(workspace.current === right.current)
        right.closeTab(right.current.id)
        XCTAssertEqual(right.closedTabs.count, 1)
        XCTAssertTrue(left.closedTabs.isEmpty)
        right.reopenClosedTab()
        XCTAssertEqual(right.current.location.path, "/fixture/right")
    }

    @MainActor func testRestartRestoresVisibleAndHiddenPanesAndEveryLayoutRatio() throws {
        let suite = "FinderSearch.panes.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = BrowserWorkspace(volumeLoader: { [] }, sessionDefaults: defaults)
        workspace.setLayout(.grid)
        for (index, pane) in workspace.panes.enumerated() {
            pane.newTab(URL(fileURLWithPath: "/fixture/\(index)"))
            let model = pane.current
            model.query = "needle-\(index)"; model.scope = model.location.path
            model.fileType = "doc"; model.viewMode = .list; model.sort = .size
            model.ascending = false; model.showHidden = true
            model.selection = ["/fixture/\(index)/selected.txt"]
            model.scrollAnchor = model.selection.first; model.scrollOffset = Double(index + 3)
            model.iconSize = Double(64 + index)
            model.backStack = [URL(fileURLWithPath: "/fixture/back")]
            model.forwardStack = [URL(fileURLWithPath: "/fixture/forward")]
        }
        for layout in PaneLayout.allCases {
            workspace.layoutWeights[layout.rawValue] = ["root": [0.3, 0.7], "root.1": [0.6, 0.4]]
        }
        workspace.activatePane(workspace.panes[2].id)
        workspace.setLayout(.columns2)
        workspace.saveSession()
        let restored = BrowserWorkspace(volumeLoader: { [] }, sessionDefaults: defaults)
        XCTAssertEqual(restored.layout, .columns2)
        XCTAssertEqual(restored.activePaneID, workspace.activePaneID)
        XCTAssertEqual(restored.layoutWeights, workspace.layoutWeights)
        XCTAssertEqual(restored.panes.count, 4)
        for (expected, actual) in zip(workspace.panes, restored.panes) {
            XCTAssertEqual(expected.id, actual.id)
            XCTAssertEqual(expected.tabs.map(TabSession.init), actual.tabs.map(TabSession.init))
            XCTAssertEqual(TabSession(expected.current), TabSession(actual.current))
        }
        restored.setLayout(.grid)
        XCTAssertEqual(restored.panes.map(\.id), workspace.panes.map(\.id))
    }

    @MainActor func testLegacySessionMigratesWithoutDroppingTabs() throws {
        let suite = "FinderSearch.panes.legacy." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SearchModel(); model.location = URL(fileURLWithPath: "/fixture/legacy")
        model.route = model.location.path; model.viewMode = .gallery
        let old = WorkspaceSession(
            tabs: [TabSession(SearchModel()), TabSession(model)], selectedIndex: 1)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["tabs"] = (json["tabs"] as! [[String: Any]]).map { original in
            var tab = original
            for key in ["iconSize", "fileType", "backPaths", "forwardPaths"] {
                tab.removeValue(forKey: key)
            }
            return tab
        }
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: WorkspaceSession.key)
        let workspace = BrowserWorkspace(volumeLoader: { [] }, sessionDefaults: defaults)
        XCTAssertEqual(workspace.layout, .single)
        XCTAssertEqual(workspace.activePane.tabs.count, 2)
        XCTAssertEqual(workspace.current.location.path, "/fixture/legacy")
        XCTAssertEqual(workspace.current.viewMode, .gallery)
        XCTAssertEqual(workspace.current.iconSize, 64)
        workspace.saveSession()
        XCTAssertNotNil(defaults.data(forKey: PaneWorkspaceSession.key))
    }

    @MainActor func testVisibleAndHiddenPaneEditsAutosaveAfterAddingTabs() async throws {
        let suite = "FinderSearch.panes.autosave." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = BrowserWorkspace(volumeLoader: { [] }, sessionDefaults: defaults)
        workspace.setLayout(.columns2)
        let hidden = workspace.panes[1]
        workspace.setLayout(.single)
        hidden.newTab(URL(fileURLWithPath: "/fixture/hidden"))
        hidden.current.viewMode = .gallery
        hidden.current.scrollAnchor = "/fixture/hidden/photo.jpg"
        hidden.current.scrollOffset = 9
        workspace.layoutWeights[PaneLayout.columns2.rawValue] = ["root": [0.35, 0.65]]
        try await Task.sleep(for: .milliseconds(450))
        let state = try JSONDecoder().decode(
            PaneWorkspaceSession.self,
            from: XCTUnwrap(defaults.data(forKey: PaneWorkspaceSession.key)))
        XCTAssertEqual(state.panes[1].selectedIndex, 1)
        XCTAssertEqual(state.panes[1].tabs[1].view, "gallery")
        XCTAssertEqual(state.panes[1].tabs[1].scrollOffset, 9)
        XCTAssertEqual(state.weights[PaneLayout.columns2.rawValue]?["root"], [0.35, 0.65])
    }

    @MainActor func testIconBoundsUpdateAcrossSplitsWithoutMixingPaneSelections() throws {
        let workspace = BrowserWorkspace(volumeLoader: { [] })
        workspace.panes = (0..<4).map { index in
            let model = SearchModel()
            model.viewMode = .icons
            model.hits = (0..<18).map {
                Hit(
                    path: "/fixture/Pane-\(index)/Document-\($0).txt", kind: "file",
                    size: 0, mtime: 0, score: 0, metadataPending: true)
            }
            model.selection = [model.hits[0].path]
            return BrowserPane(tabs: [model])
        }
        workspace.activePaneID = workspace.panes[0].id
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PaneTestWorkspace(workspace: workspace))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func overlays(_ view: NSView) -> [MarqueeSelectionView] {
            if let overlay = view as? MarqueeSelectionView { return [overlay] }
            return view.subviews.flatMap(overlays)
        }
        for layout in [PaneLayout.columns2, .columns4, .leftOneRightTwo, .single, .grid] {
            workspace.setLayout(layout)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let visible = overlays(try XCTUnwrap(window.contentView)).filter(\.isInteractionEnabled)
            XCTAssertEqual(visible.count, layout.paneCount)
            for overlay in visible {
                XCTAssertGreaterThan(overlay.itemFrames.count, 1, layout.title)
                let folders = Set(
                    overlay.itemFrames.keys.map {
                        URL(fileURLWithPath: $0).deletingLastPathComponent().path
                    })
                XCTAssertEqual(folders.count, 1, "Bounds must belong to one pane")
                for frame in overlay.itemFrames.values {
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertLessThanOrEqual(frame.maxX, overlay.bounds.width + 1, layout.title)
                }
            }
            for pane in workspace.panes {
                XCTAssertEqual(pane.current.selection, [pane.current.hits[0].path])
            }
        }
    }

    @MainActor func testNativeFileViewsSurviveEveryLayoutAtNarrowAndWideSizes() throws {
        let workspace = BrowserWorkspace(volumeLoader: { [] })
        workspace.panes = (0..<4).map { _ in BrowserPane() }
        workspace.activePaneID = workspace.panes[0].id
        workspace.layout = .grid
        for (index, pane) in workspace.panes.enumerated() {
            let model = pane.current
            model.location = URL(fileURLWithPath: "/fixture/Folder-\(index + 1)")
            model.route = model.location.path; model.viewMode = .list
            model.hits = (0..<150).map {
                Hit(
                    path: model.location.path + String(format: "/Document-%03d.txt", $0),
                    kind: "file", size: 1024, mtime: 0, score: 0, metadataPending: true)
            }
            model.selection = [model.hits[30].path]
            model.scrollAnchor = model.hits[30].path; model.scrollOffset = 7
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PaneTestWorkspace(workspace: workspace))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func tables(_ view: NSView) -> [BrowserTable] {
            if let table = view as? BrowserTable { return [table] }
            return view.subviews.flatMap(tables)
        }
        let content = try XCTUnwrap(window.contentView)
        let original = Set(tables(content).map(ObjectIdentifier.init))
        XCTAssertEqual(original.count, 4)
        for width in [1400, 850] {
            window.setContentSize(NSSize(width: width, height: width == 850 ? 470 : 850))
            for layout in PaneLayout.allCases {
                workspace.setLayout(layout)
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                XCTAssertEqual(
                    Set(tables(content).map(ObjectIdentifier.init)), original, layout.title)
                XCTAssertEqual(
                    tables(content).filter { $0.marquee.isInteractionEnabled }.count,
                    layout.paneCount)
                for pane in workspace.panes {
                    XCTAssertEqual(
                        pane.current.selection, [pane.current.hits[30].path], layout.title)
                    XCTAssertEqual(
                        pane.current.scrollAnchor, pane.current.hits[30].path, layout.title)
                }
                // Optional local evidence uses authored fixture names, never user files.
                if let directory = ProcessInfo.processInfo.environment[
                    "FINDERSEARCH_TEST_SCREENSHOTS"],
                    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    let url = URL(fileURLWithPath: directory).appendingPathComponent(
                        "\(layout.rawValue)-\(width).png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}

private struct PaneTestWorkspace: View {
    @ObservedObject var workspace: BrowserWorkspace
    var body: some View { BrowserView(workspace: workspace, model: workspace.current) }
}
