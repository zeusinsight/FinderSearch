import SwiftUI
import AppKit

/// The same native editor is used by SwiftUI file views and AppKit table cells.
@MainActor final class RenameTextField: NSTextField, NSTextFieldDelegate {
    private(set) var editingPath: String?
    private var commit: ((String) -> Bool)?
    private var cancel: (() -> Void)?
    private var finishing = false
    private var originalName = ""
    private var nameRange = NSRange(location: 0, length: 0)
    private var wantsFocus = false
    private var pendingInput: (() -> [NSEvent])?

    static func selectedNameRange(_ hit: Hit) -> NSRange {
        let name = hit.name as NSString
        let suffix = (hit.name as NSString).pathExtension
        let length =
            hit.kind == "dir" || suffix.isEmpty
            ? name.length : max(0, name.length - (suffix as NSString).length - 1)
        return NSRange(location: 0, length: length)
    }

    func begin(_ hit: Hit, commit: @escaping (String) -> Bool, cancel: @escaping () -> Void,
               pendingInput: @escaping () -> [NSEvent] = { [] }) {
        self.pendingInput = pendingInput
        guard editingPath != hit.path else { return }
        editingPath = hit.path; self.commit = commit; self.cancel = cancel
        originalName = hit.name
        nameRange = Self.selectedNameRange(hit); wantsFocus = true
        stringValue = hit.name; isEditable = true; isSelectable = true
        isBordered = true; drawsBackground = true; backgroundColor = .textBackgroundColor
        textColor = .textColor; delegate = self
        setAccessibilityLabel("Rename \(hit.name)")
        requestFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { requestFocus() }
    }

    private func requestFocus(force: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let path = self.editingPath, self.wantsFocus || force,
                let window = self.window else { return }
            let selectName = self.wantsFocus
            guard window.makeFirstResponder(self), let editor = self.currentEditor() as? NSTextView else { return }
            self.wantsFocus = false
            if selectName { editor.selectedRange = self.nameRange }
            // Replay only keys the user actually typed while the folder/editor
            // was being prepared, directly into this editor, never globally.
            let events = self.pendingInput?() ?? []
            for event in events {
                guard self.editingPath == path else { break }
                editor.keyDown(with: event)
            }
        }
    }

    private static func field(in view: NSView, path: String) -> RenameTextField? {
        if let field = view as? RenameTextField, field.editingPath == path { return field }
        for child in view.subviews {
            if let field = field(in: child, path: path) { return field }
        }
        return nil
    }
    static func editorIsActive(in window: NSWindow, path: String?) -> Bool {
        guard let path, let content = window.contentView,
              let field = field(in: content, path: path), let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }
    static func focusPendingInput(in window: NSWindow, path: String?) {
        guard let path, let content = window.contentView else { return }
        field(in: content, path: path)?.requestFocus(force: true)
    }

    func end(resign: Bool = true) {
        finishing = true
        if resign, currentEditor() != nil {
            var parent = superview
            while let view = parent, !(view is NSTableView) { parent = view.superview }
            window?.makeFirstResponder(parent)
        }
        editingPath = nil; commit = nil; cancel = nil; pendingInput = nil
        wantsFocus = false
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        setAccessibilityLabel(nil)
        finishing = false
    }

    func cancelEditing(resign: Bool = true) {
        guard editingPath != nil else { return }
        cancel?(); end(resign: resign)
        stringValue = originalName
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if commit?(textView.string) == true { end() }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing(); return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if !finishing { cancelEditing(resign: false) }
    }
}

private struct RenameField: NSViewRepresentable {
    let hit: Hit
    let alignment: NSTextAlignment
    let commit: (String) -> Bool
    let cancel: () -> Void
    let pendingInput: () -> [NSEvent]

    func makeNSView(context: Context) -> RenameTextField {
        let field = RenameTextField(string: hit.name)
        field.font = .systemFont(ofSize: 12); field.alignment = alignment
        field.lineBreakMode = .byClipping; field.maximumNumberOfLines = 1
        field.begin(hit, commit: commit, cancel: cancel, pendingInput: pendingInput)
        return field
    }
    func updateNSView(_ field: RenameTextField, context: Context) {}
    static func dismantleNSView(_ field: RenameTextField, coordinator: ()) {
        // SwiftUI can replace its hosting view during a focus transition. The
        // replacement editor retains the session; teardown must not cancel it.
        field.end(resign: false)
    }
}

struct FileNameLabel: View {
    @ObservedObject var model: SearchModel
    let hit: Hit
    var lineLimit = 1
    var centered = false

    var body: some View {
        if model.renaming?.path == hit.path {
            RenameField(
                hit: hit, alignment: centered ? .center : .left,
                commit: { model.commitRename($0) }, cancel: { model.cancelRename() },
                pendingInput: { model.takeRenameInput(for: hit.path) }
            )
            .frame(height: 20)
        } else {
            HStack(spacing: 4) {
                Text(hit.name).font(.system(size: 12)).lineLimit(lineLimit)
                    .multilineTextAlignment(centered ? .center : .leading)
                FileTagIndicators(url: hit.metadataPending == true ? nil : hit.url)
                    .fixedSize()
            }
        }
    }
}
