import XCTest
import SwiftUI
@testable import FinderSearch

final class DocumentSearchLayoutTests: XCTestCase {
    @MainActor func testSettingsLoadsWithoutWritingAndFitsItsWindow() throws {
        let service = SettingsReadOnlyEngine()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 176),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DocumentSettingsView(engine: service))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        try capture(window, name: "document-settings")
    }

    @MainActor func testContentSearchBarFitsNarrowAndWideWindows() throws {
        let workspace = BrowserWorkspace(volumeLoader: { [] })
        let model = SearchModel(engine: LayoutSearchEngine())
        workspace.tabs = [model]; workspace.selectedTab = model.id
        let previousViewMode = model.viewMode
        defer { model.viewMode = previousViewMode }
        model.viewMode = .icons
        model.searchContents = true
        model.query = "秦前坤"
        model.hits = [Hit(path: "/fixture/采购文件.docx", kind: "file", size: 1024, mtime: 1, score: 0,
            contentSnippet: "采购联系人：秦前坤")]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: BrowserView(workspace: workspace, model: model))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        for width in [1050, 850] {
            window.setContentSize(NSSize(width: width, height: 620))
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            try capture(window, name: "document-search-\(width)")
        }
    }

    @MainActor private func capture(_ window: NSWindow, name: String) throws {
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["FINDERSEARCH_TEST_SCREENSHOTS"] {
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}

private actor SettingsReadOnlyEngine: SearchService {
    func request(_ fields: [String: Any]) async throws -> Reply {
        XCTAssertEqual(fields["op"] as? String, "settings")
        XCTAssertNil(fields["document_indexing"], "Opening Settings must not write the preference")
        return try JSONDecoder().decode(Reply.self, from: Data(#"{"ok":true,"document_indexing":false}"#.utf8))
    }
}

private actor LayoutSearchEngine: SearchService {
    func request(_ fields: [String: Any]) async throws -> Reply {
        return try JSONDecoder().decode(Reply.self, from: Data(#"{"ok":true,"files":[{"path":"/fixture/采购文件.docx","size":1024,"mtime":1,"matches":[{"text":"采购联系人：秦前坤"}]}],"complete":true,"document_indexing":false}"#.utf8))
    }
}
