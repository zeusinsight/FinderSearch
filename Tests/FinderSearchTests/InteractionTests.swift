import XCTest
@testable import FinderSearch

/// Interaction corrections: search scope lifecycle, timing feedback, and the
/// grid formula shared by the icon view and the loading skeleton.
final class InteractionTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "FinderSearch-interaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    @MainActor func settle(_ model: SearchModel) async throws {
        for _ in 0..<250 {
            if !model.searching, !model.loading, !model.busy, !model.sorting { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor func testScopeClearsWhenQueryClears() async throws {
        let model = SearchModel(engine: ReplyStub()); model.navigate(folder)
        try await settle(model)
        model.query = "alpha"
        try await settle(model)
        model.scope = folder.path
        XCTAssertEqual(model.scope, folder.path)
        model.query = ""
        XCTAssertEqual(model.scope, "")
    }

    @MainActor func testVirtualRouteSearchStaysInHome() async throws {
        let engine = ReplyStub()
        let model = SearchModel(engine: engine)
        model.sidebar("recents")
        try await settle(model)
        model.query = "invoice"
        try await settle(model)
        let last = await engine.requests.last ?? [:]
        XCTAssertEqual(last["in"] as? String, NSHomeDirectory())
        XCTAssertEqual(last["q"] as? String, "invoice")
    }

    @MainActor func testElapsedResetsWhenSearchStarts() async throws {
        let model = SearchModel(engine: ReplyStub()); model.navigate(folder)
        try await settle(model)
        model.elapsed = 9
        model.query = "needle"
        XCTAssertEqual(model.elapsed, 0)
    }

    func testGridMetricsMatchAdaptiveGridPacking() {
        for width in stride(from: 300.0, through: 1600.0, by: 7) {
            for iconSize in [40.0, 64.0, 96.0] {
                let count = GridMetrics.columns(width: width, iconSize: iconSize)
                let available = width - 36
                let cell = iconSize + 55, spacing = 14.0
                XCTAssertGreaterThanOrEqual(count, 1)
                XCTAssertLessThanOrEqual(
                    Double(count) * cell + Double(count - 1) * spacing, available)
                XCTAssertGreaterThan(Double(count + 1) * cell + Double(count) * spacing, available)
            }
        }
    }
}

private actor ReplyStub: SearchService {
    var requests: [[String: Any]] = []
    func request(_ fields: [String: Any]) async throws -> Reply {
        requests.append(fields)
        return Reply(
            ok: true, error: nil, hits: [], took_us: 1, entries: nil, full_disk_access: nil)
    }
}
