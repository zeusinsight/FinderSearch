import SwiftUI
import AppKit

/// Keep toolbar segments and symbol images stable while folder content changes.
struct ViewModePicker: NSViewRepresentable {
    @Binding var selection: FileViewMode
    private static let width: CGFloat = 150
    private static let height: CGFloat = 28

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        makeControl(coordinator: context.coordinator)
    }

    func makeControl(coordinator: Coordinator) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            frame: NSRect(
                x: 0, y: 0,
                width: Self.width, height: Self.height))
        control.segmentCount = FileViewMode.allCases.count
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        control.target = coordinator
        control.action = #selector(Coordinator.selectMode(_:))
        control.setAccessibilityLabel("View")
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        for (index, mode) in FileViewMode.allCases.enumerated() {
            let image = NSImage(
                systemSymbolName: mode.symbol, accessibilityDescription: mode.title)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setWidth(34, forSegment: index)
            control.setToolTip(mode.title, forSegment: index)
        }
        coordinator.update(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.update(control)
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<FileViewMode>
        init(selection: Binding<FileViewMode>) { self.selection = selection }

        func update(_ control: NSSegmentedControl) {
            let index = FileViewMode.allCases.firstIndex(of: selection.wrappedValue) ?? 0
            if control.selectedSegment != index { control.selectedSegment = index }
        }

        @objc func selectMode(_ control: NSSegmentedControl) {
            guard FileViewMode.allCases.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = FileViewMode.allCases[control.selectedSegment]
        }
    }
}
