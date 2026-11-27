import Foundation
import WiettyCore

/// What the scrollback stepper in Settings, General is made of, apart from the
/// view: its bounds, its step, how its value is drawn and its caption.
///
/// Out of `SettingsView` so a test can read each of them. The caption most of all:
/// its first version said the setting was what an MCP read could reach, which was
/// the one thing no value of the setting changes, and nothing could have caught it.
enum ScrollbackControl {
    /// The setting's own range, so the stepper cannot ask for a value the store
    /// would clamp.
    static let range = TerminalScrollback.range

    /// One click: a thousand lines, about a mebibyte per full terminal.
    static let step = 1_000

    /// The value beside the label, as the interval steppers draw theirs.
    static func valueLabel(_ lines: Int, locale: Locale = .current) -> String {
        "\(lines.formatted(.number.grouping(.automatic).locale(locale))) lines"
    }

    /// What the number bounds, what it costs, when a change applies, and what it
    /// does not bound. Each sentence is a statement about the code:
    ///
    /// - The history is the screen model's (`GhosttyVtTerminal`), and the viewers
    ///   that are sent it are the ones that attach over `WS /attach`: a snapshot is
    ///   every row the model holds (`PaneStreamHub`, `snapshotFrame()`).
    /// - The cost is `TerminalScrollback`'s: about 1 KiB per retained row at 120
    ///   columns, paid once the rows exist, hence "a full terminal".
    /// - `GhosttyService.open` reads the setting once per terminal.
    /// - This Mac's pane scrolls its surface's history, which Ghostty's
    ///   `scrollback-limit` sizes and Wietty never writes.
    ///
    /// Nothing about MCP: `get_process_output` returns at most 200 lines, under the
    /// setting's floor.
    static let caption = "Lines of history Wietty keeps for each terminal for viewers on other devices: the iPad, the browser and another Mac. A full terminal costs about 1 KiB per line, so 10,000 lines is about 10 MiB each. Applies to terminals opened after a change. This Mac's own pane keeps its own history."
}
