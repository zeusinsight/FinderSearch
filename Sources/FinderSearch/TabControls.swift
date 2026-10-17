import SwiftUI
import AppKit

enum TabShortcut {
    case new, reopen
    static func command(for event: NSEvent) -> Self? {
        guard event.keyCode == 17, event.modifierFlags.contains(.command),
            event.modifierFlags.intersection([.option, .control]).isEmpty
        else { return nil }
        return event.modifierFlags.contains(.shift) ? .reopen : .new
    }
}

struct BrowserWindowCapture: NSViewRepresentable {
    let capture: (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowCaptureView { WindowCaptureView(capture: capture) }
    func updateNSView(_ view: WindowCaptureView, context: Context) { view.capture = capture }
}
final class WindowCaptureView: NSView {
    var capture: (NSWindow?) -> Void
    init(capture: @escaping (NSWindow?) -> Void) {
        self.capture = capture; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.capture(self.window)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MiddleClickTarget: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    var action: () -> Void
    func makeNSView(context: Context) -> MiddleClickView { MiddleClickView(action: action) }
    func updateNSView(_ view: MiddleClickView, context: Context) {
        view.action = action; view.isInteractionEnabled = isEnabled
    }
}
final class MiddleClickView: NSView {
    var isInteractionEnabled = true
    var action: () -> Void
    private var monitor: Any?
    init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, self.isInteractionEnabled, event.buttonNumber == 2,
                event.window === self.window,
                self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            self.action(); return nil
        }
    }
    // The overlay never competes with primary buttons or their drag gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// Observe mouse-down before native tables, context menus and text editors handle it.
/// The overlay itself never intercepts clicks or file drags.
struct PaneActivationTarget: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let activate: () -> Void
    func makeNSView(context: Context) -> PaneActivationView {
        PaneActivationView(activate: activate)
    }
    func updateNSView(_ view: PaneActivationView, context: Context) {
        view.activate = activate; view.isInteractionEnabled = isEnabled
    }
}

final class PaneActivationView: NSView {
    var isInteractionEnabled = true
    var activate: () -> Void
    private var monitor: Any?
    init(activate: @escaping () -> Void) {
        self.activate = activate; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, self.isInteractionEnabled, event.window === self.window,
                !self.isHiddenOrHasHiddenAncestor,
                self.bounds.width > 0, self.bounds.height > 0,
                self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            self.activate(); return event
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
