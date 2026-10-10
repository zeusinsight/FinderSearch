import XCTest
@testable import FinderSearch

final class SelectionIndexTests: XCTestCase {
    private func hit(_ name: String, size: UInt64 = 1) -> Hit {
        Hit(path: "/fixture/\(name)", kind: "file", size: size, mtime: 0, score: 0)
    }

    @MainActor private func settle(_ model: SearchModel) async throws {
        for _ in 0..<2000 {
            if !model.sorting { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Ordering did not finish")
    }

    @MainActor func testIndexTracksOrderingReplacementAndKeyboardRanges() async throws {
        let model = SearchModel()
        model.hits = (0..<40).map { hit("file-\($0)", size: UInt64($0)) }
        try await settle(model)
        model.selection = [hit("file-2").path, hit("file-30").path]
        XCTAssertEqual(model.selectedItems.map(\.name), ["file-2", "file-30"])
        model.ascending = false
        XCTAssertEqual(model.selectedItems.map(\.name), ["file-2", "file-30"])
        try await settle(model)
        XCTAssertEqual(model.selectedItems.map(\.name), ["file-30", "file-2"])
        model.select(hit("file-30"), extending: false, toggling: false)
        model.moveSelection(by: 2, extending: true)
        XCTAssertEqual(model.selectedItems.map(\.name), ["file-30", "file-29", "file-28"])
        model.moveSelection(by: -1, extending: true)
        XCTAssertEqual(model.selectedItems.map(\.name), ["file-30", "file-29"])
        model.select(hit("file-27"), extending: true, toggling: false)
        XCTAssertEqual(
            model.selectedItems.map(\.name), ["file-30", "file-29", "file-28", "file-27"])
        model.selection = [hit("file-30").path]
        model.hits = (0..<40).map { hit("file-\($0)", size: 999) }
        XCTAssertEqual(model.selected?.size, 999)
        try await settle(model)
        XCTAssertEqual(model.selected?.size, 999)
        model.hits = [hit("replacement")]
        XCTAssertTrue(model.selectedItems.isEmpty)
        try await settle(model)
        XCTAssertTrue(model.selectedItems.isEmpty)
    }

    @MainActor func testExtraRowsDeduplicateAndInvalidateForBothSelectionPaths() async throws {
        let model = SearchModel()
        model.hits = (0..<40).map { hit("file-\($0)") }
        model.extraHits = [
            hit("file-2", size: 99), hit("extra"), hit("extra", size: 99), hit(".hidden"),
        ]
        try await settle(model)
        model.selection = Set(["file-2", "extra", ".hidden", "missing"].map { hit($0).path })
        XCTAssertEqual(model.selectedItems.map(\.name), ["file-2", "extra"])
        XCTAssertEqual(model.selectedItems.map(\.size), [1, 1])
        model.extraHits = [hit("extra", size: 42)]
        XCTAssertEqual(model.selectedItems.map(\.size), [1, 42])
        model.extraHits = [hit(".hidden"), hit("extra")]
        model.selection = Set(model.hits.map(\.path) + model.extraHits.map(\.path))
        XCTAssertEqual(model.selectedItems.count, 41)
        // Keep visibility changes isolated from filesystem navigation.
        model.busy = true
        model.showHidden = true
        try await settle(model)
        model.selection = [hit(".hidden").path]
        XCTAssertEqual(model.selectedItems.map(\.name), [".hidden"])
        model.showHidden = false
        XCTAssertTrue(model.selectedItems.isEmpty)
        try await settle(model)
    }

    @MainActor func testSparseSelectionPerformance() async throws {
        let model = SearchModel()
        model.hits = (0..<30000).map {
            Hit(path: "/fixture/file-\($0).txt", kind: "file", size: 1, mtime: 0, score: 0)
        }
        try await settle(model)
        let ordered = model.sortedHits
        model.selection = [ordered[0].path]
        let buildStart = ContinuousClock.now
        XCTAssertEqual(model.selectedItems.map(\.path), [ordered[0].path])
        let buildTime = buildStart.duration(to: .now)
        let choices = (0..<200).map { ordered[($0 * 7919) % ordered.count].path }
        var baseline: [Double] = [], indexed: [Double] = []
        func millis(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) / 1e15
        }
        for round in 0..<7 {
            for useIndex in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let start = ContinuousClock.now
                for path in choices {
                    model.selection = [path]
                    let result: [Hit]
                    if useIndex {
                        result = model.selectedItems
                    } else {
                        var seen = Set<String>()
                        result =
                            (model.sortedHits
                            + model.extraHits.filter {
                                model.showHidden || !$0.name.hasPrefix(".")
                            }).filter {
                                model.selection.contains($0.path) && seen.insert($0.path).inserted
                            }
                    }
                    XCTAssertEqual(result.map(\.path), [path])
                }
                let elapsed = millis(start.duration(to: .now))
                if round > 0 {
                    if useIndex { indexed.append(elapsed) } else { baseline.append(elapsed) }
                }
            }
        }
        let before = baseline.sorted()[baseline.count / 2]
        let after = indexed.sorted()[indexed.count / 2]
        XCTAssertLessThan(
            after * 10, before, "Sparse selection should stay at least 10x faster than scanning")
        print(
            "PERFORMANCE 30,000 files / 200 selection changes: baseline median \(before) ms; indexed median \(after) ms; ratio \(before / after)x; one-time index build \(millis(buildTime)) ms"
        )
        print("PERFORMANCE baseline samples \(baseline); indexed samples \(indexed)")
    }
}
