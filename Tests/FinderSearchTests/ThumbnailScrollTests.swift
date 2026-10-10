import XCTest
import AppKit
import Combine
import SwiftUI
@testable import FinderSearch

final class ThumbnailScrollTests: XCTestCase {
    private func makeImageFixtures(_ count: Int) throws -> (URL, [Hit]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderSearch-thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var hits: [Hit] = []
        for index in 0..<count {
            let image = NSImage(size: NSSize(width: 640, height: 480), flipped: false) { rect in
                NSColor(hue: CGFloat(index % 37) / 37, saturation: 0.7, brightness: 0.9, alpha: 1)
                    .setFill()
                rect.fill()
                return true
            }
            var rect = NSRect(origin: .zero, size: image.size)
            let cgImage = try XCTUnwrap(
                image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let url = root.appendingPathComponent(String(format: "image-%04d.png", index))
            try XCTUnwrap(
                NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            )
            .write(to: url)
            hits.append(Hit(path: url.path, kind: "file", size: 1, mtime: 1, score: 0))
        }
        return (root, hits)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
                (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0)
            {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    /// IconServices and ImageIO images decode lazily at first draw; grid cells must
    /// receive plain bitmaps so fast scrolling never rasterizes on the main thread.
    func testIconsAndThumbnailsArePreDecodedBitmaps() throws {
        let (root, hits) = try makeImageFixtures(1)
        defer { try? FileManager.default.removeItem(at: root) }
        for image in [
            FileIcons.shared.icon(hits[0]), FileIcons.shared.placeholder(hits[0]),
            ImageRasterizer.bitmap(NSWorkspace.shared.icon(for: .png)),
        ] {
            let rep = try XCTUnwrap(image.representations.first)
            XCTAssertEqual(image.representations.count, 1)
            XCTAssertFalse(String(describing: type(of: rep)).contains("ISIcon"))
            XCTAssertLessThanOrEqual(rep.pixelsWide, ImageRasterizer.iconPixels)
            XCTAssertGreaterThan(rep.pixelsWide, 0)
        }
        let wide = try XCTUnwrap(
            CGContext(
                data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let decoded = try XCTUnwrap(ImageRasterizer.decode(wide, maxPixels: 256))
        XCTAssertEqual(decoded.width, 256); XCTAssertEqual(decoded.height, 128)
        XCTAssertEqual(
            ImageRasterizer.aspectSize(decoded, points: 128), NSSize(width: 128, height: 64))
    }

    func testRowIconsUseSmallBitmapsWithoutReplacingPreviewCache() async throws {
        let (root, hits) = try makeImageFixtures(1)
        defer { try? FileManager.default.removeItem(at: root) }
        let hit = hits[0]
        let rowResult = await FileIcons.shared.load(hit, size: .row)
        let previewResult = await FileIcons.shared.load(hit, size: .preview)
        let row = try XCTUnwrap(rowResult)
        let preview = try XCTUnwrap(previewResult)
        let repeatedRow = await FileIcons.shared.load(hit, size: .row)
        let repeatedPreview = await FileIcons.shared.load(hit, size: .preview)
        XCTAssertTrue(row === repeatedRow)
        XCTAssertTrue(preview === repeatedPreview)
        XCTAssertFalse(row === preview)
        XCTAssertLessThanOrEqual(try XCTUnwrap(row.representations.first).pixelsWide, 32)
        XCTAssertGreaterThan(try XCTUnwrap(preview.representations.first).pixelsWide, 32)
        XCTAssertLessThan(ImageRasterizer.cost(row), ImageRasterizer.cost(preview))
        let smallPlaceholder = FileIcons.shared.placeholder(hit, size: .row)
        let largePlaceholder = FileIcons.shared.placeholder(hit, size: .preview)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(smallPlaceholder.representations.first).pixelsWide, 32)
        XCTAssertGreaterThan(try XCTUnwrap(largePlaceholder.representations.first).pixelsWide, 32)
        XCTAssertFalse(smallPlaceholder === largePlaceholder)
    }

    @MainActor func testFastIconGridScrollWithThumbnails() throws {
        let (root, hits) = try makeImageFixtures(400)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = BrowserWorkspace(volumeLoader: { [] }, volumeEjector: { _ in })
        let model = workspace.current
        model.viewMode = .icons
        model.hits = hits
        var changes = 0
        let counter = model.objectWillChange.sink { changes += 1 }
        defer { counter.cancel() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: BrowserView(workspace: workspace, model: model))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let scroll = try XCTUnwrap(scrollView(in: window.contentView!))
        changes = 0
        var frames: [Double] = []
        for step in 1...200 {
            let start = Date()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: Double(step) * 60))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            window.contentView!.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            frames.append(Date().timeIntervalSince(start) * 1000)
        }
        let sorted = frames.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[sorted.count * 95 / 100]
        XCTAssertLessThan(p95, 50, "Fast thumbnail scrolling must stay responsive")
        print(
            "PERFORMANCE thumbnail icon scroll: p50 \(p50) ms, p95 \(p95) ms, max \(sorted.last!) ms, model changes \(changes)"
        )
    }
}
