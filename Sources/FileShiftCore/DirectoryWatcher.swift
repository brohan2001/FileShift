import Foundation
import Darwin

/// Watches a single directory's entries (not its subfolders) with a kqueue-backed
/// Dispatch source. Fires on entry add/remove/rename; costs nothing while idle.
/// If the directory itself is deleted, renamed or revoked, it re-opens the path.
final class DirectoryWatcher {
    let path: String
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private let onError: (FSError) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var stopped = true

    init(path: String, queue: DispatchQueue, onChange: @escaping () -> Void, onError: @escaping (FSError) -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
        self.onError = onError
    }

    /// Must be called on `queue`.
    func start() throws {
        stopped = false
        try open()
    }

    /// Must be called on `queue`.
    func stop() {
        stopped = true
        source?.cancel()
        source = nil
    }

    private func open() throws {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { throw FSError(op: "open", path: path, code: errno) }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let ev = src.data
            if !ev.intersection([.delete, .rename, .revoke]).isEmpty {
                self.reopenLater()
            } else {
                self.onChange()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func reopenLater() {
        source?.cancel()
        source = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.stopped, self.source == nil else { return }
            do {
                try self.open()
                self.onChange()
            } catch let e as FSError {
                self.onError(e)
                self.reopenLater()
            } catch {}
        }
    }
}
