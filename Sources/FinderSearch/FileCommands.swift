import AppKit

/// User commands collect intent on the main actor; filesystem preparation runs in the background.
extension SearchModel {
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url)) }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false;
        panel.prompt = L10n.string("Open")
        if panel.runModal() == .OK, let url = panel.url { navigate(url) }
    }
    func goToFolder() {
        let alert = NSAlert(); alert.messageText = L10n.string("Go to Folder");
        alert.addButton(withTitle: L10n.string("Go"));
        alert.addButton(withTitle: L10n.string("Cancel"))
        let field = EditingTextField(string: location.path);
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
        prepareOperations(name: "New Folder", renameCreated: true) {
            [.folder(LocalFiles.availableName(in: folder, name: "untitled folder"))]
        }
    }
    func newTextFile() {
        guard canWriteHere else { return }
        let folder = location
        prepareOperations(name: "New Text File", renameCreated: true) {
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
    func copy(clipboard: FileClipboard? = nil) {
        (clipboard ?? .shared).write(selectedItems.map(\.url), cut: false)
    }
    func cut(clipboard: FileClipboard? = nil) {
        guard !busy else { return }
        (clipboard ?? .shared).write(selectedItems.map(\.url), cut: true)
    }
    func copyPath() {
        NSPasteboard.general.clearContents();
        NSPasteboard.general.setString(
            selectedItems.map(\.path).joined(separator: "\n"), forType: .string)
        FileClipboard.shared.refresh()
    }
    func paste(move: Bool = false, clipboard: FileClipboard? = nil) {
        guard canWriteHere, !busy else { return }
        let clipboard = clipboard ?? .shared
        let changeCount = clipboard.pasteboard.changeCount
        transfer(clipboard.urls, to: location, move: move || clipboard.isCut) { successful in
            clipboard.finish(successful, changeCount: changeCount)
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
                    L10n.format(
                        "Kind: %@\nSize: %@\nModified: %@\nWhere: %@\nTags: %@", item.typeName,
                        ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: item.size), countStyle: .file),
                        item.modified.formatted(), item.parent, details.1.joined(separator: ", "))
                alert.addButton(withTitle: L10n.string("OK")); alert.runModal()
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
                var tags = FileTag.read(hit.url)
                if tags.contains(where: { $0.name == name }) {
                    tags.removeAll { $0.name == name }
                } else {
                    tags.append(FileTag(name: name, color: FileTag.color(for: name)))
                }
                return .tags(hit.url, tags.map(\.storageValue))
            }
        }
    }
}
