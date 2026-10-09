import Darwin
import Foundation

// Persistent JSON-lines helper: no process launch is included in query timing.
// Each request runs one native Spotlight query to its finish-gathering notification.
while let line = readLine() {
    do {
        let fields = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
        let query = NSMetadataQuery()
        query.searchScopes = [fields["scope"]!]
        query.predicate = NSPredicate(format: "kMDItemFSName == %@", fields["name"]!)
        var finished = false
        let observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil
        ) { _ in finished = true }
        let start = DispatchTime.now().uptimeNanoseconds
        guard query.start() else { throw NSError(domain: "Benchmark", code: 1) }
        let deadline = Date().addingTimeInterval(15)
        while !finished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        query.disableUpdates()
        let names = (0..<query.resultCount).compactMap {
            (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: "kMDItemFSName")
                as? String
        }
        query.stop()
        NotificationCenter.default.removeObserver(observer)
        let result: [String: Any] = ["ok": finished, "names": names, "milliseconds": milliseconds]
        let data = try JSONSerialization.data(withJSONObject: result)
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    } catch {
        print("{\"ok\":false,\"names\":[]}")
        fflush(stdout)
    }
}
