import AppKit
import SwiftUI
import Darwin

struct FileTag: Equatable, Sendable {
    let name: String
    let color: Int
    init(_ value: String) {
        let parts = value.split(separator: "\n", omittingEmptySubsequences: false)
        name = String(parts.first ?? "")
        color = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
    }
    init(name: String, color: Int) {
        self.name = name; self.color = color
    }
    var storageValue: String { name + "\n" + String(color) }
    static func color(for name: String) -> Int {
        ["Gray": 1, "Green": 2, "Purple": 3, "Blue": 4, "Yellow": 5, "Red": 6, "Orange": 7][name]
            ?? 0
    }
    static func write(_ values: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: values.map { FileTag($0).storageValue }, format: .binary, options: 0)
        let result = data.withUnsafeBytes {
            setxattr(
                url.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0)
        }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
        }
        (url as NSURL).removeAllCachedResourceValues()
    }
    var displayColor: NSColor {
        switch color {
        case 1: return .systemGray
        case 2: return .systemGreen
        case 3: return .systemPurple
        case 4: return .systemBlue
        case 5: return .systemYellow
        case 6: return .systemRed
        case 7: return .systemOrange
        default: return .secondaryLabelColor
        }
    }
    static func read(_ url: URL) -> [FileTag] {
        // Foundation exposes tag names, but Finder stores each tag's color here.
        let attribute = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, attribute, nil, 0, 0, 0)
        if size > 0, size <= 65536 {
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes {
                getxattr(url.path, attribute, $0.baseAddress, size, 0, 0)
            }
            if count > 0 {
                data.count = count
                if let values = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String]
                {
                    return values.map(FileTag.init).filter { !$0.name.isEmpty }
                }
            }
        }
        return ((try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? [])
            .map(FileTag.init).filter { !$0.name.isEmpty }
    }
}

/// Load only visible files, with bounded storage and explicit mutation invalidation.
@MainActor final class FileTagCache {
    static let shared = FileTagCache()
    static let changed = Notification.Name("FinderSearch.fileTagsChanged")
    private final class Entry: NSObject {
        let tags: [FileTag]
        init(_ tags: [FileTag]) { self.tags = tags }
    }
    private let entries = NSCache<NSString, Entry>()
    private var revision = 0
    init() { entries.countLimit = 1024 }
    func cached(_ url: URL) -> [FileTag]? { entries.object(forKey: url.path as NSString)?.tags }
    func load(_ url: URL) async -> [FileTag] {
        if let cached = cached(url) { return cached }
        let revision = revision
        let tags = (try? await BackgroundWork.run { FileTag.read(url) }) ?? []
        if self.revision == revision, !Task.isCancelled {
            entries.setObject(Entry(tags), forKey: url.path as NSString)
        }
        return tags
    }
    func invalidate(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        revision += 1
        for path in paths { entries.removeObject(forKey: path as NSString) }
        NotificationCenter.default.post(name: Self.changed, object: paths)
    }
}

struct FileTagIndicators: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> FileTagView { FileTagView() }
    func updateNSView(_ view: FileTagView, context: Context) { view.configure(url) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FileTagView, context: Context)
        -> CGSize?
    {
        nsView.intrinsicContentSize
    }
}

/// Shared by SwiftUI file names and native list cells; reuse cancels stale reads.
final class FileTagView: NSView {
    private(set) var tags: [FileTag] = []
    private var url: URL?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        observer = NotificationCenter.default.addObserver(
            forName: FileTagCache.changed, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let url = self.url,
                    (notification.object as? Set<String>)?.contains(url.path) == true
                else { return }
                self.refresh()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: min(tags.count, 4) * 8, height: 10)
    }
    func configure(_ url: URL?) {
        guard self.url != url else { return }
        self.url = url
        update([])
        refresh()
    }
    private func refresh() {
        task?.cancel()
        guard let url else { return }
        task = Task { @MainActor [weak self] in
            let tags = await FileTagCache.shared.load(url)
            guard !Task.isCancelled, self?.url == url else { return }
            self?.update(tags)
        }
    }
    private func update(_ tags: [FileTag]) {
        self.tags = tags
        toolTip =
            tags.isEmpty
            ? nil : tags.map { SidebarTags.title(for: $0.name) }.joined(separator: ", ")
        setAccessibilityElement(!tags.isEmpty)
        setAccessibilityRole(.image)
        setAccessibilityLabel(toolTip.map { L10n.string("Tags: ") + $0 })
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        for (index, tag) in tags.prefix(4).enumerated() {
            let circle = NSBezierPath(ovalIn: NSRect(x: index * 8, y: 2, width: 6, height: 6))
            tag.displayColor.set()
            if tag.color == 0 { circle.stroke() } else { circle.fill() }
        }
    }
    deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
