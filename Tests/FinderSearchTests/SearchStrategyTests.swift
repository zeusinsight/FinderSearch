import XCTest
@testable import FinderSearch

final class SearchStrategyTests: XCTestCase {
    func testQuerySanitizationSplitsPunctuationAndPreservesFilters() {
        let messy = SearchQueryPlan("project-report_2025, (final); draft")
        XCTAssertEqual(messy.primaryQuery, "project report 2025 final draft")
        XCTAssertEqual(messy.scoringTokens, ["project", "report", "2025", "final", "draft"])

        let deduplicated = SearchQueryPlan("budget - Budget_2025")
        XCTAssertEqual(deduplicated.primaryQuery, "budget 2025")

        let filters = SearchQueryPlan("ext:pdf !archive \"annual report\" ^invoice$ my-tax_return")
        XCTAssertEqual(
            filters.primaryQuery,
            "ext:pdf !archive \"annual report\" ^invoice$ my tax return"
        )
        XCTAssertEqual(
            filters.preservedTokens, ["ext:pdf", "!archive", "\"annual report\"", "^invoice$"])
        XCTAssertEqual(
            filters.scoringTokens,
            ["annual", "report", "invoice", "my", "tax", "return"]
        )

        let dotfile = SearchQueryPlan(".zshrc")
        XCTAssertEqual(dotfile.primaryQuery, ".zshrc")

        let pathQuery = SearchQueryPlan("Sources/FinderSearch/Model.swift")
        XCTAssertEqual(pathQuery.primaryQuery, "Sources/FinderSearch/Model.swift")
    }

    func testNonAdjacentAndOutOfOrderWordsOutrankScatteredSubsequences() {
        let exactBothWords = Hit(
            path: "/repo/device/fido/my_fido_device_discovery.cc",
            kind: "file",
            size: 1000,
            mtime: 100,
            score: 1860
        )
        // Starts with "fido" (giving fsearch a high prefix score), but only matches
        // "discovery" as scattered letters across the path/filename.
        let scatteredSecondWord = Hit(
            path: "/repo/device/fido_cable_v2_authenticator_registry.cc",
            kind: "file",
            size: 1000,
            mtime: 100,
            score: 1995
        )
        let singleWordOnly = Hit(
            path: "/repo/device/fido_constants.cc",
            kind: "file",
            size: 1000,
            mtime: 100,
            score: 1500
        )

        let forwardPlan = SearchQueryPlan("fido discovery")
        let forwardRanked = SearchRelevance.rank(
            hits: [scatteredSecondWord, singleWordOnly, exactBothWords],
            for: forwardPlan
        )
        XCTAssertEqual(forwardRanked.first?.path, exactBothWords.path)

        let reversePlan = SearchQueryPlan("discovery fido")
        let reverseRanked = SearchRelevance.rank(
            hits: [scatteredSecondWord, singleWordOnly, exactBothWords],
            for: reversePlan
        )
        XCTAssertEqual(reverseRanked.first?.path, exactBothWords.path)
    }

    func testCamelCaseAndConciseFilenamesRankHigher() {
        let concise = Hit(
            path: "/repo/Sources/OpenPanelController.swift",
            kind: "file",
            size: 500,
            mtime: 100,
            score: 1600
        )
        let verbose = Hit(
            path: "/repo/Sources/LegacyOpenFileBrowserPanelWindowControllerHelper.swift",
            kind: "file",
            size: 500,
            mtime: 100,
            score: 1600
        )
        let scattered = Hit(
            path: "/repo/Sources/OperationPipeline.swift",
            kind: "file",
            size: 500,
            mtime: 100,
            score: 1750
        )

        let plan = SearchQueryPlan("panel open")
        let ranked = SearchRelevance.rank(hits: [scattered, verbose, concise], for: plan)
        XCTAssertEqual(ranked.map(\.path), [concise.path, verbose.path, scattered.path])
    }

    func testTypoWordInMultiWordQueryRanksAboveSingleWordMatch() {
        let target = Hit(
            path: "/docs/quarterly_financial_report.pdf",
            kind: "file",
            size: 1000,
            mtime: 100,
            score: 1400
        )
        let partial = Hit(
            path: "/docs/quarterly_notes.pdf",
            kind: "file",
            size: 1000,
            mtime: 100,
            score: 1550
        )

        // "reprot" has an adjacent transposition of "report"
        let plan = SearchQueryPlan("quarterly reprot")
        let ranked = SearchRelevance.rank(hits: [partial, target], for: plan)
        XCTAssertEqual(ranked.first?.path, target.path)
    }

    @MainActor func testModelSendsSanitizedQueryBoostNearAndFallsBackWhenStrictMatchIsEmpty()
        async throws
    {
        let hitA = Hit(
            path: "/Users/test/Documents/my_fido_device_discovery.cc",
            kind: "file",
            size: 120,
            mtime: 50,
            score: 1500
        )
        let hitB = Hit(
            path: "/Users/test/Documents/fido_notes.txt",
            kind: "file",
            size: 80,
            mtime: 50,
            score: 1600
        )
        let engine = SmartMockSearchEngine { fields in
            let q = fields["q"] as? String ?? ""
            switch q {
            case "fido discovery":
                return [hitB, hitA]
            default:
                return []
            }
        }
        let model = SearchModel(
            engine: engine,
            searchDebounce: .milliseconds(5),
            folderLoader: { _, _ in [] },
            folderPreviewLoader: { _, _ in [] }
        )
        let folder = URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true)
        model.navigate(folder)

        // Wait for initial folder load to settle
        for _ in 0..<50 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        // 3-word messy query where "missingword" is not in any file:
        // Primary query: "fido discovery missingword" -> 0 hits
        // Tiered fallback drops 1 word -> queries "fido discovery", finds hits, and ranks hitA first.
        model.query = "fido-discovery, missingword"
        XCTAssertEqual(model.sort, .relevance)

        for _ in 0..<100 {
            if !model.searching && !model.sorting && !model.hits.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let requests = await engine.requests
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        XCTAssertEqual(requests.first?["q"] as? String, "fido discovery missingword")
        XCTAssertEqual(requests.first?["boost"] as? Bool, true)
        XCTAssertEqual(requests.first?["near"] as? String, folder.path)
        XCTAssertEqual(model.sortedHits.map(\.path), [hitA.path, hitB.path])
    }

    @MainActor func testShortWordTranspositionFallbackFindsMatch() async throws {
        let mainHit = Hit(
            path: "/Users/test/Project/main_window.swift",
            kind: "file",
            size: 100,
            mtime: 10,
            score: 1400
        )
        let engine = SmartMockSearchEngine { fields in
            let q = fields["q"] as? String ?? ""
            return q == "main" ? [mainHit] : []
        }
        let model = SearchModel(
            engine: engine,
            searchDebounce: .milliseconds(5),
            folderLoader: { _, _ in [] },
            folderPreviewLoader: { _, _ in [] }
        )
        model.query = "mian"
        for _ in 0..<100 {
            if !model.searching && !model.sorting && !model.hits.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.sortedHits.map(\.path), [mainHit.path])
    }

    @MainActor func testLocalFolderSearchFindsFilesWhenEngineSkipsGatedDirectory() async throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "FinderSearchLocalFallback-" + UUID().uuidString, isDirectory: true)
        let subFolder = tempRoot.appendingPathComponent("SharedNotes", isDirectory: true)
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let targetFile = subFolder.appendingPathComponent("quarterly_architecture_overview.pdf")
        let otherFile = subFolder.appendingPathComponent("unrelated_notes.txt")
        try Data("pdf".utf8).write(to: targetFile)
        try Data("txt".utf8).write(to: otherFile)

        // Engine returns 0 hits (simulating a skipped iCloud Drive / gated folder)
        let engine = SmartMockSearchEngine { _ in [] }
        let model = SearchModel(engine: engine, searchDebounce: .milliseconds(5))
        model.navigate(subFolder)

        for _ in 0..<100 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        model.query = "overview architecture"
        for _ in 0..<100 {
            if !model.searching && !model.sorting && !model.hits.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.sortedHits.map(\.path), [targetFile.standardizedFileURL.path])
    }
}

private actor SmartMockSearchEngine: SearchService {
    var requests: [[String: Any]] = []
    private let handler: @Sendable ([String: Any]) -> [Hit]

    init(handler: @escaping @Sendable ([String: Any]) -> [Hit]) {
        self.handler = handler
    }

    func request(_ fields: [String: Any]) async throws -> Reply {
        requests.append(fields)
        let hits = handler(fields)
        return Reply(
            ok: true, error: nil, hits: hits, took_us: 100, entries: 10, full_disk_access: true
        )
    }
}
