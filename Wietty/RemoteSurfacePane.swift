import SwiftUI
import AppKit
import WiettyShared

/// What the pane of a terminal on another Mac draws for a state of its owner.
///
/// Separated from the view so it can be asserted without a window, a surface or a
/// connection: a bar over the surface or not, its text and its button, and the
/// surface, the stopped screen or a message that fills the pane.
struct RemotePaneLayout: Equatable {
    /// The line over the top of the surface while the link is down. Drawn over it, so
    /// it never changes the surface's size.
    struct Bar: Equatable {
        let text: String
        /// The button's title. Whatever it says, it calls
        /// `RemotePane.reconnectPressed()`, which knows what it means in each state.
        let button: String
    }

    /// What fills the rest of the pane.
    enum Content: Equatable {
        /// The surface, in the container the own pane uses. In `connecting` it may
        /// not exist yet for a turn, and nothing is drawn in its place.
        case surface
        /// The session ended on the other Mac: the stopped screen a terminal of this
        /// Mac gets (`TerminalStoppedView`), with Restart. The surface is still the
        /// pane's until it is hidden, but it is not shown.
        case stopped
        /// No surface at all: the message, under `refusedTitle`.
        case refused(String)
    }

    static let refusedTitle = "Cannot show this terminal"

    let bar: Bar?
    let content: Content

    /// - Parameter state: the pane's state, nil before the registry has handed the
    ///   view its pane, which is drawn as `connecting`.
    init(state: RemoteReconnectPolicy.State?) {
        switch state ?? .connecting {
        case .connecting, .live:
            bar = nil
            content = .surface
        case .reconnecting:
            bar = Bar(text: "Connection lost. Reconnecting…", button: "Reconnect now")
            content = .surface
        case .waiting:
            bar = Bar(text: "Connection lost.", button: "Reconnect")
            content = .surface
        case .ended:
            bar = nil
            content = .stopped
        case .refused(let message):
            bar = nil
            content = .refused(message)
        }
    }
}

/// A terminal that lives on another Mac, in the main window's pane, on a libghostty
/// surface fed through the app's `TerminalBridge`.
///
/// The view owns nothing. Appearing opens the session's pane in `RemotePanes` and
/// disappearing closes it, one close for one open, so the registry's count stays
/// right when SwiftUI runs a new view's appear before the old one's disappear. The
/// caller keys this view by its session, so a different session or connection is a
/// different view: the old one's disappear closes its pane, the new one's appear
/// opens another. Showing a session again after a hide is a new pane, a new surface
/// and a new attach.
///
/// The surface goes in the same `SurfaceContainer` the own pane uses: pinned top
/// left, at the size of the grid in force when another viewer holds it, with the
/// margin painted in the terminal's background. The surface view itself is told the
/// pane's size by the container and passes it to the pane's grid, as an own pane's
/// does.
///
/// The bar is drawn over the top of the surface, not above it: the surface's
/// container always has the whole pane, so a bar that comes and goes changes neither
/// the grid this pane claims when it owns it nor what is visible of a grid imposed on
/// it. The bar covers the top of the first row while it shows.
///
/// The bar comes and goes with the state, with no animation: a link that keeps
/// dropping switches between `live` and `reconnecting`, and an animated bar would
/// make that worse to look at.
///
/// A session that ended on the other Mac gets the stopped screen a terminal of this
/// Mac gets, in place of the surface and with no bar. Its Restart asks the other Mac
/// for a restart, which gives the row a new session; the selection follows the row to
/// it (`PaneRouter.remoteRowsChanged`), so this view goes and one for the replacement
/// comes.
struct RemoteSurfacePane: View {
    let panes: RemotePanes
    let session: RemoteSessionRef
    /// Whether the session's row is an agent, which only changes the wording of the
    /// stopped screen. A closure, read when the stopped screen is drawn, so it is
    /// answered from the snapshot of that moment and not from the one the pane was
    /// opened under.
    var isAgent: () -> Bool = { false }
    /// The stopped screen's Restart.
    var onRestart: () -> Void = {}

    /// The pane this view opened, nil before `onAppear` and after `onDisappear`.
    /// Also what pairs the two: a close only for an open this view made.
    @State private var pane: RemotePane?

    var body: some View {
        let layout = RemotePaneLayout(state: pane?.state)
        Group {
            switch layout.content {
            case .surface:
                // Nil for one main turn after the open (the owner creates the
                // surface on the next turn), and nothing is drawn meanwhile.
                if let surface = pane?.surfaceView {
                    SurfaceContainer(surface: surface)
                } else {
                    Color.clear
                }
            case .stopped:
                TerminalStoppedView(isAgent: isAgent(), onRestart: onRestart)
            case .refused(let message):
                ContentUnavailableView {
                    Label(RemotePaneLayout.refusedTitle, systemImage: "bolt.slash")
                } description: {
                    Text(message)
                }
            }
        }
        // Over the surface, never above it: the container keeps the whole pane, so
        // the bar changes neither the grid this pane would claim nor how much of an
        // imposed grid is visible. It covers the top of the first row while shown.
        .overlay(alignment: .top) {
            if let bar = layout.bar {
                RemotePaneBar(bar: bar) { pane?.reconnectPressed() }
            }
        }
        .transaction { $0.animation = nil }
        .onAppear {
            guard pane == nil else { return }
            pane = panes.open(session)
        }
        .onDisappear {
            guard pane != nil else { return }
            pane = nil
            panes.close(session)
        }
    }
}

/// The line over the top of a remote pane's surface, in the style of the window's status bar:
/// caption text on the bar material, a divider under it.
private struct RemotePaneBar: View {
    let bar: RemotePaneLayout.Bar
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(bar.text)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(bar.button, action: action)
                    .controlSize(.small)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(minHeight: StatusBarView.height)
            Divider()
        }
        .background(.bar)
    }
}
