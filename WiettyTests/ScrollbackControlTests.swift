import AppKit
import Foundation
import SwiftUI
import Testing
import WiettyCore
@testable import Wietty

/// The scrollback stepper in Settings, General: its bounds, its step, what it is
/// bound to, and what its caption may and may not say.
///
/// The number itself and the line it lives on are `ScrollbackSettingTests`; that the
/// tab still fits the pane with the control in it is `SettingsFieldTests`.
@MainActor
@Suite struct ScrollbackControlTests {
    @Test func theStepperCoversTheSettingsWholeRangeAThousandLinesAtATime() {
        #expect(ScrollbackControl.range == TerminalScrollback.range)
        #expect(ScrollbackControl.range == 1_000...100_000)
        #expect(ScrollbackControl.step == 1_000)
    }

    /// A stepper only lands on its bounds, and on the default, when each is a whole
    /// number of steps from the floor. Otherwise the last click before the ceiling
    /// would be a short one and the default could not be clicked back to.
    @Test func theBoundsAndTheDefaultAreOnAStep() {
        let range = ScrollbackControl.range
        #expect((range.upperBound - range.lowerBound) % ScrollbackControl.step == 0)
        #expect((TerminalScrollback.defaultLines - range.lowerBound) % ScrollbackControl.step == 0)
    }

    /// A click goes to the next multiple of the step in its direction, so a value a
    /// hand edit left off a step is back on one after a single click.
    @Test(arguments: [(1_500, 2_000, 1_000), (10_000, 11_000, 9_000), (4_321, 5_000, 4_000),
                      (1_001, 2_000, 1_000), (99_999, 100_000, 99_000),
                      (1_000, 2_000, 1_000), (100_000, 100_000, 99_000)])
    func aClickLandsOnTheNextMultipleOfTheStep(from: Int, up: Int, down: Int) {
        #expect(ScrollbackControl.stepped(from, up: true) == up)
        #expect(ScrollbackControl.stepped(from, up: false) == down)
    }

    /// Whatever it is handed, in or out of the range, a click answers inside it.
    @Test(arguments: [-5, 0, 999, 100_001, 5_000_000])
    func aClickNeverLeavesTheRange(from: Int) {
        #expect(ScrollbackControl.range.contains(ScrollbackControl.stepped(from, up: true)))
        #expect(ScrollbackControl.range.contains(ScrollbackControl.stepped(from, up: false)))
    }

    /// Every value from the floor is reachable by clicks, and the walk ends on the
    /// ceiling: 99 clicks, each one step.
    @Test func clickingUpFromTheFloorWalksEveryThousandToTheCeiling() {
        var lines = ScrollbackControl.range.lowerBound
        var clicks = 0
        while ScrollbackControl.stepped(lines, up: true) != lines {
            let next = ScrollbackControl.stepped(lines, up: true)
            #expect(next - lines == ScrollbackControl.step)
            lines = next
            clicks += 1
        }
        #expect(lines == ScrollbackControl.range.upperBound)
        #expect(clicks == 99)
    }

    // MARK: The stepper view

    /// A box a binding can write to, standing in for the store.
    private final class Box { var lines: Int; init(_ lines: Int) { self.lines = lines } }

    private func stepper(_ box: Box) -> ScrollbackStepper {
        ScrollbackStepper(lines: Binding(get: { box.lines }, set: { box.lines = $0 }))
    }

    /// The view's two actions are what its arrows call, and they are
    /// `ScrollbackControl.stepped` on the binding, nothing else.
    @Test func theSteppersActionsStepTheBinding() {
        let box = Box(1_500)
        stepper(box).increment()
        #expect(box.lines == 2_000)
        stepper(box).increment()
        #expect(box.lines == 3_000)
        stepper(box).decrement()
        #expect(box.lines == 2_000)
    }

    @Test func anArrowIsOffAtItsBound() {
        #expect(!stepper(Box(100_000)).canIncrement)
        #expect(stepper(Box(100_000)).canDecrement)
        #expect(stepper(Box(1_000)).canIncrement)
        #expect(!stepper(Box(1_000)).canDecrement)
        #expect(stepper(Box(1_500)).canIncrement)
        #expect(stepper(Box(1_500)).canDecrement)
    }

    /// Making the view and laying it out writes nothing: a value off a step stays
    /// as the file has it until somebody clicks.
    @Test func showingTheStepperDoesNotChangeTheValue() {
        var writes = 0
        let view = ScrollbackStepper(lines: Binding(get: { 1_500 }, set: { _ in writes += 1 }))
        _ = NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 480, height: 1_000))
        #expect(writes == 0)
        #expect(view.valueLabel == ScrollbackControl.valueLabel(1_500))
    }

    /// A click on the stepper, with the store behind the binding, is written to the
    /// config file by the store's own `didSet`: no second path to the file.
    @Test func aClickIsWrittenToTheConfigFile() throws {
        let config = WiettyConfigFile.temporary()
        let store = SettingsFixture(config: config).store

        ScrollbackStepper(lines: Bindable(store).scrollbackLines).increment()

        #expect(store.scrollbackLines == TerminalScrollback.defaultLines + 1_000)
        #expect(try config.read()["scrollback-lines"] == "11000")
    }

    /// A value off a step in the file is read as it is, and stays so with the
    /// stepper made over it.
    @Test func aValueOffAStepInTheFileIsKeptUntilAClick() throws {
        let config = WiettyConfigFile.temporary()
        SettingsFixture(config: config).store.scrollbackLines = 1_500
        let store = SettingsFixture(config: config).store
        let view = ScrollbackStepper(lines: Bindable(store).scrollbackLines)
        _ = NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 480, height: 1_000))

        #expect(store.scrollbackLines == 1_500)
        #expect(try config.read()["scrollback-lines"] == "1500")

        view.increment()
        #expect(try config.read()["scrollback-lines"] == "2000")
    }

    /// The binding is the store's, so a value from anywhere else is clamped by the
    /// store's rule.
    @Test(arguments: [(0, 1_000), (999, 1_000), (100_001, 100_000), (5_000_000, 100_000)])
    func aValueOutsideTheRangeSetThroughTheBindingIsClamped(set: Int, kept: Int) throws {
        let config = WiettyConfigFile.temporary()
        let store = SettingsFixture(config: config).store

        Bindable(store).scrollbackLines.wrappedValue = set

        #expect(store.scrollbackLines == kept)
        #expect(try config.read()["scrollback-lines"] == String(kept))
    }

    // MARK: The value and the caption

    private static let american = Locale(identifier: "en_US")
    private static let dutch = Locale(identifier: "nl_NL")

    @Test func theValueIsDrawnWithItsUnit() {
        #expect(ScrollbackControl.valueLabel(10_000, locale: Self.american) == "10,000 lines")
        #expect(ScrollbackControl.valueLabel(100_000, locale: Self.american) == "100,000 lines")
        #expect(ScrollbackControl.valueLabel(10_000, locale: Self.dutch) == "10.000 lines")
    }

    /// The whole caption, in one locale, word for word.
    @Test func theCaptionInFull() {
        #expect(ScrollbackControl.caption(locale: Self.american) == """
            Lines of history Wietty keeps for each terminal and sends to a viewer on another device. \
            Another Mac and the browser can scroll back through it; the iPad shows the screen only. \
            A full terminal costs about 1 KiB per line, so 10,000 lines is about 10 MiB each. \
            Applies to terminals opened after a change. This Mac's own pane keeps its own history.
            """)
    }

    /// The count in the caption is grouped as the value above it is, in any locale,
    /// so the row never reads "10.000 lines" over a caption saying "10,000 lines".
    @Test(arguments: ["en_US", "nl_NL", "de_CH", "fr_FR"])
    func theCaptionSpellsTheDefaultAsTheValueLabelDoes(identifier: String) {
        let locale = Locale(identifier: identifier)
        let label = ScrollbackControl.valueLabel(TerminalScrollback.defaultLines, locale: locale)
        #expect(ScrollbackControl.caption(locale: locale).contains("so \(label) is about 10 MiB each"))
    }

    @Test func theDutchCaptionGroupsWithAPoint() {
        #expect(ScrollbackControl.caption(locale: Self.dutch).contains("so 10.000 lines is about 10 MiB each"))
        #expect(!ScrollbackControl.caption(locale: Self.dutch).contains("10,000"))
    }

    /// The first version of this caption said the setting was what an MCP read
    /// could reach. `get_process_output` is capped at 200 lines, so that was the
    /// reader the setting least affects.
    @Test func theCaptionDoesNotMentionMCP() {
        let caption = ScrollbackControl.caption(locale: Self.american)
        #expect(!caption.localizedCaseInsensitiveContains("MCP"))
        #expect(!caption.localizedCaseInsensitiveContains("agent"))
    }

    /// The caption says the browser can scroll back through what it is sent. That
    /// is only so because the page asks xterm.js for more than its default of 1,000
    /// lines: the setting's ceiling, since the page cannot know the setting. This
    /// reads the page the server serves (`RemoteServer.fileResponse` reads the same
    /// bundle resource). What a real browser then does was not observed.
    @Test func theBrowserPageKeepsAsManyLinesAsTheSettingsCeiling() throws {
        let url = try #require(Bundle.main.url(forResource: "remote_index", withExtension: "html"))
        let page = try String(contentsOf: url, encoding: .utf8)
        let match = try #require(page.firstMatch(of: /new Terminal\(\{[^}]*\bscrollback:\s*(\d+)[^}]*\}\)/))
        #expect(Int(match.1) == TerminalScrollback.range.upperBound)
        #expect(page.matches(of: /new Terminal\(/).count == 1)
    }
}
