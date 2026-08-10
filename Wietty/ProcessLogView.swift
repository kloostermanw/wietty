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
        log.isTest
            ? store.testSupervisor.test(projectId: log.projectId, name: log.name)
            : store.processes.process(projectId: log.projectId, name: log.name)
    }

    var body: some View {
        Group {
            if let process {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(process.log.lines.joined(separator: "\n"))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
