import SwiftUI

/// A read-only, auto-scrolling view of one process's output, for the pane.
///
/// The process is looked up by `ProcessLogRef` on every redraw rather than held,
/// because a process can be stopped, restarted, or removed from the config while
/// its log is on screen. Looking it up is what makes the "not found" state a real
/// answer instead of a stale object.
struct ProcessLogView: View {
    let store: ProjectStore
    let log: ProcessLogRef

    private var process: ManagedProcess? {
        if log.isCheck {
            return store.checkSupervisor.check(projectId: log.projectId, name: log.name)
        }
        return log.isTest
            ? store.testSupervisor.test(projectId: log.projectId, name: log.name)
            : store.processes.process(projectId: log.projectId, name: log.name)
    }

    var body: some View {
        Group {
            if let process {
                ScrollViewReader { proxy in
                    ScrollView {
                        // One `Text` per line inside a `LazyVStack`, rather than a
                        // single `Text` of the whole joined buffer. A lone selectable
                        // `Text` lays out in O(content size) synchronously on the main
                        // thread, so a large log (or one runaway line) froze the app;
                        // the lazy stack only lays out the rows on screen. The cost is
                        // that selection no longer spans lines, it is per row.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(process.log.lines.enumerated()), id: \.offset) { _, line in
                                // A blank line renders as a space so it keeps a row's
                                // height instead of collapsing to nothing.
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .onChange(of: process.log.lines.count) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            } else {
                // Reachable while the log is on screen: removing the workspace, or
                // an edited config that no longer declares this process, takes the
                // row away underneath it.
                ContentUnavailableView("Process not found", systemImage: "bolt.slash")
            }
        }
        // The pane's own minimums, for the reason `LocalTerminalView` gives: a
        // view that asks only for its content leaves the split as tall as its
        // content, at the bottom of the window.
        .frame(minWidth: SidebarWidth.paneMinimum,
               minHeight: SidebarWidth.paneMinimumHeight,
               maxHeight: .infinity)
    }
}
