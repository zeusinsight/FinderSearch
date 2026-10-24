import XCTest
@testable import FinderSearch

final class SearchHistoryTests: XCTestCase {
    @MainActor func testDisabledHistoryNeitherRecordsNorLosesExistingEntries() throws {
        let name = "SearchHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = SearchHistory(defaults: defaults)
        XCTAssertTrue(history.enabled)
        history.record("秦前坤")
        history.enabled = false
        history.record("不应记录")
        let restored = SearchHistory(defaults: defaults)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.queries, ["秦前坤"])
        restored.enabled = true
        restored.record("采购文件")
        XCTAssertTrue(SearchHistory(defaults: defaults).enabled)
        XCTAssertEqual(restored.queries, ["采购文件", "秦前坤"])
    }

    @MainActor func testRecentSearchesPersistWithNewestFirstAndNoDuplicates() throws {
        let name = "SearchHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = SearchHistory(defaults: defaults)
        history.record("秦前坤")
        history.record("采购文件")
        history.record("  秦前坤\n")
        history.record(" \n")
        XCTAssertEqual(history.queries, ["秦前坤", "采购文件"])
        XCTAssertEqual(SearchHistory(defaults: defaults).queries, history.queries)
    }

    @MainActor func testHistoryIsBoundedAndClearPersists() throws {
        let name = "SearchHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let history = SearchHistory(defaults: defaults)
        for index in 0..<25 { history.record("query \(index)") }
        XCTAssertEqual(history.queries.count, 20)
        XCTAssertEqual(history.queries.first, "query 24")
        XCTAssertEqual(history.queries.last, "query 5")
        history.clear()
        XCTAssertTrue(history.queries.isEmpty)
        XCTAssertTrue(SearchHistory(defaults: defaults).queries.isEmpty)
    }
}
