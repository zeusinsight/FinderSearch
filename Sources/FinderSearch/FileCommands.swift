import AppKit

/// User commands collect intent on the main actor; filesystem preparation runs in the background.
extension SearchModel {
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url)) }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false;
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { navigate(url) }
    }
    func goToFolder() {
        let alert = NSAlert(); alert.messageText = "Go to Folder"; alert.addButton(withTitle: "Go");
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: location.path);
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            navigate(
                URL(
                    fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath,
                    isDirectory: true))
        }
    }
    func rename() {
        guard !busy, let hit = selected, selection.count == 1 else { return }
        beginRename(hit)
    }
    func newFolder() {
        guard canWriteHere else { return }
        let folder = location
        prepareOperations(name: "New Folder") {
            [.folder(LocalFiles.availableName(in: folder, name: "untitled folder"))]
        }
    }
    func newTextFile() {
        guard canWriteHere else { return }
        let folder = location
        prepareOperations(name: "New Text File") {
            [.textFile(LocalFiles.availableName(in: folder, name: "untitled.txt"))]
        }
    }
    func duplicate() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        prepareOperations(name: "Duplicate") {
            try items.map {
                try Task.checkCancellation()
                return .copy(
                    $0.url,
                    LocalFiles.availableName(
                        in: $0.url.deletingLastPathComponent(), name: $0.name, suffix: " copy"))
            }
        }
    }
    func trash() { perform(selectedItems.map { .trash($0.url) }, name: "Move to Trash") }
    func copy() {
        NSPasteboard.general.clearContents();
        NSPasteboard.general.writeObjects(selectedItems.map { $0.url as NSURL })
    }
    func copyPath() {
        NSPasteboard.general.clearContents();
        NSPasteboard.general.setString(
            selectedItems.map(\.path).joined(separator: "\n"), forType: .string)
    }
    func paste(move: Bool = false) {
        guard canWriteHere else { return }
        let urls =
            NSPasteboard.general.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        transfer(urls, to: location, move: move)
    }
    func transfer(_ urls: [URL], to folder: URL, move: Bool) {
        guard !busy else { return }
        var seen = Set<String>()
        let items = urls.filter { $0.isFileURL && seen.insert($0.path).inserted }
        guard !items.isEmpty else { return }
        prepareOperations(name: move ? "Move" : "Copy") {
            let target = folder.resolvingSymlinksInPath().path
            return try items.compactMap { source in
                try Task.checkCancellation()
                let destination = folder.appendingPathComponent(source.lastPathComponent)
                if source.standardizedFileURL == destination.standardizedFileURL {
                    return move
                        ? nil
                        : .copy(
                            source,
                            LocalFiles.availableName(
                                in: folder, name: source.lastPathComponent, suffix: " copy"))
                }
                if target.hasPrefix(source.resolvingSymlinksInPath().path + "/") {
                    throw Engine.Failure.message(
                        "A folder cannot be moved or copied inside itself.")
                }
                return move ? .move(source, destination) : .copy(source, destination)
            }
        }
    }
    func info() {
        guard let hit = selected else { return }
        let folder = location
        Task {
            do {
                let details = try await BackgroundWork.run {
                    let item = try Hit.read(hit.url)
                    let tags = (try? hit.url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                    return (item, tags)
                }
                guard location == folder else { return }
                let item = details.0
                let alert = NSAlert(); alert.messageText = item.name
                alert.informativeText =
                    "Kind: \(item.typeName)\nSize: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: item.size), countStyle: .file))\nModified: \(item.modified.formatted())\nWhere: \(item.parent)\nTags: \(details.1.joined(separator: ", "))"
                alert.addButton(withTitle: "OK"); alert.runModal()
            } catch {
                if location == folder { self.error = error.localizedDescription }
            }
        }
    }
    func tag(_ name: String) {
        let items = selectedItems
        guard !items.isEmpty else { return }
        prepareOperations(name: "Tags") {
            try items.map { hit in
                try Task.checkCancellation()
                var tags = (try? hit.url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
                if tags.contains(name) { tags.removeAll { $0 == name } } else { tags.append(name) }
                return .tags(hit.url, tags)
            }
        }
    }
}
