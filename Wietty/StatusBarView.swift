import SwiftUI
import AppKit

/// The bar along the bottom of the window, under both the sidebar and the pane.
///
/// It reports on the app itself rather than on anything in the pane, which is why it
/// spans the whole window instead of sitting in the right column the way `NavBarView`
/// does. On the left, the MCP server: whether it is listening, on which port, and a
/// Restart. A failure keeps its reason in the tooltip, and the same text is on the
/// MCP tab of Settings. On the right, how many terminals, agents, managed processes
/// and tests are running (`RunningProcessCounts`) and the app's own memory
/// (`AppMemory`).
///
/// Always present, for the reason `NavBarView` is: a bar that came and went would
/// move the terminal above it.
struct StatusBarView: View {
    let mcpStatus: MCPServerStatus
    let runningProcesses: RunningProcessCounts
    /// Nil until the first sample, or if the kernel would not report it; the item is
    /// left out rather than showing a made up number.
    let memoryBytes: UInt64?
    let onRestartMCPServer: () -> Void

    /// The bar's own height, which `SidebarWidth.windowMinimumHeight` adds in.
    static let height: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                mcpItem
                Spacer(minLength: 0)
                processesItem
                if let memoryBytes {
                    memoryItem(memoryBytes)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
        }
        .background(.bar)
    }

    private var mcpItem: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(for: mcpStatus.health))
                .foregroundStyle(Self.color(for: mcpStatus.health))
                .imageScale(.small)
            Text(mcpStatus.summary)
                .foregroundStyle(.secondary)
            Button(action: onRestartMCPServer) {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help("Restart the MCP server")
            .accessibilityLabel("Restart MCP server")
        }
        .font(.caption)
        .help(mcpStatus.detail)
        .contextMenu {
            Button("Restart MCP Server", action: onRestartMCPServer)
            if let url = mcpStatus.endpointURL {
                Button("Copy Endpoint URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
            }
        }
    }

    private var processesItem: some View {
        Label(runningProcesses.summary, systemImage: "gearshape.2")
            .foregroundStyle(.secondary)
            .font(.caption)
            .help(runningProcesses.detail)
    }

    private func memoryItem(_ bytes: UInt64) -> some View {
        Label(AppMemory.format(bytes: bytes), systemImage: "memorychip")
            .foregroundStyle(.secondary)
            .font(.caption.monospacedDigit())
            .help("Memory used by Wietty itself, as Activity Monitor reports it. "
                  + "The shells and agents in its terminals are not included.")
    }

    /// The symbol for a health, shared with the MCP tab of Settings so both say it
    /// the same way.
    static func symbol(for health: MCPServerStatus.Health) -> String {
        switch health {
        case .ok: "circle.fill"
        case .pending: "circle.dotted"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    static func color(for health: MCPServerStatus.Health) -> Color {
        switch health {
        case .ok: .green
        case .pending: .secondary
        case .error: .red
        }
    }
}
