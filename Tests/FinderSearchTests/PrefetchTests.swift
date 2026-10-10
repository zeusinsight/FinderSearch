import XCTest
@testable import FinderSearch

/// Compare production candidate discovery with the previous full scan.
final class PrefetchTests: XCTestCase {
    private func millis(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    @MainActor func testPrefetchCandidateDiscovery() {
        let count = 30000
        let folders = (0..<count).map {
            Hit(path: "/fixture/folder-\($0)", kind: "dir", size: 0, mtime: 0, score: 0)
        }
        let files = (0..<count).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: 0, mtime: 0, score: 0)
        }
        let packages = (0..<count).map {
            Hit(path: "/fixture/package-\($0).rtfd", kind: "dir", size: 0, mtime: 0, score: 0)
        }
        let cases: [(String, [Hit])] = [
            ("empty", []),
            ("all folders", folders),
            ("folders first", Array(folders.prefix(3)) + files),
            ("folders last", files + Array(folders.prefix(3))),
            ("files only", files),
            ("extension-bearing directories", packages + Array(folders.prefix(3))),
            ("fewer than three folders", Array(folders.prefix(2))),
        ]
        for (label, items) in cases {
            var samples = [[Double]](repeating: [], count: 2)
            for round in 0..<7 {
                var outputs: [[URL]] = [[], []]
                for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    autoreleasepool {
                        let start = ContinuousClock.now
                        let result =
                            method == 0
                            ? Array(items.filter(\.isFolder).prefix(3)).map(\.url)
                            : SearchModel.prefetchCandidates(in: items)
                        let elapsed = millis(start.duration(to: .now))
                        outputs[method] = result
                        if round > 0 { samples[method].append(elapsed) }
                    }
                }
                XCTAssertEqual(outputs[0], outputs[1])
                XCTAssertLessThanOrEqual(outputs[1].count, 3)
            }
            let before = samples[0].sorted()[3], after = samples[1].sorted()[3]
            print(
                "PREFETCH PRODUCTION \(label), \(items.count) rows: \(before) -> \(after) ms (\(before / after)x)"
            )
        }
    }

    @MainActor func testPostLoadMainThreadWork() {
        let items = (0..<30000).map {
            Hit(path: "/fixture/folder-\($0)", kind: "dir", size: 0, mtime: 0, score: 0)
        }
        var samples = [[Double]](repeating: [], count: 2)
        for round in 0..<7 {
            for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                autoreleasepool {
                    var selection: Set<String> = [items[0].path, "/fixture/deleted"]
                    let start = ContinuousClock.now
                    // Same O(n) selection reconciliation that accompanies publication.
                    selection.formIntersection(Set(items.map(\.path)))
                    let urls =
                        method == 0
                        ? Array(items.filter(\.isFolder).prefix(3)).map(\.url)
                        : SearchModel.prefetchCandidates(in: items)
                    let elapsed = millis(start.duration(to: .now))
                    XCTAssertEqual(selection, [items[0].path])
                    XCTAssertEqual(urls.count, 3)
                    if round > 0 { samples[method].append(elapsed) }
                }
            }
        }
        let before = samples[0].sorted()[3], after = samples[1].sorted()[3]
        print(
            "POSTLOAD PRODUCTION 30,000 folders, selection reconciliation + prefetch candidates: \(before) -> \(after) ms (\(before / after)x)"
        )
    }
}
