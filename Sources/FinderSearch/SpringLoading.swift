import Foundation

/// A drag hover owns one delay. Repeated validation of the same row does not
/// restart it; leaving the row or dropping cancels it.
@MainActor final class SpringLoader {
    private var task: Task<Void, Never>?
    private var target: URL?
    func hover(
        _ url: URL?, delay: Duration = .milliseconds(650), open: @escaping @MainActor (URL) -> Void
    ) {
        guard target != url else { return }
        cancel(); target = url
        guard let url else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay); try Task.checkCancellation() } catch { return }
            guard self?.target == url else { return }
            self?.target = nil; self?.task = nil; open(url)
        }
    }
    func leave(_ url: URL) { if target == url { cancel() } }
    func cancel() { task?.cancel(); task = nil; target = nil }
    deinit { task?.cancel() }
}
extension SearchModel {
    func hoverFolder(_ url: URL?) {
        springLoader.hover(busy ? nil : url) { [weak self] folder in
            guard let self, !self.busy, folder != self.location else { return }
            self.navigate(folder)
        }
    }
}
