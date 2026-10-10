import XCTest
@testable import FinderSearch

/// Production optimistic updates; benchmarks never change files on disk.
final class BulkMutationTests: XCTestCase {
    // Exact previous trash implementation, kept only as a benchmark baseline.
    private func sequentialTrash(_ operations: [FileMutation], hits: [Hit]) -> [Hit] {
        var result = hits
        for case .trash(let source) in operations {
            result.removeAll { $0.path == source.path }
        }
        return result
    }

    private func hit(_ name: String) -> Hit {
        Hit(path: "/fixture/" + name, kind: "file", size: 42, mtime: 123, score: 0)
    }

    func testTrashBatchesPreserveOrderAndMetadata() {
        let hits = ["a", "b", "a", "c", "d"].map(hit)
        let cases: [([FileMutation], [Hit])] = [
            ([], hits),
            ([.trash(hit("a").url)], [hit("b"), hit("c"), hit("d")]),
            ([.trash(hit("a").url), .trash(hit("a").url)], [hit("b"), hit("c"), hit("d")]),
            (
                [.trash(hit("missing").url), .trash(hit("c").url)],
                [hit("a"), hit("b"), hit("a"), hit("d")]
            ),
            (hits.map { .trash($0.url) }, []),
        ]
        for (operations, expected) in cases {
            XCTAssertEqual(OptimisticFiles.applying(operations, to: hits, in: nil), expected)
            XCTAssertEqual(OptimisticFiles.applying(operations, to: [], in: nil), [])
        }
        // Reconcile a partially successful batch against the original rows,
        // retaining the item whose filesystem operation failed or was cancelled.
        let successful: [FileMutation] = [.trash(hit("b").url)]
        XCTAssertEqual(
            OptimisticFiles.applying(successful, to: hits, in: nil),
            [hit("a"), hit("a"), hit("c"), hit("d")])
    }

    func testMixedOperationsRetainSequentialDependencies() {
        let hits = [hit("a"), hit("b"), hit("c")]
        let move = FileMutation.move(hit("a").url, hit("e").url)
        XCTAssertEqual(
            OptimisticFiles.applying(
                [move, .trash(hit("e").url)],
                to: hits, in: nil), [hit("b"), hit("c")])
        XCTAssertEqual(
            OptimisticFiles.applying(
                [.trash(hit("e").url), move],
                to: hits, in: nil), [hit("b"), hit("c"), hit("e")])
        XCTAssertEqual(
            OptimisticFiles.applying(
                [.trash(hit("a").url), move],
                to: hits, in: nil), [hit("b"), hit("c")])
    }

    @MainActor func testLargeSelectionTrashProjection() {
        let hits = (0..<30000).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: UInt64($0), mtime: 0, score: 0)
        }
        let operations: [FileMutation] = (0..<100).map { .trash(hits[$0 * 199].url) }
        var samples = [[Double]](repeating: [], count: 2)
        for round in 0..<5 {
            var outputs: [[Hit]] = [[], []]
            for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                autoreleasepool {
                    let start = ContinuousClock.now
                    outputs[method] =
                        method == 0
                        ? sequentialTrash(operations, hits: hits)
                        : OptimisticFiles.applying(operations, to: hits, in: nil)
                    let duration = start.duration(to: .now)
                    let elapsed =
                        Double(duration.components.seconds) * 1000
                        + Double(duration.components.attoseconds) / 1e15
                    if round > 0 { samples[method].append(elapsed) }
                }
            }
            XCTAssertEqual(outputs[0], outputs[1])
            XCTAssertEqual(outputs[1].count, 29900)
        }
        let before = samples[0].sorted()[2], after = samples[1].sorted()[2]
        print(
            "TRASH PROJECTION PRODUCTION 100 removals / 30,000 rows: \(before) -> \(after) ms (\(before / after)x)"
        )
        print("TRASH PROJECTION samples baseline \(samples[0]); batched \(samples[1])")
    }
}
