import XCTest
@testable import FinderSearch

final class SearchSchedulingTests: XCTestCase {
    @MainActor func testContentSearchUsesLiteralTextAndContinuesPages() async throws {
        let requested = expectation(description: "Both content pages sent")
        requested.expectedFulfillmentCount = 2
        let engine = ContentSearchEngine(requested: requested)
        let model = SearchModel(engine: engine, searchDebounce: .seconds(60))
        model.searchContents = true
        model.query = "秦前坤.*"
        model.submitSearch()
        await fulfillment(of: [requested], timeout: 1)
        try await Task.sleep(for: .milliseconds(100))
        let patterns = await engine.patterns
        let cursors = await engine.cursors
        XCTAssertEqual(patterns, ["秦前坤.*", "秦前坤.*"])
        XCTAssertEqual(cursors, [nil, 12])
        XCTAssertEqual(model.hits.map(\.name), ["first.docx", "second.xlsx"])
        XCTAssertEqual(model.hits.first?.contentSnippet, "秦前坤.* in a paragraph")
        XCTAssertEqual(model.hits.first?.size, 1024)
        XCTAssertFalse(model.searching)
    }

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

private actor ContentSearchEngine: SearchService {
    let requested: XCTestExpectation
    var patterns: [String] = []
    var cursors: [UInt64?] = []
    init(requested: XCTestExpectation) { self.requested = requested }
    func request(_ fields: [String: Any]) async throws -> Reply {
        XCTAssertEqual(fields["op"] as? String, "grep")
        XCTAssertEqual(fields["mode"] as? String, "literal")
        XCTAssertEqual(fields["q"] as? String, "")
        patterns.append(fields["pattern"] as? String ?? "")
        cursors.append(fields["cursor"] as? UInt64)
        let first = patterns.count == 1
        let json = first
            ? #"{"ok":true,"files":[{"path":"/fixture/first.docx","size":1024,"mtime":1,"matches":[{"text":"秦前坤.* in a paragraph"}]}],"complete":false,"next":12}"#
            : #"{"ok":true,"files":[{"path":"/fixture/first.docx","matches":[]},{"path":"/fixture/second.xlsx","size":2048,"mtime":1,"matches":[{"text":"秦前坤.* in a cell"}]}],"complete":true}"#
        requested.fulfill()
        return try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
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
