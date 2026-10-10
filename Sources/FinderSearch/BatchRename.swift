import SwiftUI
import Darwin

struct RenameMove: Equatable, Sendable {
    let source: URL
    let destination: URL
}
struct BatchRenameSpec: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case replace = "Replace Text", add = "Add Text", number = "Numbered Names"
    }
    var mode: Mode = .replace
    var find = ""
    var text = ""
    var start = 1
}

enum BatchRenames {
    static func plan(_ hits: [Hit], spec: BatchRenameSpec) throws -> [RenameMove] {
        var destinations = Set<String>()
        var caseSensitive: [String: Bool] = [:]
        return try hits.enumerated().map { index, hit in
            let ext = hit.isFolder ? "" : hit.url.pathExtension
            let stem = ext.isEmpty ? hit.name : hit.url.deletingPathExtension().lastPathComponent
            let name: String
            guard spec.start >= 0, spec.start <= Int.max - hits.count else {
                throw Engine.Failure.message("Choose a valid starting number.")
            }
            switch spec.mode {
            case .replace:
                name =
                    spec.find.isEmpty
                    ? stem : stem.replacingOccurrences(of: spec.find, with: spec.text)
            case .add: name = stem + spec.text
            case .number: name = spec.text + " " + String(spec.start + index)
            }
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                !name.contains("\0"), !name.contains(":")
            else {
                throw Engine.Failure.message(
                    "Names cannot be empty or contain /, : or a null character.")
            }
            let destination = hit.url.deletingLastPathComponent().appendingPathComponent(
                name + (ext.isEmpty ? "" : "." + ext))
            let parent = hit.url.deletingLastPathComponent()
            if caseSensitive[parent.path] == nil {
                caseSensitive[parent.path] =
                    (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                        .volumeSupportsCaseSensitiveNames) ?? true
            }
            let key =
                caseSensitive[parent.path] == false
                ? destination.path.lowercased() : destination.path
            guard destinations.insert(key).inserted else {
                throw Engine.Failure.message("Each item needs a different name.")
            }
            return RenameMove(source: hit.url, destination: destination)
        }.filter { $0.source != $0.destination }
    }
    static func identity(_ url: URL) -> String? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
    static func validate(_ moves: [RenameMove], control: FileOperationControl? = nil) throws {
        let sources = Set(moves.map { $0.source.path })
        let identities = Set(moves.compactMap { identity($0.source) })
        for move in moves {
            try Task.checkCancellation(); try control?.checkCancellation()
            guard LocalFiles.exists(move.source) else { throw CocoaError(.fileReadNoSuchFile) }
            if LocalFiles.exists(move.destination), !sources.contains(move.destination.path),
                !(move.source.path.caseInsensitiveCompare(move.destination.path) == .orderedSame
                    && identities.contains(identity(move.destination) ?? ""))
            {
                throw Engine.Failure.message(
                    "“\(move.destination.lastPathComponent)” already exists.")
            }
        }
    }
    static func apply(_ moves: [RenameMove], control: FileOperationControl) -> FileBatch {
        var batch = FileBatch()
        var staged: [(move: RenameMove, temporary: URL, published: Bool)] = []
        do {
            try validate(moves, control: control)
            for (index, move) in moves.enumerated() {
                try control.checkCancellation()
                control.start(
                    item: move.source.lastPathComponent, completed: index, total: moves.count)
                let temporary = move.source.deletingLastPathComponent().appendingPathComponent(
                    ".FinderSearch-rename-" + UUID().uuidString)
                try NativeFileCopy.move(move.source, to: temporary, control: control)
                staged.append((move, temporary, false))
            }
            for index in staged.indices {
                try control.checkCancellation()
                try NativeFileCopy.move(
                    staged[index].temporary, to: staged[index].move.destination, control: control)
                staged[index].published = true
            }
            batch.inverse = [
                .renameBatch(
                    moves.map { RenameMove(source: $0.destination, destination: $0.source) })
            ]
        } catch {
            batch.cancelled = error is CancellationError
            if !batch.cancelled { batch.errors.append(error.localizedDescription) }
            // First vacate final names, then restore originals, so swaps roll back safely.
            let recovery = FileOperationControl()
            for index in staged.indices where staged[index].published {
                do {
                    try NativeFileCopy.move(
                        staged[index].move.destination, to: staged[index].temporary,
                        control: recovery)
                    staged[index].published = false
                } catch { batch.errors.append(error.localizedDescription) }
            }
            for entry in staged {
                let current = entry.published ? entry.move.destination : entry.temporary
                do {
                    try NativeFileCopy.move(current, to: entry.move.source, control: recovery)
                } catch {
                    batch.errors.append(
                        "Could not restore \(entry.move.source.lastPathComponent). Its file is at \(current.path)."
                    )
                    batch.inverse.append(.move(current, entry.move.source))
                }
            }
            batch.failed = [.renameBatch(moves)]
        }
        return batch
    }
}

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let hits: [Hit]
}
struct BatchRenameSheet: View {
    @ObservedObject var model: SearchModel
    let request: BatchRenameRequest
    @State private var spec = BatchRenameSpec()
    @State private var moves: [RenameMove] = []
    @State private var message: String?
    @State private var checking = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename \(request.hits.count) Items").font(.headline)
            Picker("Format", selection: $spec.mode) {
                ForEach(BatchRenameSpec.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if spec.mode == .replace { TextField("Find", text: $spec.find) }
            TextField(
                spec.mode == .number
                    ? "Name" : spec.mode == .add ? "Add after name" : "Replace with",
                text: $spec.text)
            if spec.mode == .number {
                Stepper("Start at \(spec.start)", value: $spec.start, in: 1...999_999)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(request.hits.prefix(200)), id: \.path) { hit in
                        HStack {
                            Text(hit.name).lineLimit(1).frame(
                                maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(
                                moves.first { $0.source.path == hit.path }?.destination
                                    .lastPathComponent ?? hit.name
                            )
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(10)
            }.frame(height: 230).background(
                .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            if let message {
                Text(message).foregroundStyle(.red).font(.callout)
            } else {
                Text(
                    checking
                        ? "Checking names…"
                        : "\(moves.count) names will change. File extensions are preserved."
                ).foregroundStyle(.secondary).font(.callout)
            }
            HStack {
                Button("Cancel") { model.batchRename = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") {
                    model.batchRename = nil
                    model.perform([.renameBatch(moves)], name: "Rename Items")
                }.keyboardShortcut(.defaultAction).disabled(
                    checking || message != nil || moves.isEmpty || model.busy)
            }
        }.padding(24).frame(width: 560)
            .task(id: spec) {
                checking = true; message = nil
                do {
                    let hits = request.hits, options = spec
                    let planned = try await BackgroundWork.run {
                        let planned = try BatchRenames.plan(hits, spec: options)
                        try BatchRenames.validate(planned); return planned
                    }
                    try Task.checkCancellation(); moves = planned; checking = false
                } catch is CancellationError {} catch {
                    moves = []; message = error.localizedDescription; checking = false
                }
            }
    }
}

extension SearchModel {
    func renameItems() {
        guard !busy, !selectedItems.isEmpty else { return }
        if selectedItems.count == 1 {
            rename()
        } else {
            batchRename = BatchRenameRequest(hits: selectedItems)
        }
    }
}
