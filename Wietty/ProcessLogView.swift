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
                        //
                        // Rows are keyed by `LogLine.id`, a stable sequence number,
                        // not by array index. When the buffer reaches its line cap and
                        // trims the oldest lines, an index-based id would shift under
                        // every surviving row, so SwiftUI would re-diff and re-lay out
                        // the whole list on each append (the hang in issue #65). The
                        // stable id lets it add and drop only the rows that changed.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(process.log.identifiedLines) { line in
                                // A blank line renders as a space so it keeps a row's
                                // height instead of collapsing to nothing.
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    // Keyed on the total number of lines ever produced, not on
                    // `lines.count`. Once the buffer reaches its cap, each append
                    // adds one line and trims one, so `lines.count` holds steady and
                    // an `onChange` on it would stop firing exactly when a process is
                    // streaming hard, leaving the pane stuck away from the tail.
                    // `firstLineNumber + lines.count` keeps climbing, so the view
                    // follows the tail past the cap.
                    .onChange(of: process.log.firstLineNumber + process.log.lines.count) {
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
