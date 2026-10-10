import XCTest
@testable import FinderSearch

/// Production cache correctness and comparison against full sorting.
final class OrderingReuseTests: XCTestCase {
    private func hit(_ name: String, size: UInt64 = 1) -> Hit {
        Hit(path: "/fixture/" + name, kind: "file", size: size, mtime: size, score: 0)
    }

    func testFallbacksMatchFullSort() throws {
        let initial = [hit("file-10"), hit("file-2"), hit(".hidden"), hit("é")]
        let variants = [
            initial, Array(initial.reversed()), Array(initial.dropLast()),
            initial + [hit("new")], [hit("renamed")] + Array(initial.dropFirst()),
            [hit("file-10", size: 90)] + Array(initial.dropFirst()),
            [hit("file-2", size: 8), hit("file-2", size: 3), hit("file-10")],
        ]
        for originalSort in FileSort.allCases {
            for hidden in [false, true] {
                for searching in [false, true] {
                    let previous = try FileOrdering.cached(
                        initial, sort: originalSort,
                        ascending: true, showHidden: hidden, isSearch: searching)
                    for variant in variants {
                        for sort in FileSort.allCases {
                            for ascending in [false, true] {
                                let actual = try FileOrdering.cached(
                                    variant, sort: sort,
                                    ascending: ascending, showHidden: !hidden,
                                    isSearch: searching, previous: previous)
                                let expected = try FileOrdering.sorted(
                                    variant, sort: sort,
                                    ascending: ascending, showHidden: !hidden, isSearch: searching)
                                XCTAssertEqual(actual.ordered, expected)
                                let matchingVisibility = try FileOrdering.cached(
                                    variant, sort: sort,
                                    ascending: ascending, showHidden: hidden,
                                    isSearch: searching, previous: previous)
                                XCTAssertEqual(
                                    matchingVisibility.ordered,
                                    try FileOrdering.sorted(
                                        variant, sort: sort, ascending: ascending,
                                        showHidden: hidden, isSearch: searching))
                            }
                        }
                    }
                }
            }
        }
        let duplicates = [hit("same", size: 1), hit("same", size: 2), hit("z")]
        let previous = try FileOrdering.cached(
            duplicates, sort: .name, ascending: true,
            showHidden: true, isSearch: false)
        XCTAssertEqual(
            try FileOrdering.cached(
                duplicates, sort: .name, ascending: false,
                showHidden: true, isSearch: false, previous: previous
            ).ordered,
            try FileOrdering.sorted(
                duplicates, sort: .name, ascending: false,
                showHidden: true, isSearch: false))
    }

    @MainActor func testModelRefreshAndRapidSortChanges() async throws {
        let model = SearchModel()
        model.hits = (0..<100).map { hit("file-\($0)", size: UInt64($0)) }
        func settle() async throws {
            for _ in 0..<2000 {
                if !model.sorting { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("Sort did not settle")
        }
        try await settle()
        model.ascending = false
        model.hits = model.hits.reversed().map {
            Hit(path: $0.path, kind: $0.kind, size: 100 - $0.size, mtime: 0, score: 0)
        }
        model.sort = .size
        model.ascending = true
        model.sort = .name
        model.ascending = false
        try await settle()
        XCTAssertEqual(
            model.sortedHits,
            try FileOrdering.sorted(
                model.hits, sort: .name,
                ascending: false, showHidden: false, isSearch: false))
        model.sort = .size
        try await settle()
        XCTAssertEqual(
            model.sortedHits,
            try FileOrdering.sorted(
                model.hits, sort: .size,
                ascending: false, showHidden: false, isSearch: false))
    }

    @MainActor func testPreviewDoesNotMasqueradeAsRequestedOrder() async throws {
        let initial = [hit("a", size: 10), hit("z", size: 1)]
        let model = SearchModel(
            folderLoader: { _, _ in
                try await Task.sleep(for: .milliseconds(30))
                return initial
            },
            folderPreviewLoader: { _, _ in
                initial.map {
                    Hit(
                        path: $0.path, kind: "file", size: 0, mtime: 0, score: 0,
                        metadataPending: true)
                }
            })
        model.navigate(URL(fileURLWithPath: "/tmp/ordering-" + UUID().uuidString))
        model.sort = .size
        model.ascending = true
        for _ in 0..<2000 {
            if !model.loading && !model.sorting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.sortedHits.map(\.name), ["z", "a"])
        XCTAssertEqual(model.sortedHits.map(\.size), [1, 10])
    }

    func testCancellationAndLocaleInvalidation() async throws {
        let items = [hit("z"), hit("a")]
        let stale = FileOrdering.Cache(
            source: items, ordered: items, sort: .name,
            ascending: true, showHidden: true, isSearch: false, locale: "stale-locale")
        let valid = try FileOrdering.cached(
            items, sort: .name, ascending: true,
            showHidden: true, isSearch: false, previous: stale)
        XCTAssertEqual(valid.ordered.map(\.name), ["a", "z"])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileOrdering.cached(
                items, sort: .name, ascending: false,
                showHidden: true, isSearch: false, previous: valid)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled ordering must throw")
        } catch is CancellationError {}
    }

    func testSortDirectionOpportunity() throws {
        let hits = (0..<30000).map { i in
            Hit(
                path: "/fixture/file-\((i * 7919) % 30000).txt", kind: "file",
                size: UInt64(i % 9), mtime: UInt64(i % 17), score: 0)
        }
        for sort: FileSort in [.name, .size, .modified, .kind] {
            let ascending = try FileOrdering.cached(
                hits, sort: sort, ascending: true,
                showHidden: false, isSearch: false)
            var full: [Double] = [], reversed: [Double] = []
            func millis(_ duration: Duration) -> Double {
                Double(duration.components.seconds) * 1000
                    + Double(duration.components.attoseconds) / 1e15
            }
            for round in 0..<7 {
                var outputs: [[Hit]] = [[], []]
                for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    let start = ContinuousClock.now
                    let result =
                        try method == 0
                        ? FileOrdering.sorted(
                            hits, sort: sort, ascending: false,
                            showHidden: false, isSearch: false)
                        : FileOrdering.cached(
                            hits, sort: sort, ascending: false, showHidden: false, isSearch: false,
                            previous: ascending
                        ).ordered
                    let elapsed = millis(start.duration(to: .now))
                    outputs[method] = result
                    if round > 0 {
                        if method == 0 { full.append(elapsed) } else { reversed.append(elapsed) }
                    }
                }
                XCTAssertEqual(outputs[0], outputs[1])
            }
            let before = full.sorted()[full.count / 2],
                after = reversed.sorted()[reversed.count / 2]
            print(
                "DIRECTION PRODUCTION \(sort) / 30,000 unique paths: \(before) → \(after) ms (\(before / after)x)"
            )
        }
    }

    func testMetadataRefreshOrderingOpportunity() throws {
        let stems = ["file", "File", "é", "é", "報告", "😀", "a_b", "a-b", ".hidden"]
        let initial = (0..<30000).map { i in
            Hit(
                path: "/fixture/\(stems[i % stems.count])-\(i).txt", kind: "file",
                size: 0, mtime: 0, score: 0, metadataPending: true)
        }
        let previous = try FileOrdering.cached(
            initial, sort: .name, ascending: true,
            showHidden: true, isSearch: false)
        let refreshed = initial.reversed().enumerated().map { i, hit in
            Hit(path: hit.path, kind: "file", size: UInt64(i), mtime: UInt64(i + 1), score: 0)
        }
        var full: [Double] = [], reused: [Double] = []
        func millis(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds)
                / 1e15
        }
        for round in 0..<7 {
            var outputs: [[Hit]] = [[], []]
            for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                let start = ContinuousClock.now
                let result: [Hit]
                if method == 0 {
                    result = try FileOrdering.sorted(
                        refreshed, sort: .name, ascending: true,
                        showHidden: true, isSearch: false)
                } else {
                    result = try FileOrdering.cached(
                        refreshed, sort: .name, ascending: true, showHidden: true, isSearch: false,
                        previous: previous
                    ).ordered
                }
                let elapsed = millis(start.duration(to: .now))
                outputs[method] = result
                if round > 0 {
                    if method == 0 { full.append(elapsed) } else { reused.append(elapsed) }
                }
            }
            XCTAssertEqual(outputs[0], outputs[1], "Same localized ordering, fresh metadata")
        }
        let before = full.sorted()[full.count / 2], after = reused.sorted()[reused.count / 2]
        print(
            "ORDERING PRODUCTION 30,000 files, same names/new metadata: \(before) → \(after) ms (\(before / after)x)"
        )
        print("ORDERING PRODUCTION samples full \(full); reuse \(reused)")
    }
}
