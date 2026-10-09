import AppKit
import Foundation

struct MountedVolume: Equatable, Identifiable, Sendable {
    let url: URL
    let canEject: Bool
    var id: String { url.path }
    var name: String { id == "/" ? "Macintosh HD" : url.lastPathComponent }

    init(url: URL, canEject: Bool) {
        self.url = url
        self.canEject = canEject && url.path != "/"
    }

    static func load() async throws -> [MountedVolume] {
        try await BackgroundWork.run {
            let keys: Set<URLResourceKey> = [
                .volumeIsBrowsableKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                .volumeIsInternalKey,
            ]
            let urls =
                FileManager.default.mountedVolumeURLs(
                    includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes])
                ?? []
            return try urls.map { url in
                try Task.checkCancellation()
                let values = try? url.resourceValues(forKeys: keys)
                return MountedVolume(
                    url: url,
                    canEject: values?.volumeIsEjectable == true
                        || values?.volumeIsRemovable == true || values?.volumeIsInternal == false)
            }
        }
    }

    static func eject(_ url: URL) async throws {
        try await BackgroundWork.run { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
    }
}
