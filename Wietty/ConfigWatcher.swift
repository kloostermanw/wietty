import Foundation

/// Watches a workspace folder for changes to its contents (including creating,
/// modifying, or deleting `wietty.json`) using a DispatchSource on the
/// directory file descriptor. Calls `onChange` on the main queue.
final class ConfigWatcher {
    private let folder: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(folder: URL, onChange: @escaping () -> Void) {
        self.folder = folder
        self.onChange = onChange
    }

    func start() {
        stop()
        let folder = self.folder
        let scoped = folder.startAccessingSecurityScopedResource()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            if scoped { folder.stopAccessingSecurityScopedResource() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.onChange() }
        src.setCancelHandler {
            close(fd)
            if scoped { folder.stopAccessingSecurityScopedResource() }
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
