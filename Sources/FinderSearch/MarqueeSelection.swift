import AppKit
import SwiftUI

/// Selection is always derived from the mouse-down snapshot, so shrinking a
/// rectangle or reversing direction does not leave previously touched files selected.
struct MarqueeSelection {
    let anchor: CGPoint
    let original: Set<String>
    let modifiers: NSEvent.ModifierFlags

    func rectangle(to point: CGPoint) -> CGRect {
        CGRect(
            x: min(anchor.x, point.x), y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
    }

    func selection(intersecting paths: Set<String>) -> Set<String> {
        if modifiers.contains(.command) { return original.symmetricDifference(paths) }
        if modifiers.contains(.shift) { return original.union(paths) }
        return paths
    }
}

struct MarqueeItemBounds: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func marqueeItem(_ path: String, in space: UUID) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MarqueeItemBounds.self,
                    value: [path: geometry.frame(in: .named("marquee-\(space)"))])
            }
        }
    }

    func marqueeSelection(model: SearchModel, focusFiles: @escaping () -> Void) -> some View {
        modifier(MarqueeSelectionModifier(model: model, focusFiles: focusFiles))
    }
}

private struct MarqueeSelectionModifier: ViewModifier {
    @ObservedObject var model: SearchModel
    let focusFiles: () -> Void
    @State private var frames: [String: CGRect] = [:]

    func body(content: Content) -> some View {
        // Item bounds use the model ID; the modifier is attached to scroll content,
        // making those coordinates stable while the viewport scrolls.
        content.coordinateSpace(name: "marquee-\(model.id)")
            .onPreferenceChange(MarqueeItemBounds.self) { frames = $0 }
            .overlay {
                MarqueeOverlay(model: model, frames: frames, focusFiles: focusFiles)
            }
    }
}

private struct MarqueeOverlay: NSViewRepresentable {
    let model: SearchModel
    let frames: [String: CGRect]
    let focusFiles: () -> Void

    func makeNSView(context: Context) -> MarqueeSelectionView { MarqueeSelectionView() }
    func updateNSView(_ view: MarqueeSelectionView, context: Context) {
        view.configure(model: model, identity: model.route + ":" + model.query)
        view.itemFrames = frames
        view.focusFiles = focusFiles
    }
    static func dismantleNSView(_ view: MarqueeSelectionView, coordinator: ()) { view.stop() }
}

/// Observe only background mouse sequences. Returning nil from hitTest leaves
/// file clicks, contextual menus and native file dragging with their existing views.
@MainActor final class MarqueeSelectionView: NSView {
    var itemFrames: [String: CGRect] = [:]
    var focusFiles: () -> Void = {}
    weak var table: NSTableView?
    var pathForRow: ((Int) -> String?)?
    private weak var model: SearchModel?
    private var identity = ""
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var timer: Timer?
    private var gesture: MarqueeSelection?
    private var rememberedFrames: [String: CGRect] = [:]
    private var lastEvent: NSEvent?
    private var rectangle: CGRect?
    private var dragging = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(model: SearchModel, identity: String) {
        if self.model !== model || self.identity != identity || model.busy {
            stop()
        }
        self.model = model
        self.identity = identity
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        stop()
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, event.window === window, window != nil, !isHiddenOrHasHiddenAncestor else {
            return event
        }
        if event.type == .keyDown {
            guard gesture != nil, event.keyCode == 53 else { return event }
            model.selection = gesture!.original
            stop()
            return nil
        }
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            // SwiftUI's scroll hosting can report a visibleRect beyond our
            // bounds, including the sidebar. Never consume clicks outside the
            // file content, even if AppKit considers those coordinates visible.
            guard !model.busy, bounds.contains(point), visibleRect.contains(point),
                event.clickCount == 1
            else {
                return event
            }
            if let table {
                guard table.row(at: table.convert(event.locationInWindow, from: nil)) < 0 else {
                    return event
                }
            } else if itemFrames.values.contains(where: { $0.contains(point) }) {
                return event
            }
            gesture = MarqueeSelection(
                anchor: point, original: model.selection, modifiers: event.modifierFlags)
            rememberedFrames = itemFrames
            window?.makeKey()
            model.cancelRename()
            focusFiles()
            return nil
        case .leftMouseDragged:
            guard gesture != nil else { return event }
            lastEvent = event
            updateSelection(event)
            if timer == nil {
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let event = self.lastEvent else { return }
                        guard self.window != nil else { self.stop(); return }
                        if self.autoscroll(with: event) { self.updateSelection(event) }
                    }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return nil
        case .leftMouseUp:
            guard let gesture else { return event }
            if dragging {
                updateSelection(event)
            } else {
                model.selection = gesture.selection(intersecting: [])
            }
            stop()
            return nil
        default: return event
        }
    }

    private func updateSelection(_ event: NSEvent) {
        guard let gesture, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = gesture.rectangle(to: point)
        guard dragging || max(rect.width, rect.height) >= 4 else { return }
        dragging = true
        model.marqueeSelecting = true
        rectangle = rect
        let paths: Set<String>
        if let table {
            let rows = table.rows(in: table.convert(rect, from: self))
            paths =
                rows.location == NSNotFound
                ? []
                : Set(
                    (rows.location..<NSMaxRange(rows)).compactMap { pathForRow?($0) })
        } else {
            rememberedFrames.merge(itemFrames, uniquingKeysWith: { _, new in new })
            paths = Set(rememberedFrames.compactMap { rect.intersects($0.value) ? $0.key : nil })
        }
        let selected = gesture.selection(intersecting: paths)
        if model.selection != selected { model.selection = selected }
        needsDisplay = true
    }

    func stop() {
        model?.marqueeSelecting = false
        timer?.invalidate(); timer = nil
        gesture = nil; rectangle = nil; lastEvent = nil
        rememberedFrames.removeAll(); dragging = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rectangle else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        rectangle.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        let outline = NSBezierPath(rect: rectangle.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    deinit {
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}
