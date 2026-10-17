import SwiftUI
import AppKit

/// Presets describe geometry only. The same file panes are reused by every layout.
enum PaneLayout: String, CaseIterable, Codable, Identifiable {
    case single, columns2, rows2, grid
    case leftOneRightTwo, leftTwoRightOne, topOneBottomTwo, topTwoBottomOne
    case rows3, columns3, columns4, rows4

    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: return "Single Pane"
        case .columns2: return "Two Columns"
        case .rows2: return "Two Rows"
        case .grid: return "Four-Pane Grid"
        case .leftOneRightTwo: return "One Left, Two Right"
        case .leftTwoRightOne: return "Two Left, One Right"
        case .topOneBottomTwo: return "One Top, Two Bottom"
        case .topTwoBottomOne: return "Two Top, One Bottom"
        case .rows3: return "Three Rows"
        case .columns3: return "Three Columns"
        case .columns4: return "Four Columns"
        case .rows4: return "Four Rows"
        }
    }
    var tree: PaneSplit {
        switch self {
        case .single: return .pane(0)
        case .columns2: return .split(.horizontal, [.pane(0), .pane(1)])
        case .rows2: return .split(.vertical, [.pane(0), .pane(1)])
        case .grid:
            return .split(
                .horizontal,
                [
                    .split(.vertical, [.pane(0), .pane(1)]),
                    .split(.vertical, [.pane(2), .pane(3)]),
                ])
        case .leftOneRightTwo:
            return .split(.horizontal, [.pane(0), .split(.vertical, [.pane(1), .pane(2)])])
        case .leftTwoRightOne:
            return .split(.horizontal, [.split(.vertical, [.pane(0), .pane(1)]), .pane(2)])
        case .topOneBottomTwo:
            return .split(.vertical, [.pane(0), .split(.horizontal, [.pane(1), .pane(2)])])
        case .topTwoBottomOne:
            return .split(.vertical, [.split(.horizontal, [.pane(0), .pane(1)]), .pane(2)])
        case .rows3: return .split(.vertical, (0..<3).map { .pane($0) })
        case .columns3: return .split(.horizontal, (0..<3).map { .pane($0) })
        case .columns4: return .split(.horizontal, (0..<4).map { .pane($0) })
        case .rows4: return .split(.vertical, (0..<4).map { .pane($0) })
        }
    }
    var paneCount: Int { tree.paneCount }
}

indirect enum PaneSplit {
    case pane(Int)
    case split(Axis, [PaneSplit])

    var paneCount: Int {
        switch self {
        case .pane: return 1
        case .split(_, let children): return children.reduce(0) { $0 + $1.paneCount }
        }
    }
    var minimumSize: CGSize {
        switch self {
        case .pane: return CGSize(width: 160, height: 100)
        case .split(let axis, let children):
            let sizes = children.map(\.minimumSize)
            let gaps = CGFloat(children.count - 1) * PaneGeometry.dividerWidth
            return CGSize(
                width: axis == .horizontal
                    ? sizes.reduce(gaps) { $0 + $1.width } : sizes.map(\.width).max() ?? 0,
                height: axis == .vertical
                    ? sizes.reduce(gaps) { $0 + $1.height } : sizes.map(\.height).max() ?? 0)
        }
    }
}

struct PaneDivider: Identifiable {
    let id: String
    let splitID: String
    let index: Int
    let axis: Axis
    let frame: CGRect
    let lengths: [CGFloat]
    let minimums: [CGFloat]

    /// Resize only the two adjacent children. All other dividers stay put.
    func weights(movingBy delta: CGFloat) -> [Double] {
        var result = lengths
        let change = min(
            max(delta, minimums[index] - lengths[index]),
            lengths[index + 1] - minimums[index + 1])
        result[index] += change
        result[index + 1] -= change
        let total = result.reduce(0, +)
        return result.map { Double($0 / max(total, 1)) }
    }
}

struct PaneGeometry {
    static let dividerWidth: CGFloat = 6
    var panes: [Int: CGRect] = [:]
    var dividers: [PaneDivider] = []

    init(tree: PaneSplit, size: CGSize, weights: [String: [Double]] = [:]) {
        arrange(tree, in: CGRect(origin: .zero, size: size), path: "root", weights: weights)
    }

    private mutating func arrange(
        _ node: PaneSplit, in frame: CGRect, path: String, weights: [String: [Double]]
    ) {
        switch node {
        case .pane(let index): panes[index] = frame
        case .split(let axis, let children):
            let extent = axis == .horizontal ? frame.width : frame.height
            let gap = min(Self.dividerWidth, extent / CGFloat(children.count * 2))
            let available = max(0, extent - gap * CGFloat(children.count - 1))
            let desired = children.map {
                axis == .horizontal ? $0.minimumSize.width : $0.minimumSize.height
            }
            // Small windows remain usable; larger ones enforce useful minimum pane sizes.
            let scale = min(1, available / max(desired.reduce(0, +), 1))
            let minimums = desired.map { $0 * scale }
            let saved = weights[path] ?? []
            let valid = saved.count == children.count && saved.allSatisfy { $0.isFinite && $0 > 0 }
            let values = valid ? saved : Array(repeating: 1.0, count: children.count)
            let largest = values.max() ?? 1
            let normalized = values.map { $0 / largest }
            let total = normalized.reduce(0, +)
            var lengths = normalized.map { CGFloat($0 / total) * available }
            // Clamp undersized children, taking only spare space from the others.
            let deficit = lengths.indices.reduce(CGFloat.zero) {
                $0 + max(0, minimums[$1] - lengths[$1])
            }
            let spare = lengths.indices.reduce(CGFloat.zero) {
                $0 + max(0, lengths[$1] - minimums[$1])
            }
            for i in lengths.indices {
                lengths[i] =
                    lengths[i] < minimums[i]
                    ? minimums[i]
                    : lengths[i] - (spare > 0 ? deficit * (lengths[i] - minimums[i]) / spare : 0)
            }
            var offset: CGFloat = 0
            for i in children.indices {
                let childFrame =
                    axis == .horizontal
                    ? CGRect(
                        x: frame.minX + offset, y: frame.minY, width: lengths[i],
                        height: frame.height)
                    : CGRect(
                        x: frame.minX, y: frame.minY + offset, width: frame.width,
                        height: lengths[i])
                arrange(children[i], in: childFrame, path: "\(path).\(i)", weights: weights)
                offset += lengths[i]
                if i < children.count - 1 {
                    let dividerFrame =
                        axis == .horizontal
                        ? CGRect(
                            x: frame.minX + offset, y: frame.minY, width: gap, height: frame.height)
                        : CGRect(
                            x: frame.minX, y: frame.minY + offset, width: frame.width, height: gap)
                    dividers.append(
                        PaneDivider(
                            id: "\(path).divider\(i)", splitID: path, index: i, axis: axis,
                            frame: dividerFrame, lengths: lengths, minimums: minimums))
                    offset += gap
                }
            }
        }
    }
}

/// A flat, identity-stable view collection sits inside recursively computed geometry.
/// Changing the split tree never reparents or recreates a pane's SwiftUI/AppKit content.
struct ResizablePaneLayout<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let layout: PaneLayout
    @Binding var weights: [String: [Double]]
    @ViewBuilder var content: (Item) -> Content
    @State private var lastSizes: [Item.ID: CGSize] = [:]

    var body: some View {
        GeometryReader { proxy in
            let geometry = PaneGeometry(tree: layout.tree, size: proxy.size, weights: weights)
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let frame = geometry.panes[index]
                    let size = frame?.size ?? lastSizes[item.id] ?? .zero
                    content(item)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .opacity(frame == nil ? 0 : 1)
                        .disabled(frame == nil)
                        .allowsHitTesting(frame != nil)
                        .accessibilityHidden(frame == nil)
                        .offset(x: frame?.minX ?? 0, y: frame?.minY ?? 0)
                }
                ForEach(geometry.dividers) { divider in
                    PaneDividerHandle(divider: divider) { weights[divider.splitID] = $0 }
                        .id("\(layout.rawValue).\(divider.id)")
                        .offset(x: divider.frame.minX, y: divider.frame.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: "paneLayout")
            .onChange(of: geometry.panes, initial: true) { _, frames in
                for (index, frame) in frames where items.indices.contains(index) {
                    lastSizes[items[index].id] = frame.size
                }
            }
        }
    }
}

private struct PaneDividerHandle: View {
    let divider: PaneDivider
    let resize: ([Double]) -> Void
    @State private var start: PaneDivider?
    private var percent: Int { Int(divider.weights(movingBy: 0)[divider.index] * 100) }
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(width: divider.frame.width, height: divider.frame.height)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (divider.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown)
                        .set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("paneLayout"))
                    .onChanged { value in
                        if start == nil { start = divider }
                        guard let start else { return }
                        let delta =
                            start.axis == .horizontal
                            ? value.translation.width : value.translation.height
                        resize(start.weights(movingBy: delta))
                    }
                    .onEnded { _ in
                        start = nil; NSCursor.arrow.set()
                    }
            )
            .accessibilityLabel("Resize panes")
            .accessibilityValue("\(percent) percent")
            .accessibilityAdjustableAction { direction in
                resize(divider.weights(movingBy: direction == .increment ? 20 : -20))
            }
    }
}

struct PaneLayoutIcon: View {
    let layout: PaneLayout
    var body: some View {
        Canvas { context, size in
            let geometry = PaneGeometry(tree: layout.tree, size: CGSize(width: 320, height: 240))
            for frame in geometry.panes.values {
                let scaled = CGRect(
                    x: frame.minX / 320 * size.width + 1, y: frame.minY / 240 * size.height + 1,
                    width: frame.width / 320 * size.width - 2,
                    height: frame.height / 240 * size.height - 2)
                context.stroke(
                    Path(roundedRect: scaled, cornerRadius: 1), with: .foreground, lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

struct PaneLayoutPicker: View {
    @ObservedObject var workspace: BrowserWorkspace
    @State private var showing = false
    var body: some View {
        Button {
            showing.toggle()
        } label: {
            PaneLayoutIcon(layout: workspace.layout)
                .frame(width: 22, height: 16)
                .frame(width: 30, height: 24)
        }
        .help("Pane Layout").accessibilityLabel("Pane Layout")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48)), count: 4), spacing: 8) {
                ForEach(PaneLayout.allCases) { layout in
                    Button {
                        workspace.setLayout(layout); showing = false
                    } label: {
                        PaneLayoutIcon(layout: layout)
                            .frame(width: 30, height: 24)
                            .frame(width: 44, height: 38)
                            .background(
                                workspace.layout == layout
                                    ? Color.accentColor.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!workspace.canSetLayout(layout))
                    .help(
                        workspace.canSetLayout(layout)
                            ? layout.title : "Finish file operations before hiding their panes"
                    )
                    .accessibilityLabel(layout.title)
                    .accessibilityAddTraits(workspace.layout == layout ? [.isSelected] : [])
                }
            }.padding(12)
        }
    }
}
