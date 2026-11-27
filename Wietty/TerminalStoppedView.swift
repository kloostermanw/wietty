import SwiftUI

/// The screen a pane shows for a terminal that has ended: what stopped, and a Restart
/// button.
///
/// One view for both panes, so a terminal of this Mac (`LocalTerminalView`) and one of
/// another Mac (`RemoteSurfacePane`) cannot come to look or work differently once they
/// have ended. What Restart does is the caller's: this Mac's store for a local row,
/// the other Mac's for a remote one.
struct TerminalStoppedView: View {
    /// Whether the row is an agent, which only changes the wording.
    let isAgent: Bool
    /// What Restart does, or nil for no button: a session of another Mac that no row
    /// there carries any more has nothing to restart.
    let onRestart: (() -> Void)?
    /// Shows the button but takes no press: a restart of another Mac's session that
    /// has been asked for and not answered yet.
    var restartDisabled = false

    static func title(isAgent: Bool) -> String {
        isAgent ? "Agent stopped" : "Terminal stopped"
    }

    static func description(isAgent: Bool) -> String {
        isAgent ? "The agent has exited." : "The process has exited."
    }

    static let restartTitle = "Restart"

    var body: some View {
        ContentUnavailableView {
            Label(Self.title(isAgent: isAgent), systemImage: "terminal")
        } description: {
            Text(Self.description(isAgent: isAgent))
        } actions: {
            if let onRestart {
                Button(Self.restartTitle, action: onRestart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(restartDisabled)
            }
        }
    }
}
