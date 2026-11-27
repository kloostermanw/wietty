import SwiftUI
import WiettyCore

/// What the scrollback stepper in Settings, General is made of, apart from the
/// view: its bounds, its step, where a click lands, how its value is drawn and its
/// caption.
///
/// Out of `SettingsView` so a test can read each of them. The caption most of all:
/// its first version said the setting was what an MCP read could reach, which the
/// 200 line cap on such a read made almost never true, and nothing could have
/// caught it.
enum ScrollbackControl {
    /// The setting's own range, so the stepper cannot ask for a value the store
    /// would clamp.
    static let range = TerminalScrollback.range

    /// One click: a thousand lines, about a mebibyte per full terminal.
    static let step = 1_000

    /// Where one click takes `lines`: the next multiple of `step` in that
    /// direction, kept inside `range`.
    ///
    /// A multiple, not `lines` plus or minus a step, because the config file can
    /// hold any number in the range. From 1,500 a click up gives 2,000 and a click
    /// down 1,000, and every click after that lands on a thousand, rather than
    /// 2,500, 3,500 and so on until a bound. A value already at the bound in that
    /// direction comes back unchanged, which is how the stepper knows to disable
    /// that half.
    static func stepped(_ lines: Int, up: Bool) -> Int {
        let floored = lines - (lines % step + step) % step
        let next = up ? floored + step : (floored == lines ? lines - step : floored)
        return min(max(next, range.lowerBound), range.upperBound)
    }

    /// A count of lines, grouped as `locale` groups numbers. The one formatter for
    /// the value beside the label and for the number in the caption, so the two
    /// cannot show the same count in two spellings.
    static func count(_ lines: Int, locale: Locale = .current) -> String {
        lines.formatted(.number.grouping(.automatic).locale(locale))
    }

    /// The value beside the label.
    static func valueLabel(_ lines: Int, locale: Locale = .current) -> String {
        "\(count(lines, locale: locale)) lines"
    }

    /// What the number bounds, who can use it, what it costs, when a change
    /// applies, and what it does not bound. Each sentence is a statement about the
    /// code:
    ///
    /// - The history is the screen model's (`GhosttyVtTerminal`), and a viewer that
    ///   attaches over `WS /attach` is sent all of it: a snapshot is every row the
    ///   model holds (`PaneStreamHub`, `snapshotFrame()`).
    /// - The pane of another Mac is a libghostty surface and the browser page's
    ///   xterm.js is given the setting's ceiling as its `scrollback`
    ///   (`remote_index.html`), so both can scroll into what they were sent. The
    ///   iPad's terminal view has scrolling turned off.
    /// - The cost is `TerminalScrollback`'s: about 1 KiB per retained row at 120
    ///   columns, paid once the rows exist, hence "a full terminal". The example is
    ///   worked out for the default.
    /// - `GhosttyService.open` reads the setting once per terminal.
    /// - This Mac's pane scrolls its surface's history, which Ghostty's own
    ///   configuration sizes and Wietty never writes.
    ///
    /// Nothing about MCP: `get_process_output` returns at most 200 lines.
    static func caption(locale: Locale = .current) -> String {
        let lines = TerminalScrollback.defaultLines
        // 1 KiB per line, in MiB, to the nearest whole one: 10 at the default.
        let mebibytes = Int((Double(lines) / 1_024).rounded())
        return "Lines of history Wietty keeps for each terminal and sends to a viewer on another device. Another Mac and the browser can scroll back through it; the iPad shows the screen only. A full terminal costs about 1 KiB per line, so \(count(lines, locale: locale)) lines is about \(count(mebibytes, locale: locale)) MiB each. Applies to terminals opened after a change. This Mac's own pane keeps its own history."
    }
}

/// The stepper itself: one row, the label on the left, the value and the two
/// arrows on the right.
///
/// A view of its own, taking nothing but a binding, so that what a click does is
/// two methods a test can call (`increment`, `decrement`) and `SettingsView` has
/// nothing to get wrong but which binding it hands over. The arrows are given
/// closures rather than a range and a step, because a click is not "plus a step":
/// see `ScrollbackControl.stepped(_:up:)`. Showing the row never writes the
/// binding, so a value off a step stays as the file has it until a click.
struct ScrollbackStepper: View {
    @Binding var lines: Int

    var canIncrement: Bool { ScrollbackControl.stepped(lines, up: true) != lines }
    var canDecrement: Bool { ScrollbackControl.stepped(lines, up: false) != lines }

    func increment() { lines = ScrollbackControl.stepped(lines, up: true) }
    func decrement() { lines = ScrollbackControl.stepped(lines, up: false) }

    var valueLabel: String { ScrollbackControl.valueLabel(lines) }

    var body: some View {
        // A nil action is how a stepper greys out one arrow.
        Stepper(label: {
            HStack {
                Text("Scrollback")
                Spacer()
                Text(valueLabel).foregroundStyle(.secondary).monospacedDigit()
            }
        }, onIncrement: canIncrement ? { increment() } : nil,
           onDecrement: canDecrement ? { decrement() } : nil)
    }
}
