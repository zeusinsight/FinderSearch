import XCTest
@testable import FinderSearch

/// Indexed transfer projection; benchmarks perform no filesystem operations.
final class TransferTests: XCTestCase {
    // Previous production implementation, retained as an independent oracle.
    private func sequential(_ operations: [FileMutation], to hits: [Hit], in folder: URL?) -> [Hit]
    {
        var result = hits
        for operation in operations {
            switch operation {
            case .renameBatch(let moves):
                let mapping = Dictionary(
                    uniqueKeysWithValues: moves.map { ($0.source.path, $0.destination) })
                result = result.map { hit in
                    guard let destination = mapping[hit.path] else { return hit }
                    return Hit(
                        path: destination.path, kind: hit.kind, size: hit.size,
                        mtime: hit.mtime, score: hit.score, metadataPending: hit.metadataPending)
                }
            case .replace(let source, let destination, let move):
                result.removeAll { $0.path == destination.path }
                result = sequential(
                    [move ? .move(source, destination) : .copy(source, destination)], to: result,
                    in: folder)
            case .trash(let source):
                result.removeAll { $0.path == source.path }
            case .move(let source, let destination):
                guard source.path != destination.path,
                    !result.contains(where: { $0.path == destination.path })
                else { continue }
                let original = result.first { $0.path == source.path }
                result.removeAll { $0.path == source.path }
                if let original,
                    destination.deletingLastPathComponent().path == folder?.path
                        || (folder == nil
                            && destination.deletingLastPathComponent().path
                                == source.deletingLastPathComponent().path)
                {
                    result.append(
                        Hit(
                            path: destination.path, kind: original.kind,
                            size: original.size, mtime: original.mtime, score: original.score,
                            metadataPending: original.metadataPending))
                }
            case .copy(let source, let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path }),
                    let original = result.first(where: { $0.path == source.path })
                else { continue }
                result.append(
                    Hit(
                        path: destination.path, kind: original.kind,
                        size: original.size, mtime: original.mtime, score: original.score,
                        metadataPending: original.metadataPending))
            case .folder(let destination), .extract(_, let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path })
                else { continue }
                result.append(
                    Hit(
                        path: destination.path, kind: "dir", size: 0,
                        mtime: UInt64(Date().timeIntervalSince1970), score: 0))
            case .textFile(let destination), .compress(_, let destination):
                guard destination.deletingLastPathComponent().path == folder?.path,
                    !result.contains(where: { $0.path == destination.path })
                else { continue }
                result.append(
                    Hit(
                        path: destination.path, kind: "file", size: 0,
                        mtime: UInt64(Date().timeIntervalSince1970), score: 0))
            case .tags: break
            }
        }
        return result
    }

    private func hit(_ name: String, size: UInt64 = 1) -> Hit {
        Hit(
            path: "/fixture/" + name, kind: "file", size: size, mtime: size, score: 3,
            metadataPending: true)
    }

    func testDependenciesDuplicatesAndReconciliation() {
        let a = hit("a"), b = hit("b"), c = hit("c"), d = hit("d")
        let cases: [[FileMutation]] = [
            [], [.move(a.url, b.url)], [.move(a.url, d.url), .move(d.url, a.url)],
            [.move(a.url, d.url), .copy(d.url, a.url)],
            [.copy(a.url, d.url), .move(d.url, c.url)],
            [.move(a.url, a.url)], [.copy(a.url, a.url)],
            [.move(d.url, a.url)], [.move(d.url, URL(fileURLWithPath: "/other/e"))],
            [.move(b.url, URL(fileURLWithPath: "/other/b")), .move(a.url, b.url)],
            [.move(a.url, d.url), .trash(d.url)],
        ]
        for hits in [[a, b, c], [a, a, b, c], []] {
            for folder: URL? in [
                URL(fileURLWithPath: "/fixture"), nil,
                URL(fileURLWithPath: "/other"),
            ] {
                for operations in cases {
                    XCTAssertEqual(
                        OptimisticFiles.applying(operations, to: hits, in: folder),
                        sequential(operations, to: hits, in: folder))
                    // A successful subset is reapplied to the original rows after failures.
                    let subset = Array(operations.suffix(1))
                    XCTAssertEqual(
                        OptimisticFiles.applying(subset, to: hits, in: folder),
                        sequential(subset, to: hits, in: folder))
                }
            }
        }
    }

    func testDeterministicDifferentialSequences() {
        var state: UInt64 = 0xCAFE
        func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1
            return Int(state >> 32) % limit
        }
        let urls = (0..<30).map {
            URL(fileURLWithPath: ($0 < 20 ? "/fixture/" : "/other/") + "file-\($0)")
        }
        for trial in 0..<300 {
            let hits: [Hit] = (0..<15).map { (i: Int) -> Hit in
                let kind = i.isMultiple(of: 3) ? "dir" : "file"
                return Hit(
                    path: urls[i].path, kind: kind, size: UInt64(i),
                    mtime: UInt64(i + 3), score: Int64(i), metadataPending: i.isMultiple(of: 2))
            }
            let operations: [FileMutation] = (0..<20).map { _ in
                let source = urls[next(urls.count)], destination = urls[next(urls.count)]
                return next(2) == 0 ? .move(source, destination) : .copy(source, destination)
            }
            let folder: URL? =
                trial % 3 == 0
                ? nil
                : URL(fileURLWithPath: trial % 3 == 1 ? "/fixture" : "/other")
            XCTAssertEqual(
                OptimisticFiles.applying(operations, to: hits, in: folder),
                sequential(operations, to: hits, in: folder), "Trial \(trial)")
        }
    }

    @MainActor func testTransferProjectionPerformance() {
        let hits = (0..<30000).map { hit("file-\($0).txt", size: UInt64($0)) }
        let folder = URL(fileURLWithPath: "/fixture")
        for (mode, count) in [
            ("move out", 1), ("move out", 10), ("move out", 100), ("rename", 100), ("copy", 100),
        ] {
            let operations: [FileMutation] = (0..<count).map { i in
                let destination = URL(
                    fileURLWithPath: (mode == "move out" ? "/other/" : "/fixture/") + "new-\(i).txt"
                )
                return mode == "copy"
                    ? .copy(hits[i * 199].url, destination)
                    : .move(hits[i * 199].url, destination)
            }
            var samples = [[Double]](repeating: [], count: 2)
            for round in 0..<4 {
                var outputs: [[Hit]] = [[], []]
                for method in (round.isMultiple(of: 2) ? [0, 1] : [1, 0]) {
                    autoreleasepool {
                        let start = ContinuousClock.now
                        outputs[method] =
                            method == 0
                            ? sequential(operations, to: hits, in: folder)
                            : OptimisticFiles.applying(operations, to: hits, in: folder)
                        let duration = start.duration(to: .now)
                        let ms =
                            Double(duration.components.seconds) * 1000
                            + Double(duration.components.attoseconds) / 1e15
                        if round > 0 { samples[method].append(ms) }
                    }
                }
                XCTAssertEqual(outputs[0], outputs[1])
            }
            let before = samples[0].sorted()[1], after = samples[1].sorted()[1]
            print(
                "TRANSFER PRODUCTION \(mode), \(count) operations / 30,000 rows: \(before) -> \(after) ms (\(before / after)x)"
            )
        }
    }
}
