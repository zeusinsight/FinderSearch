import SwiftUI

/// Results of a content search: one row per file with the lines that matched.
/// Files come from the engine's content index; each row stays a normal file,
/// so selection, opening, and the file actions behave like any other result.
struct ContentResultsView: View {
    @ObservedObject var model: SearchModel
    let select: (Hit) -> Void
    private let modes: [(String, String)] = [
        ("Text", "literal"), ("Regex", "regex"), ("Symbol", "symbol"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.searching && model.sortedHits.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Searching file contents…").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sortedHits.isEmpty {
                empty
            } else {
                results
            }
        }
    }

    /// The match-mode picker stays available even without results: switching
    /// to a regular expression is often the fix for an empty literal search.
    private var header: some View {
        HStack(spacing: 10) {
            Picker("Match", selection: $model.contentMode) {
                ForEach(modes, id: \.1) { title, tag in Text(title).tag(tag) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            .help("Match plain text, a regular expression, or the definition of a symbol")
            Spacer()
            if !model.sortedHits.isEmpty {
                Text(summary)
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(
                model.error == nil ? "No Matches" : "Search Unavailable",
                systemImage: model.error == nil
                    ? "doc.text.magnifyingglass" : "exclamationmark.triangle")
        } description: {
            if model.error == nil {
                Text(
                    "No text files contain “\(model.query)”. Contents are searched in text "
                        + "files such as code, Markdown, and plain text.")
            } else {
                Text("The search could not complete. Check the message above and try again.")
            }
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sortedHits) { hit in row(hit) }
                }.padding(.vertical, 4)
            }
            .onChange(of: model.focusedPath) { _, path in if let path { proxy.scrollTo(path) } }
        }
    }

    private var summary: String {
        var parts = ["\(model.sortedHits.count) files"]
        parts.append(model.contentSource == "scan" ? "read from disk" : "content index")
        if !model.contentComplete { parts.append("partial") }
        if model.contentIndexing > 0 { parts.append("indexing \(model.contentIndexing) files") }
        return parts.joined(separator: " · ")
    }

    private func row(_ hit: Hit) -> some View {
        let matches = model.matches(for: hit.path)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                FileIcon(hit: hit).frame(width: 16, height: 16)
                Text(hit.name).font(.system(size: 13)).lineLimit(1)
                Text(hit.parent).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(matches.count) \(matches.count == 1 ? "match" : "matches")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(matches.prefix(2).enumerated()), id: \.offset) { _, match in
                Text("\(match.line): \(match.text.trimmingCharacters(in: .whitespaces))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if matches.count > 2 {
                Text("\(matches.count - 2) more \(matches.count == 3 ? "match" : "matches")…")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            model.selection.contains(hit.path) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { select(hit); model.open(hit) }
        .onTapGesture { select(hit) }
        .contextMenu { rowMenu(hit) }
        .draggable(hit.url)
        .modifier(FolderDropTarget(hit: hit, model: model))
        .id(hit.path)
        .accessibilityLabel("\(hit.name), \(matches.count) matches")
        .accessibilityAddTraits(model.selection.contains(hit.path) ? [.isSelected] : [])
    }

    @ViewBuilder private func rowMenu(_ hit: Hit) -> some View {
        Button("Open") { contextual(hit); model.open(hit) }
        Button("Open Enclosing Folder") { model.navigate(hit.url.deletingLastPathComponent()) }
            .disabled(model.busy)
        Divider()
        Button("Get Info") { contextual(hit); model.info() }
        Button("Quick Look") { contextual(hit); model.preview = hit }
        Button("Copy") { contextual(hit); model.copy() }
        Button("Copy Path") { contextual(hit); model.copyPath() }
        Divider()
        Button("Move to Trash") { contextual(hit); model.trash() }.disabled(model.busy)
    }

    private func contextual(_ hit: Hit) {
        if !model.selection.contains(hit.path) { model.selection = [hit.path] }
    }
}
