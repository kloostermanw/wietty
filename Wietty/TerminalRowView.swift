import SwiftUI

struct TerminalRowView: View {
    let label: String
    let kind: TerminalKind
    var isExited: Bool = false
    /// Whether this row's terminal is running right now, which tints its glyph green.
    /// Distinct from `!isExited`: an unspawned or idle row is neither running nor
    /// exited, so it stays neutral rather than green.
    var isRunning: Bool = false
    var needsAttention: Bool = false
    var isLocalOnly: Bool = false
    /// Whether this row's terminal is the one the pane is showing. Exactly one row
    /// in the window is ever marked, because the pane holds one terminal.
    var isSelected: Bool = false
    let onPlay: () -> Void
    /// Stops the running session without removing the row (the stop button).
    let onStop: () -> Void
    let onRestart: () -> Void
    /// Closes and removes the row (the trash button). Distinct from `onStop`, which
    /// leaves the row in place. Required, not defaulted: the trash button is always
    /// rendered, so a caller that forgot to wire it would ship an inert delete.
    let onClose: () -> Void
    /// Whether stopping a session in place is available, which offers the stop button
    /// on a live row. False where only teardown exists, such as a remote card whose
    /// LAN protocol has no stop that keeps the row.
    var canStop: Bool = true

    @State private var isHovered = false
    @Environment(\.sidebarColors) private var sidebarColors

    private var iconName: String {
        kind == .claude ? "sparkle" : "terminal"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(iconStyle)
                .opacity(isExited ? 0.6 : 1)
                // A fixed slot the width of the header chevron, so the icon sits in the
                // same left gutter and the label lines up with the project name.
                .frame(width: 12, alignment: .center)
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
        .padding(.trailing, 6)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(highlight)
        .onHover { isHovered = $0 }
    }

    // A running row can be stopped or restarted; one that is not running is reopened
    // with play. Gated on `isRunning`, the same positive signal the glyph uses, rather
    // than `!isExited`: a plain terminal never reports exited, so keying off it left a
    // stopped terminal showing a dead stop button and no way to reopen. Either way the
    // row can be closed, which removes it, so the trash button is always offered.
    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 8) {
            if isRunning {
                if canStop {
                    RowActionButton(systemName: "stop.fill", help: "Stop", action: onStop)
                }
                RowActionButton(systemName: "arrow.clockwise", help: "Restart", action: onRestart)
            } else {
                RowActionButton(systemName: "play.fill", help: "Activate", action: onPlay)
            }
            RowActionButton(systemName: "trash", help: "Close terminal", action: onClose)
        }
    }

    /// The glyph's colour: green while the terminal or agent is actually running, so a
    /// live session stays identifiable at a glance even when another row is the one
    /// selected in the pane. An exited row keeps the dimmed tertiary treatment; a row
    /// that is neither (unspawned, or idle before the first job poll) stays neutral
    /// rather than claiming to be running.
    private var iconStyle: AnyShapeStyle {
        if isRunning { return AnyShapeStyle(Color.green) }
        return isExited ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
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
