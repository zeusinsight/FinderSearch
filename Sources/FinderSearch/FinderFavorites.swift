import Foundation
import CoreServices

/// A read-only snapshot of Finder's ordinary folder favorites. Keep the system
/// item ID so an offline favorite can retain its last known path and position.
enum FinderFavorites {
    struct Entry: Codable, Equatable, Sendable {
        let id: UInt32
        let path: String
    }

    struct Item: Sendable {
        let id: UInt32
        let url: URL?
        var hidden = false
    }

    static let syncEnabledKey = "syncFinderFavorites"
    static let cacheKey = "finderSidebarFavorites"
    static let originalKey = "sidebarFavoritesBeforeFinderSync"

    static func load(cached: [Entry]) async throws -> [Entry] {
        try await BackgroundWork.run {
            // Deprecated, but still the system's Finder favorites interface.
            // Going through it avoids depending on .sfl2/.sfl3/.sfl4 archives.
            guard
                let list = LSSharedFileListCreate(
                    nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil
                )?.takeRetainedValue(),
                let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue()
                    as? [LSSharedFileListItem]
            else { throw CocoaError(.fileReadUnknown) }

            let items = snapshot.map { item in
                let hidden =
                    LSSharedFileListItemCopyProperty(
                        item, kLSSharedFileListItemHidden.takeUnretainedValue()
                    )?.takeRetainedValue() as? Bool ?? false
                // Do not prompt for credentials or mount a disconnected volume.
                let flags = UInt32(
                    kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
                let url =
                    hidden
                    ? nil
                    : LSSharedFileListItemCopyResolvedURL(
                        item, flags, nil
                    )?.takeRetainedValue() as URL?
                return Item(id: LSSharedFileListItemGetID(item), url: url, hidden: hidden)
            }
            return try folders(from: items, cached: cached)
        }
    }

    static func folders(from items: [Item], cached: [Entry]) throws -> [Entry] {
        let previous = Dictionary(
            cached.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var unresolved = false
        let folders = items.compactMap { item -> Entry? in
            guard !item.hidden else { return nil }
            let path: String
            if let url = item.url {
                // Recents, AirDrop and other virtual destinations aren't folders.
                guard url.isFileURL else { return nil }
                let url = url.standardizedFileURL
                if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                    guard values.isDirectory == true, values.isPackage != true else { return nil }
                    path = url.path
                } else {
                    unresolved = true
                    guard let saved = previous[item.id], saved == url.path else { return nil }
                    path = saved
                }
            } else {
                unresolved = true
                guard let saved = previous[item.id] else { return nil }
                path = saved
            }
            guard path.hasPrefix("/"), seen.insert(path).inserted else { return nil }
            return Entry(id: item.id, path: path)
        }
        // An unreadable snapshot must not erase the last usable sidebar. A
        // genuinely empty list (or one containing only special items) may do so.
        if folders.isEmpty && unresolved { throw CocoaError(.fileReadUnknown) }
        return folders
    }
}
