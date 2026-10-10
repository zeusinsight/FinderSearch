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
    var action: () -> Void
    func makeNSView(context: Context) -> MiddleClickView { MiddleClickView(action: action) }
    func updateNSView(_ view: MiddleClickView, context: Context) { view.action = action }
}
final class MiddleClickView: NSView {
    var action: () -> Void
    private var monitor: Any?
    init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, event.buttonNumber == 2, event.window === self.window,
                self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            self.action(); return nil
        }
    }
    // The overlay never competes with primary buttons or their drag gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
