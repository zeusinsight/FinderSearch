import AppKit
import SwiftUI
import XCTest
@testable import FinderSearch

final class MarqueeSelectionTests: XCTestCase {
    func testRectangleWorksInEveryDirectionAndModifierSelectionIsReversible() {
        let anchor = CGPoint(x: 100, y: 100)
        let plain = MarqueeSelection(anchor: anchor, original: ["old"], modifiers: [])
        XCTAssertEqual(plain.rectangle(to: .zero), CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(plain.selection(intersecting: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(plain.selection(intersecting: ["a"]), ["a"])
        let adding = MarqueeSelection(anchor: anchor, original: ["old"], modifiers: .shift)
        XCTAssertEqual(adding.selection(intersecting: ["a"]), ["old", "a"])
        let toggling = MarqueeSelection(anchor: anchor, original: ["old"], modifiers: .command)
        XCTAssertEqual(toggling.selection(intersecting: ["old", "a"]), ["a"])
        XCTAssertEqual(toggling.selection(intersecting: []), ["old"])
    }

    @MainActor private func mouse(
        _ type: NSEvent.EventType, at point: CGPoint, in view: NSView,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: try XCTUnwrap(view.window).windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor func testBackgroundDragSelectsShrinksCancelsAndLeavesFileDragsAlone() throws {
        let model = SearchModel()
        let view = MarqueeSelectionView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.stop(); window.orderOut(nil) }
        view.configure(model: model, identity: "test")
        view.itemFrames = [
            "a": CGRect(x: 20, y: 20, width: 80, height: 80),
            "b": CGRect(x: 120, y: 20, width: 80, height: 80),
        ]
        model.selection = ["original"]
        XCTAssertNotNil(view.handle(try mouse(.leftMouseDown, at: CGPoint(x: 30, y: 30), in: view)))
        XCTAssertFalse(model.marqueeSelecting)
        XCTAssertNil(view.handle(try mouse(.leftMouseDown, at: .zero, in: view)))
        XCTAssertNil(
            view.handle(try mouse(.leftMouseDragged, at: CGPoint(x: 210, y: 110), in: view)))
        XCTAssertEqual(model.selection, ["a", "b"])
        XCTAssertTrue(model.marqueeSelecting)
        _ = view.handle(try mouse(.leftMouseDragged, at: CGPoint(x: 110, y: 110), in: view))
        XCTAssertEqual(model.selection, ["a"])
        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertNil(view.handle(escape))
        XCTAssertEqual(model.selection, ["original"])
        XCTAssertFalse(model.marqueeSelecting)
        _ = view.handle(try mouse(.leftMouseDown, at: .zero, in: view, modifiers: .shift))
        _ = view.handle(try mouse(.leftMouseDragged, at: CGPoint(x: 110, y: 110), in: view))
        _ = view.handle(try mouse(.leftMouseUp, at: CGPoint(x: 110, y: 110), in: view))
        XCTAssertEqual(model.selection, ["original", "a"])
        XCTAssertFalse(model.marqueeSelecting)
        // A background click clears selection, without starting a file drag.
        _ = view.handle(try mouse(.leftMouseDown, at: .zero, in: view))
        _ = view.handle(try mouse(.leftMouseUp, at: .zero, in: view))
        XCTAssertTrue(model.selection.isEmpty)
    }

    @MainActor func testDraggingPastViewportAutoscrollsAndRouteChangeEndsGesture() throws {
        let model = SearchModel()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        let view = MarqueeSelectionView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        scroll.documentView = view
        let window = NSWindow(
            contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { view.stop(); window.orderOut(nil) }
        scroll.layoutSubtreeIfNeeded()
        view.configure(model: model, identity: "before")
        view.itemFrames = ["a": CGRect(x: 20, y: 20, width: 80, height: 80)]
        _ = view.handle(try mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: view))
        _ = view.handle(try mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 180), in: view))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertTrue(model.marqueeSelecting)
        view.configure(model: model, identity: "after")
        XCTAssertFalse(model.marqueeSelecting)
    }

    @MainActor func testListBackgroundDragSelectsRowsAndPreservesNativeRowDrag() throws {
        let model = SearchModel()
        model.hits = (0..<6).map {
            Hit(
                path: "/fixture/row-\($0).txt", kind: "file", size: 0, mtime: 0,
                score: 0, metadataPending: true)
        }
        let list = FileList(model: model, focusFiles: {}, newTab: { _ in })
        let coordinator = list.makeCoordinator()
        let scroll = list.makeView(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        coordinator.update()
        scroll.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(scroll.documentView as? BrowserTable)
        let overlay = table.marquee
        XCTAssertNotNil(
            overlay.handle(try mouse(.leftMouseDown, at: CGPoint(x: 20, y: 12), in: overlay)))
        let start = CGPoint(x: 20, y: 200)
        XCTAssertTrue(overlay.visibleRect.contains(start))
        XCTAssertNil(overlay.handle(try mouse(.leftMouseDown, at: start, in: overlay)))
        _ = overlay.handle(try mouse(.leftMouseDragged, at: CGPoint(x: 250, y: 80), in: overlay))
        XCTAssertEqual(model.selection, Set(model.hits.suffix(3).map(\.path)))
        _ = overlay.handle(try mouse(.leftMouseUp, at: CGPoint(x: 250, y: 80), in: overlay))
        XCTAssertFalse(model.marqueeSelecting)
    }

    @MainActor func testIconGridPublishesBoundsAndSelectsVisibleFiles() throws {
        let workspace = BrowserWorkspace(volumeLoader: { [] }, volumeEjector: { _ in })
        let model = workspace.current
        model.viewMode = .icons
        model.hits = (1...18).map {
            Hit(
                path: "/fixture/Document-\($0).txt", kind: "file", size: 0, mtime: 0,
                score: 0, metadataPending: true)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1050, height: 680), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: BrowserView(workspace: workspace, model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        func find(_ view: NSView) -> MarqueeSelectionView? {
            if let found = view as? MarqueeSelectionView { return found }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let overlay = try XCTUnwrap(find(try XCTUnwrap(window.contentView)))
        XCTAssertGreaterThan(overlay.itemFrames.count, 3)
        let frames = overlay.itemFrames.values.sorted {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }
        let end = CGPoint(x: frames[2].maxX + 2, y: frames[2].maxY + 2)
        _ = overlay.handle(try mouse(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: overlay))
        _ = overlay.handle(try mouse(.leftMouseDragged, at: end, in: overlay))
        XCTAssertGreaterThanOrEqual(model.selection.count, 3)
        XCTAssertLessThan(model.selection.count, model.hits.count)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(model.marqueeSelecting)
        _ = overlay.handle(try mouse(.leftMouseUp, at: end, in: overlay))
        XCTAssertFalse(model.marqueeSelecting)
    }
}
