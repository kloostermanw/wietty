import SwiftUI

struct TerminalRowView: View {
    let label: String
    let kind: TerminalKind
    var isExited: Bool = false
    var needsAttention: Bool = false
    var isLocalOnly: Bool = false
    /// Whether this row's terminal is the one the pane is showing. Exactly one row
    /// in the window is ever marked, because the pane holds one terminal.
    var isSelected: Bool = false
    let onPlay: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @State private var isHovered = false
    @Environment(\.sidebarColors) private var sidebarColors

    private var iconName: String {
        kind == .claude ? "sparkle" : "terminal"
    }

    // A terminal is running unless it has exited. Plain terminals never report
    // an exited state, so they are always considered running; Claude rows use
    // `isExited`.
    private var isRunning: Bool { !isExited }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(isExited ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .opacity(isExited ? 0.6 : 1)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(labelStyle)
            if isLocalOnly {
                Text("local")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.15), in: Capsule())
            }
            Spacer(minLength: 8)
            if needsAttention {
                Text("🔔")
            }
            if isHovered {
                actionButtons
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(highlight)
        .onHover { isHovered = $0 }
    }

    // Not running shows a single play button; running shows stop + restart.
    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 8) {
            if isRunning {
                RowActionButton(systemName: "stop.fill", help: "Close terminal", action: onStop)
                RowActionButton(systemName: "arrow.clockwise", help: "Restart", action: onRestart)
            } else {
                RowActionButton(systemName: "play.fill", help: "Activate", action: onPlay)
            }
        }
    }

    /// The label's colour: the user's active-row foreground when this row is the one
    /// on screen and they set one, otherwise the built-in primary/secondary that
    /// dims an exited Claude row.
    private var labelStyle: AnyShapeStyle {
        if isSelected, let foreground = sidebarColors.activeTerminalRowForeground {
            return AnyShapeStyle(foreground)
        }
        return isExited ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    /// Selected wins over hovered, and which is which is `SidebarRowBackground`'s
    /// to say rather than this view's. The selected fill takes the user's override
    /// when they set one.
    @ViewBuilder private var highlight: some View {
        if let fill = SidebarRowBackground.resolve(isSelected: isSelected, isHovered: isHovered)
            .fill(activeRowBackground: sidebarColors.activeTerminalRowBackground) {
            RoundedRectangle(cornerRadius: SidebarRowBackground.cornerRadius)
                .fill(fill)
        }
    }
}
