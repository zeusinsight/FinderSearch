import SwiftUI
import AppKit

enum ConflictChoice: String, CaseIterable { case replace, keepBoth, skip, cancel }
struct FileConflict: Identifiable {
    let id = UUID()
    let source: URL
    let destination: URL
}
struct TransferCandidate: Sendable {
    let source: URL
    let destination: URL
    let conflict: Bool
}

enum TransferPlan {
    static func candidates(_ urls: [URL], into folder: URL, move: Bool) throws
        -> [TransferCandidate]
    {
        let target = folder.resolvingSymlinksInPath().path
        var seen = Set<String>(), reserved = Set<String>()
        return try urls.filter { $0.isFileURL && seen.insert($0.path).inserted }.compactMap {
            source in
            try Task.checkCancellation()
            var destination = folder.appendingPathComponent(source.lastPathComponent)
            let resolvedSource = source.resolvingSymlinksInPath().path
            let prefix = resolvedSource == "/" ? "/" : resolvedSource + "/"
            if target == resolvedSource || target.hasPrefix(prefix) {
                throw Engine.Failure.message("A folder cannot be moved or copied inside itself.")
            }
            let canonicalSource = source.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(source.lastPathComponent)
            let canonicalDestination = folder.resolvingSymlinksInPath().appendingPathComponent(
                source.lastPathComponent)
            if canonicalSource.standardizedFileURL == canonicalDestination.standardizedFileURL {
                if move { return nil }
                destination = LocalFiles.availableName(
                    in: folder, name: source.lastPathComponent,
                    suffix: " copy", reserved: reserved)
            }
            let conflict = LocalFiles.exists(destination) || reserved.contains(destination.path)
            reserved.insert(destination.path)
            return TransferCandidate(source: source, destination: destination, conflict: conflict)
        }
    }
}

struct ConflictSheet: View {
    let conflict: FileConflict
    let choose: (ConflictChoice, Bool) -> Void
    @State private var applyToAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("“\(conflict.destination.lastPathComponent)” already exists").font(.headline)
            Text(
                "Choose what to do in \(conflict.destination.deletingLastPathComponent().path). Replace moves the existing item to Trash so Undo can restore it."
            )
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Apply to all conflicts in this operation", isOn: $applyToAll)
            HStack {
                Button("Cancel") { choose(.cancel, false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { choose(.skip, applyToAll) }
                Button("Keep Both") { choose(.keepBoth, applyToAll) }.keyboardShortcut(
                    .defaultAction)
                Button("Replace") { choose(.replace, applyToAll) }
            }
        }.padding(24).frame(width: 510)
    }
}

extension SearchModel {
    func resolveConflict(_ choice: ConflictChoice, applyToAll: Bool = false) {
        if applyToAll { allConflictChoice = choice }
        let continuation = conflictContinuation; conflictContinuation = nil
        conflict = nil; continuation?.resume(returning: choice)
    }
    func chooseConflict(_ candidate: TransferCandidate) async -> ConflictChoice {
        if let allConflictChoice { return allConflictChoice }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            conflict = FileConflict(source: candidate.source, destination: candidate.destination)
        }
    }
    func transfer(_ urls: [URL], to folder: URL, move: Bool) {
        guard !busy, !urls.isEmpty else { return }
        busy = true; error = nil; allConflictChoice = nil
        operationName = move ? "Move" : "Copy"
        operationProgress = FileOperationProgress()
        preparationTask = Task {
            do {
                let candidates = try await BackgroundWork.run {
                    try TransferPlan.candidates(urls, into: folder, move: move)
                }
                var operations: [FileMutation] = [], reserved = Set<String>()
                for candidate in candidates {
                    try Task.checkCancellation()
                    var destination = candidate.destination
                    var replacing = false
                    if candidate.conflict || reserved.contains(destination.path) {
                        switch await chooseConflict(candidate) {
                        case .cancel: throw CancellationError()
                        case .skip: continue
                        case .replace: replacing = true
                        case .keepBoth:
                            let used = reserved
                            destination = try await BackgroundWork.run {
                                LocalFiles.availableName(
                                    in: folder, name: candidate.destination.lastPathComponent,
                                    reserved: used)
                            }
                        }
                    }
                    try Task.checkCancellation()
                    reserved.insert(destination.path)
                    operations.append(
                        replacing
                            ? .replace(candidate.source, destination, move: move)
                            : move
                                ? .move(candidate.source, destination)
                                : .copy(candidate.source, destination))
                }
                busy = false; operationProgress = nil
                if !operations.isEmpty { perform(operations, name: move ? "Move" : "Copy") }
            } catch is CancellationError {
                resolveConflict(.cancel); busy = false; operationProgress = nil
            } catch {
                busy = false; operationProgress = nil; self.error = error.localizedDescription
            }
        }
    }
}
