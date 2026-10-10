import XCTest
@testable import FinderSearch

/// Content search: reply decoding, engine round-trips, and the model state the
/// view reads. Engine-level checks stub the helper binary; model-level checks
/// stub the search service.
final class ContentSearchTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "FinderSearch-content-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func write(_ name: String, _ text: String = "original") throws -> URL {
        let url = folder.appendingPathComponent(name); try Data(text.utf8).write(to: url);
        return url
    }
    func engineScript(_ name: String, _ body: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
    @MainActor func settle(_ model: SearchModel) async throws {
        for _ in 0..<250 {
            if !model.searching, !model.loading, !model.busy, !model.sorting { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Reply decoding

    func testGrepReplyDecodesFilesAndMetadata() throws {
        let json = """
            {"ok":true,"took_us":321,"source":"scan","read":7,"complete":false,"indexing":2,
            "files":[{"path":"/tmp/a.txt","matches":[{"line":3,"text":"needle"},\
            {"line":9,"text":"again"}]}]}
            """
        let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.source, "scan")
        XCTAssertEqual(reply.read, 7)
        XCTAssertEqual(reply.complete, false)
        XCTAssertEqual(reply.indexing, 2)
        let file = try XCTUnwrap(reply.files?.first)
        XCTAssertEqual(file.path, "/tmp/a.txt")
        XCTAssertEqual(file.name, "a.txt")
        XCTAssertEqual(file.matches.count, 2)
        XCTAssertEqual(file.matches[0].line, 3)
        XCTAssertEqual(file.matches[0].text, "needle")
    }
    func testNameReplyDecodesWithoutContentFields() throws {
        let raw = #"{"ok":true,"took_us":12,"hits":[{"path":"/a.txt","kind":"file","size":1,"mtime":2,"score":3}]}"#
        let reply = try JSONDecoder().decode(Reply.self, from: Data(raw.utf8))
        XCTAssertEqual(reply.hits?.count, 1)
        XCTAssertNil(reply.files)
        XCTAssertNil(reply.source)
    }

    // MARK: Engine

    func testGrepRequestRoundTripsThroughHelper() async throws {
        let reply = """
            {"ok":true,"took_us":8,"source":"index","read":3,"complete":true,"indexing":0,\
            "files":[{"path":"/tmp/a.txt","matches":[{"line":1,"text":"needle"}]}]}
            """
        let binary = try engineScript(
            "grep-engine",
            "#!/bin/sh\nwhile IFS= read -r line; do\nprintf '%s\\n' '\(reply)'\ndone\n")
        let engine = Engine(binary: binary)
        let fields: [String: Any] = [
            "op": "grep", "pattern": "needle", "q": "", "limit": 500, "per_file": 3,
            "budget_ms": 4000, "mode": "literal", "in": folder.path,
        ]
        let answer = try await engine.request(fields)
        XCTAssertTrue(answer.ok)
        let file = try XCTUnwrap(answer.files?.first)
        XCTAssertEqual(file.matches.count, 1)
        XCTAssertEqual(answer.source, "index")
        // The helper stays warm for follow-up requests: the second round-trip
        // reuses the same process rather than spawning a new one.
        let second = try await engine.request(fields)
        XCTAssertTrue(second.ok)
    }
    func testCancelledRequestLeavesHelperRunning() async throws {
        let binary = try engineScript("stalled-engine", "#!/bin/sh\nexec /bin/sleep 30\n")
        let engine = Engine(binary: binary)
        let request = Task { try await engine.request(["q": "test"]) }
        try await Task.sleep(for: .milliseconds(200))
        request.cancel()
        do {
            _ = try await request.value; XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(
            engine.helperAttached, "A cancelled request must not terminate the helper")
    }

    /// A cancelled request's reply must never be mistaken for the next
    /// request's reply, even when it arrives split across the cancellation.
    func testCancelledRequestReplyIsNotReusedByNextRequest() async throws {
        // Replies echo the id the client sent, like the real daemon does.
        let stub = """
            #!/usr/bin/env python3
            import json, sys, time
            first = True
            for line in sys.stdin:
                req = json.loads(line)
                if first:
                    first = False
                    time.sleep(1.0)
                print(json.dumps({"ok": True, "id": req.get("id"),
                                  "source": req.get("marker", ""),
                                  "took_us": 1, "hits": []}), flush=True)
            """
        let binary = try engineScript("id-stub", stub)
        let engine = Engine(binary: binary)
        let a = Task { try await engine.request(["q": "AAA", "marker": "aaa"]) }
        try await Task.sleep(for: .milliseconds(300))
        a.cancel()
        do { _ = try await a.value; XCTFail("expected cancellation") } catch is CancellationError {}
        // Give the helper time to answer the abandoned request.
        try await Task.sleep(for: .milliseconds(1200))
        let b = try await engine.request(["q": "BBB", "marker": "bbb"])
        XCTAssertEqual(b.source, "bbb", "the next request consumed the abandoned reply")
        let c = try await engine.request(["q": "CCC", "marker": "ccc"])
        XCTAssertEqual(c.source, "ccc")
    }

    func testPartialReplyLineDoesNotCorruptNextRequest() async throws {
        let binary = try engineScript(
            "chunked-reply",
            """
            #!/bin/sh
            n=0
            while IFS= read -r line; do
              n=$((n+1))
              printf '{"ok":true,"source":"%s"' "$n"
              sleep 1
              printf ',"took_us":1,"hits":[]}\\n'
            done
            """)
        let engine = Engine(binary: binary)
        let a = Task { try await engine.request(["q": "AAA"]) }
        try await Task.sleep(for: .milliseconds(400))
        a.cancel()
        do { _ = try await a.value } catch is CancellationError {}
        let b = try await engine.request(["q": "BBB"])
        XCTAssertEqual(b.source, "2", "the next request received the abandoned reply")
        let c = try await engine.request(["q": "CCC"])
        XCTAssertEqual(c.source, "3")
    }

    func testTermIgnoringHelperDoesNotWedgeEngine() async throws {
        let binary = try engineScript(
            "term-proof",
            "#!/bin/sh\ntrap '' TERM\nprintf 'not json\\n'\nwhile IFS= read -r line; do :; done\n")
        let engine = Engine(binary: binary)
        let start = Date()
        do { _ = try await engine.request(["q": "x"]) } catch {}
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 5,
            "a helper that ignores SIGTERM must not block the engine's queue")
        // The engine still answers, through a fresh helper.
        let second = Date()
        do { _ = try await engine.request(["q": "y"]) } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(second), 5)
    }

    /// Cancellation keeps the helper warm: repeatedly cancelling must leave
    /// exactly one helper alive, not zero and not one per request.
    func testCancelledRequestsKeepExactlyOneHelper() async throws {
        let binary = try engineScript(
            "warm-loop", "#!/bin/sh\nwhile IFS= read -r line; do :; done\n")
        let engine = Engine(binary: binary)
        for _ in 0..<5 {
            let task = Task { try await engine.request(["q": "x"]) }
            try await Task.sleep(for: .milliseconds(120))
            task.cancel()
            do { _ = try await task.value } catch is CancellationError {}
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(pgrep("FinderSearch-content-[0-9A-Fa-f-]*/warm-loop").count, 1)
    }

    /// A real error replaces the helper, and the old one is reaped: no zombie
    /// accumulates, and no helper survives a burst of failures.
    func testRealErrorsLeaveNoZombiesOrHelpers() async throws {
        let binary = try engineScript(
            "garbage-reply",
            "#!/bin/sh\nwhile IFS= read -r line; do printf 'garbage\\n'; done\n")
        let engine = Engine(binary: binary)
        for _ in 0..<3 {
            do { _ = try await engine.request(["q": "x"]) } catch {}
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertEqual(pgrep("FinderSearch-content-[0-9A-Fa-f-]*/garbage-reply").count, 0)
    }

    func pgrep(_ pattern: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        return String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).split(separator: "\n").map(String.init)
    }

    // MARK: Model

    @MainActor func testContentSearchBuildsFileResultsWithSnippets() async throws {
        let alpha = try write("alpha.txt", "needle in alpha")
        let beta = try write("beta.txt", "needle in beta")
        let engine = StubSearchEngine(
            files: [
                ContentFile(
                    path: beta.path, matches: [ContentMatch(line: 1, text: "needle in beta")]),
                ContentFile(
                    path: alpha.path,
                    matches: [
                        ContentMatch(line: 7, text: "needle in alpha"),
                        ContentMatch(line: 9, text: "needle again"),
                    ]),
            ])
        let model = SearchModel(engine: engine); model.navigate(folder)
        try await settle(model)
        model.contentSearch = true
        model.query = "needle"
        try await settle(model)
        XCTAssertTrue(model.contentActive)
        XCTAssertEqual(model.hits.map(\.path), [beta.path, alpha.path])
        XCTAssertEqual(model.matches(for: alpha.path).count, 2)
        XCTAssertEqual(model.matches(for: beta.path).first?.line, 1)
        // Metadata is the reply's, not the model's defaults.
        XCTAssertEqual(model.contentSource, "scan")
        XCTAssertFalse(model.contentComplete)
        XCTAssertEqual(model.contentIndexing, 7)
        XCTAssertGreaterThan(model.elapsed, 0)
        XCTAssertEqual(model.sortedHits.count, 2)
    }
    @MainActor func testContentSearchRequestCarriesPatternScopeAndFilters() async throws {
        let engine = StubSearchEngine()
        let model = SearchModel(engine: engine); model.navigate(folder)
        try await settle(model)
        model.contentSearch = true
        model.query = "needle"; model.scope = folder.path; model.fileType = "doc"
        try await settle(model)
        let last = await engine.requests.last ?? [:]
        XCTAssertEqual(last["op"] as? String, "grep")
        XCTAssertEqual(last["pattern"] as? String, "needle")
        // Filename tokens must not narrow the candidates that get read.
        XCTAssertEqual(last["q"] as? String, "")
        XCTAssertEqual(last["limit"] as? Int, 500)
        XCTAssertEqual(last["in"] as? String, folder.path)
        XCTAssertEqual(last["type"] as? String, "doc")
        XCTAssertEqual(last["mode"] as? String, "literal")
    }
    @MainActor func testContentModeChangeRerunsSearch() async throws {
        let engine = StubSearchEngine()
        let model = SearchModel(engine: engine); model.navigate(folder)
        try await settle(model)
        model.contentSearch = true; model.query = "needle"
        try await settle(model)
        model.contentMode = "regex"
        try await settle(model)
        let modes = await engine.requests.compactMap { $0["mode"] as? String }
        XCTAssertEqual(modes.last, "regex")
    }
    @MainActor func testTurningContentSearchOffRestoresNameSearch() async throws {
        _ = try write("alpha.txt", "needle in alpha")
        let engine = StubSearchEngine()
        let model = SearchModel(engine: engine); model.navigate(folder)
        try await settle(model)
        model.contentSearch = true; model.query = "alpha"
        try await settle(model)
        model.contentSearch = false
        try await settle(model)
        let last = await engine.requests.last ?? [:]
        XCTAssertEqual(last["op"] as? String, nil)
        XCTAssertEqual(last["q"] as? String, "alpha")
        XCTAssertNil(model.contentFiles.first)
    }
    @MainActor func testSupersededContentReplyKeepsNewestState() async throws {
        // The first query's reply arrives after the second one's.
        let alpha = try write("alpha.txt")
        let beta = try write("beta.txt")
        let model = SearchModel(engine: ReplyOrderEngine(alpha: alpha.path, beta: beta.path))
        model.navigate(folder)
        try await settle(model)
        model.contentSearch = true
        model.query = "alpha"
        try await Task.sleep(for: .milliseconds(450))
        model.query = "beta"
        try await settle(model)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.contentFiles.map(\.path), [beta.path])
        XCTAssertEqual(model.hits.map(\.path), [beta.path])
        XCTAssertEqual(model.contentSource, "index")
    }
    @MainActor func testTogglingContentsModeClearsFilenameResults() async throws {
        let alpha = try write("alpha.txt", "needle in alpha")
        let engine = StubSearchEngine(
            files: [ContentFile(path: alpha.path, matches: [ContentMatch(line: 1, text: "needle in alpha")])],
            hits: [Hit(path: alpha.path, kind: "file", size: 1, mtime: 0, score: 0)])
        let model = SearchModel(engine: engine); model.navigate(folder)
        try await settle(model)
        model.query = "alpha"
        try await settle(model)
        XCTAssertEqual(model.hits.count, 1)
        // Filename rows must not linger as content rows while the grep runs.
        model.contentSearch = true
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.searching)
        try await settle(model)
        XCTAssertEqual(model.hits.map(\.path), [alpha.path])
        XCTAssertEqual(model.contentFiles.count, 1)
    }
}

private actor StubSearchEngine: SearchService {
    var requests: [[String: Any]] = []
    private let files: [ContentFile]
    private let hits: [Hit]
    private let source: String
    private let complete: Bool
    private let indexing: Int
    init(
        files: [ContentFile] = [], hits: [Hit] = [], source: String = "scan",
        complete: Bool = false, indexing: Int = 7
    ) {
        self.files = files
        self.hits = hits
        self.source = source
        self.complete = complete
        self.indexing = indexing
    }
    func request(_ fields: [String: Any]) async throws -> Reply {
        requests.append(fields)
        if fields["op"] as? String == "grep" {
            return Reply(
                ok: true, error: nil, hits: nil, took_us: 42, entries: nil, full_disk_access: nil,
                files: files, source: source, read: 9, complete: complete, indexing: indexing)
        }
        return Reply(
            ok: true, error: nil, hits: hits, took_us: 1, entries: nil, full_disk_access: nil)
    }
}

/// Answers the first content query late, so a second query overtakes it and
/// the superseded reply must not replace the newer state.
private actor ReplyOrderEngine: SearchService {
    private let alpha: String
    private let beta: String
    init(alpha: String, beta: String) { self.alpha = alpha; self.beta = beta }
    func request(_ fields: [String: Any]) async throws -> Reply {
        if fields["op"] as? String == "grep" {
            let pattern = fields["pattern"] as? String ?? ""
            if pattern == "alpha" { try await Task.sleep(for: .milliseconds(700)) }
            let path = pattern == "alpha" ? alpha : beta
            return Reply(
                ok: true, error: nil, hits: nil, took_us: 1, entries: nil, full_disk_access: nil,
                files: [ContentFile(path: path, matches: [ContentMatch(line: 1, text: pattern)])],
                source: "index", read: 1, complete: true, indexing: 0)
        }
        return Reply(
            ok: true, error: nil, hits: [], took_us: 1, entries: nil, full_disk_access: nil)
    }
}
