import SwiftUI

/// Draw placeholders in one pass without creating file cells, loading icons,
/// or adding animation work while the filesystem is busy.
struct FolderLoadingSkeleton: View {
    let mode: FileViewMode
    var iconSize: Double = 64

    var body: some View {
        VStack(spacing: 0) {
            if mode == .list {
                HStack(spacing: 0) {
                    Text("Name").frame(width: 300, alignment: .leading)
                    Text("Date Modified").frame(width: 180, alignment: .leading)
                    Text("Size").frame(width: 85, alignment: .leading)
                    Text("Kind").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11)).padding(.leading, 18).frame(height: 27)
                .clipped()
                Divider()
            }
            Canvas { context, size in draw(context: context, size: size) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading files")
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let color = Color(nsColor: .tertiaryLabelColor).opacity(0.35)
        func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, radius: Double = 3) {
            guard w > 0 else { return }
            context.fill(
                Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius),
                with: .color(color))
        }
        switch mode {
        case .list, .columns:
            let inset = mode == .list ? 18.0 : 12.0
            for row in 0..<min(60, Int(size.height / 24) + 1) {
                let y = Double(row) * 24
                block(inset, y + 4, 16, 16)
                let width = mode == .list ? 210.0 : max(40, size.width - 62)
                block(inset + 24, y + 8, width * [0.8, 0.6, 0.95, 0.7][row % 4], 8)
                if mode == .list {
                    block(318, y + 8, 112, 8)
                    block(526, y + 8, 48, 8)
                    block(588, y + 8, min(94, size.width - 600), 8)
                }
            }
        case .icons:
            let count = max(1, Int((size.width - 36) / (iconSize + 69)))
            let cell = max(iconSize + 55, (size.width - 36) / Double(count))
            let height = iconSize + 72
            for row in 0..<min(12, Int(size.height / height) + 1) {
                for column in 0..<count {
                    let x = 18.0 + Double(column) * cell + (cell - iconSize) / 2
                    let y = 24.0 + Double(row) * height
                    block(x, y, iconSize, iconSize, radius: 5)
                    block(x - 7, y + iconSize + 14, iconSize + 14, 8)
                    block(x + 8, y + iconSize + 28, max(24, iconSize - 16), 8)
                }
            }
        case .gallery:
            let width = min(300, size.width * 0.5)
            let height = min(240, max(60, size.height - 170))
            block(
                (size.width - width) / 2, max(20, (size.height - 115 - height) / 2), width, height,
                radius: 5)
            for column in 0..<min(20, Int(size.width / 110) + 1) {
                let x = 23.0 + Double(column) * 110
                block(x, max(0, size.height - 100), 64, 64, radius: 5)
                block(x - 8, max(0, size.height - 25), 80, 8)
            }
        }
    }
}
