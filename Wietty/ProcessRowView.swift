import SwiftUI

struct ProcessRowView: View {
    let process: ManagedProcess
    /// Whether this row's log is the one the pane is showing. A process row has no
    /// activate action, so this is the only thing that says a log came from here.
    var isSelected: Bool = false
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    let onKill: () -> Void
    let onOpenLog: () -> Void
    /// Copies this process's `ManagedProcessID` so a prompt can point an agent at its
    /// output through the MCP tools. Defaulted so a caller that never wires it (a
    /// preview, a render test) can leave it out.
    var onCopyId: () -> Void = {}

    @State private var isHovered = false

    private var dot: ProcessDot { processDot(for: process.state) }
    private var isRunning: Bool { processIsRunning(for: process.state) }

    var body: some View {
        HStack(spacing: 6) {
            dotView
            Text(process.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if process.state == .orphaned {
                Text("(orphan)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isHovered {
                actionButtons
            }
        }
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(highlight)
        .onHover { isHovered = $0 }
        .help(helpText)
        .contextMenu {
            Button("Start", action: onStart)
            Button("Stop", action: onStop)
            Button("Restart", action: onRestart)
            Button("Kill", action: onKill)
            Divider()
            Button("Open log", action: onOpenLog)
            Button("Copy ID for agent", action: onCopyId)
        }
    }

    // Not running shows a single play button; running shows stop + restart. A
    // process row always offers the log button.
    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 8) {
            if isRunning {
                RowActionButton(systemName: "stop.fill", help: "Stop", action: onStop)
                RowActionButton(systemName: "arrow.clockwise", help: "Restart", action: onRestart)
            } else {
                RowActionButton(systemName: "play.fill", help: "Start", action: onStart)
            }
            RowActionButton(systemName: "doc.plaintext", help: "Open log", action: onOpenLog)
        }
    }

    /// Selected wins over hovered, and which is which is `SidebarRowBackground`'s
    /// to say rather than this view's. The same fill a terminal row uses, because a
    /// marked row means the same thing in both: this is what the pane is showing.
    @ViewBuilder private var highlight: some View {
        if let fill = SidebarRowBackground.resolve(isSelected: isSelected,
                                                  isHovered: isHovered).fill {
            RoundedRectangle(cornerRadius: SidebarRowBackground.cornerRadius)
                .fill(fill)
        }
    }

    private var dotView: some View {
        Image(systemName: dot.fill == .filled ? "circle.fill" : "circle")
            .font(.system(size: 9))
            .foregroundStyle(color)
            // A fixed slot the width of the header chevron, so the dot sits in the
            // same left gutter and the process name lines up with the project name.
            .frame(width: 12, alignment: .center)
    }

    private var color: Color {
        switch dot.color {
        case .green: return .green
        case .red: return .red
        case .gray: return .secondary
        }
    }

    private var helpText: String {
        switch process.state {
        case .idle: return "Not running"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .finished: return "Finished (exit 0)"
        case .failed(let code): return "Failed (exit \(code))"
        case .stopping: return "Stopping…"
        case .orphaned: return "Running, but removed from wietty.json"
        }
    }
}
