import XCTest
@testable import FinderSearch

final class SearchSchedulingTests: XCTestCase {
    @MainActor func testRapidEditsSendOnlyLatestQuery() async throws {
        let requested = expectation(description: "Latest query sent")
        let engine = ScheduledSearchEngine(requested: requested)
        let model = SearchModel(engine: engine)
        model.query = "a"
        model.query = "ab"
        model.query = "abc"
        await fulfillment(of: [requested], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        let queries = await engine.queries
        XCTAssertEqual(queries, ["abc"])
    }

    @MainActor func testSubmitBypassesDebounceWithoutDuplicatingInFlightRequest() async throws {
        let requested = expectation(description: "Submitted without waiting for debounce")
        let engine = ScheduledSearchEngine(requested: requested, holdFirst: true)
        let model = SearchModel(engine: engine, searchDebounce: .seconds(60))
        model.query = "report"
        model.submitSearch()
        await fulfillment(of: [requested], timeout: 1)
        model.submitSearch()
        await engine.releaseFirst()
        try await Task.sleep(for: .milliseconds(100))
        let queries = await engine.queries
        XCTAssertEqual(queries, ["report"])
        XCTAssertEqual(model.hits.first?.name, "report")
        XCTAssertFalse(model.searching)
    }

    @MainActor func testObsoleteReplyCannotReplaceSubmittedResults() async throws {
        let requested = expectation(description: "Both requests sent")
        requested.expectedFulfillmentCount = 2
        let engine = ScheduledSearchEngine(requested: requested, holdFirst: true)
        let model = SearchModel(engine: engine, searchDebounce: .seconds(60))
        model.query = "old"
        model.submitSearch()
        // Wait for the old request to enter the engine before superseding it.
        for _ in 0..<200 {
            if await engine.queries.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let initialQueries = await engine.queries
        XCTAssertEqual(initialQueries, ["old"])
        model.query = "new"
        model.submitSearch()
        await fulfillment(of: [requested], timeout: 1)
        await engine.releaseFirst()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.hits.first?.name, "new")
        XCTAssertFalse(model.searching)
    }
}

private actor ScheduledSearchEngine: SearchService {
    let requested: XCTestExpectation
    let holdFirst: Bool
    var queries: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(requested: XCTestExpectation, holdFirst: Bool = false) {
        self.requested = requested
        self.holdFirst = holdFirst
    }

    func request(_ fields: [String: Any]) async throws -> Reply {
        let query = fields["q"] as? String ?? ""
        queries.append(query)
        requested.fulfill()
        if holdFirst && queries.count == 1 {
            // Deliberately ignore cancellation to exercise stale-reply protection.
            await withCheckedContinuation { continuation = $0 }
        }
        return Reply(
            ok: true, error: nil,
            hits: [Hit(path: "/fixture/" + query, kind: "file", size: 1, mtime: 1, score: 1)],
            took_us: 1, entries: nil, full_disk_access: nil)
    }

    func releaseFirst() {
        continuation?.resume()
        continuation = nil
    }
}
