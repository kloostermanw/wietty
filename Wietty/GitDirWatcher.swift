import Foundation

/// Watches a workspace's `.git` for local state changes (commits, checkouts,
/// branch create/delete) and calls `onChange` on the main queue so the app can
/// re-read git state immediately instead of waiting for the next poll.
///
/// Mirrors `ConfigWatcher`'s `DispatchSource.makeFileSystemObjectSource`
/// pattern, but arms a source per stable path:
///
///  - `.git/logs/HEAD` — the reflog, appended in place on *every* HEAD movement
///    (commit, checkout, reset, merge, rebase). Its in-place growth is a stable
///    `.write`/`.extend` signal, so it needs no re-arming.
///  - `.git/refs/heads` — a directory whose entries change on branch
///    create/delete and on the ref rename a commit performs.
///
/// Best-effort by design: if `.git` is missing or a file (worktrees/submodules
/// store `.git` as a file, not a directory), or a path cannot be opened, that
/// path is simply skipped and the app keeps relying on periodic polling. Remote
/// pushes from other people are never a local disk event and stay poll-only.
///
/// Rapid bursts (a single commit touches several watched paths) are coalesced
/// into one `onChange` so callers do not run one git sync per touched file.
/// `@unchecked Sendable`: all mutable state is created and mutated only on the
/// main queue (the source and debounce callbacks run there), so the assertion
/// holds.
final class GitDirWatcher: @unchecked Sendable {
    private let workspace: URL
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var scoped = false
    private var coalescing = false

    /// Delay used to collapse a burst of file events into a single callback.
    private let coalesceInterval: DispatchTimeInterval = .milliseconds(300)

    init(workspace: URL, onChange: @escaping () -> Void) {
        self.workspace = workspace
        self.onChange = onChange
    }

    func start() {
        stop()
        let scoped = workspace.startAccessingSecurityScopedResource()
        let gitDir = workspace.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir),
              isDir.boolValue else {
            if scoped { workspace.stopAccessingSecurityScopedResource() }
            return
        }
        self.scoped = scoped
        arm(gitDir.appendingPathComponent("logs/HEAD"))
        arm(gitDir.appendingPathComponent("refs/heads"))
        // Nothing armed (unusual layout): release the scope now rather than hold
        // it for a watcher that can never fire.
        if sources.isEmpty { stop() }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        if scoped {
            workspace.stopAccessingSecurityScopedResource()
            scoped = false
        }
    }

    deinit { stop() }

    /// Opens `url` for event-only monitoring and adds a source for it. Silently
    /// skips paths that cannot be opened (missing reflog, packed refs, etc.).
    private func arm(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.poke() }
        source.setCancelHandler { close(fd) }
        sources.append(source)
        source.resume()
    }

    /// Coalesces a burst of events into a single `onChange`. The source events
    /// are coarse (they do not say what changed), so one debounced re-read is
    /// all that is needed.
    private func poke() {
        guard !coalescing else { return }
        coalescing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval) { [weak self] in
            guard let self else { return }
            self.coalescing = false
            self.onChange()
        }
    }
}
