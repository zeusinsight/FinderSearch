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

    static func selectedNameRange(_ hit: Hit) -> NSRange {
        let name = hit.name as NSString
        let suffix = (hit.name as NSString).pathExtension
        let length =
            hit.kind == "dir" || suffix.isEmpty
            ? name.length : max(0, name.length - (suffix as NSString).length - 1)
        return NSRange(location: 0, length: length)
    }

    func begin(_ hit: Hit, commit: @escaping (String) -> Bool, cancel: @escaping () -> Void) {
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

    private func requestFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editingPath != nil, self.wantsFocus,
                let window = self.window, window.makeFirstResponder(self) else { return }
            self.wantsFocus = false
            (self.currentEditor() as? NSTextView)?.selectedRange = self.nameRange
        }
    }

    func end(resign: Bool = true) {
        finishing = true
        if resign, currentEditor() != nil {
            var parent = superview
            while let view = parent, !(view is NSTableView) { parent = view.superview }
            window?.makeFirstResponder(parent)
        }
        editingPath = nil; commit = nil; cancel = nil
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

    func makeNSView(context: Context) -> RenameTextField {
        let field = RenameTextField(string: hit.name)
        field.font = .systemFont(ofSize: 12); field.alignment = alignment
        field.lineBreakMode = .byClipping; field.maximumNumberOfLines = 1
        field.begin(hit, commit: commit, cancel: cancel)
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
                commit: { model.commitRename($0) }, cancel: { model.cancelRename() }
            )
            .frame(height: 20)
        } else {
            Text(hit.name).font(.system(size: 12)).lineLimit(lineLimit)
                .multilineTextAlignment(centered ? .center : .leading)
        }
    }
}
