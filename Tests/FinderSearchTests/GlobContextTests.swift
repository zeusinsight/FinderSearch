import XCTest
@testable import FinderSearch

final class GlobContextTests: XCTestCase {
    @MainActor func testRelativeGlobUsesBrowsedFolderWithOrWithoutScope() async throws {
        for scoped in [false, true] {
            let requested = expectation(description: "Search sent")
            let engine = GlobContextEngine(requested: requested)
            let model = SearchModel(engine: engine, searchDebounce: .seconds(60))
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            model.location = folder
            model.route = folder.path
            if scoped { model.scope = folder.path }
            model.query = "src/*.rs"
            model.submitSearch()
            await fulfillment(of: [requested], timeout: 2)
            let context = await engine.context
            XCTAssertEqual(context?.cwd, folder.path)
            XCTAssertEqual(context?.scope, scoped ? folder.path : nil)
            XCTAssertEqual(context?.query, "src/*.rs")
        }
    }
}

private actor GlobContextEngine: SearchService {
    let requested: XCTestExpectation
    var context: (cwd: String?, scope: String?, query: String?)?
    init(requested: XCTestExpectation) { self.requested = requested }
    func request(_ fields: [String: Any]) async throws -> Reply {
        context = (fields["cwd"] as? String, fields["in"] as? String, fields["q"] as? String)
        requested.fulfill()
        return Reply(
            ok: true, error: nil, hits: [], took_us: 1, entries: nil, full_disk_access: nil)
    }
}
