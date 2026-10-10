import SwiftUI

struct BrowserTabBar: View {
    @ObservedObject var workspace: BrowserWorkspace
    var body: some View {
        GeometryReader { geometry in
            let width = min(
                220, max(120, (geometry.size.width - 44) / CGFloat(workspace.tabs.count)))
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(workspace.tabs) { tab in
                                BrowserTab(workspace: workspace, model: tab, width: width).id(
                                    tab.id)
                            }
                        }.padding(.horizontal, 6).padding(.vertical, 5)
                    }.scrollIndicators(.hidden)
                        .onChange(of: workspace.selectedTab) { _, id in proxy.scrollTo(id) }
                }
                Button {
                    workspace.newTab()
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                        .frame(width: 32, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).help("New Tab (⌘T)").accessibilityLabel("New Tab")
                    .padding(.trailing, 6)
            }
        }.frame(height: 40)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
    }
}

private struct BrowserTab: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var model: SearchModel
    let width: CGFloat
    @State private var hovering = false
    private var selected: Bool { workspace.selectedTab == model.id }
    var body: some View {
        HStack(spacing: 0) {
            Button {
                workspace.selectedTab = model.id
            } label: {
                HStack(spacing: 7) {
                    Image(
                        systemName: model.route == "recents"
                            ? "clock" : model.route.hasPrefix("tag:") ? "tag" : "folder"
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(model.title).font(.system(size: 12, weight: selected ? .medium : .regular))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.padding(.leading, 10).frame(maxWidth: .infinity).frame(height: 30)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            Button {
                workspace.closeTab(model.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy).help("Close Tab")
                .accessibilityLabel("Close \(model.title) tab")
        }.frame(width: width, height: 30)
            .background(
                selected
                    ? Color(nsColor: .controlBackgroundColor)
                    : hovering ? Color.primary.opacity(0.05) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(
                    selected ? Color(nsColor: .separatorColor).opacity(0.45) : .clear,
                    lineWidth: 0.5)
            }
            .contentShape(Rectangle()).onHover { hovering = $0 }
            .help(model.location.path)
            .overlay { MiddleClickTarget { workspace.closeTab(model.id) } }
            .draggable(model.id.uuidString)
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value),
                    workspace.tabs.contains(where: { $0.id == id })
                else { return false }
                workspace.moveTab(id, to: model.id); return true
            }
            .contextMenu {
                Button("New Tab") { workspace.newTab() }
                Button("Close Tab") { workspace.closeTab(model.id) }.disabled(model.busy)
                Button("Reopen Closed Tab") { workspace.reopenClosedTab() }.disabled(
                    workspace.closedTabs.isEmpty)
            }
    }
}
