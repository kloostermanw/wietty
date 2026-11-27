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

    /// The control writes through a binding to the store's own property, so the
    /// store's `didSet` is what persists it: no second path to the file.
    @Test func aStepThroughTheBindingIsWrittenToTheConfigFile() throws {
        let config = WiettyConfigFile.temporary()
        let store = SettingsFixture(config: config).store
        let binding = Bindable(store).scrollbackLines

        binding.wrappedValue += ScrollbackControl.step

        #expect(store.scrollbackLines == TerminalScrollback.defaultLines + 1_000)
        #expect(try config.read()["scrollback-lines"] == "11000")
    }

    /// The stepper's own range stops a click, but the binding is the store's, so a
    /// value from anywhere else is clamped by the same rule.
    @Test(arguments: [(0, 1_000), (999, 1_000), (100_001, 100_000), (5_000_000, 100_000)])
    func aValueOutsideTheRangeSetThroughTheBindingIsClamped(set: Int, kept: Int) throws {
        let config = WiettyConfigFile.temporary()
        let store = SettingsFixture(config: config).store

        Bindable(store).scrollbackLines.wrappedValue = set

        #expect(store.scrollbackLines == kept)
        #expect(try config.read()["scrollback-lines"] == String(kept))
    }

    @Test func theValueIsDrawnWithItsUnit() {
        let en = Locale(identifier: "en_US")
        #expect(ScrollbackControl.valueLabel(10_000, locale: en) == "10,000 lines")
        #expect(ScrollbackControl.valueLabel(100_000, locale: en) == "100,000 lines")
    }

    /// The caption says what the number bounds: the history kept for viewers on
    /// other devices. Each of the three is named, because "remote viewers" would
    /// leave a reader guessing whether the browser counts.
    @Test func theCaptionNamesTheViewersTheHistoryIsKeptFor() {
        let caption = ScrollbackControl.caption
        #expect(caption.contains("the iPad"))
        #expect(caption.contains("the browser"))
        #expect(caption.contains("another Mac"))
    }

    /// The first version of this caption said the setting was what an MCP read
    /// could reach. `get_process_output` is capped at 200 lines, under the setting's
    /// floor, so that was the one thing no value of the setting changes.
    @Test func theCaptionDoesNotMentionMCP() {
        #expect(!ScrollbackControl.caption.localizedCaseInsensitiveContains("MCP"))
        #expect(!ScrollbackControl.caption.localizedCaseInsensitiveContains("agent"))
    }

    /// The cost in the caption is worked out for the default, so it has to be the
    /// default the code has.
    @Test func theCaptionsCostExampleIsTheDefault() {
        #expect(TerminalScrollback.defaultLines == 10_000)
        #expect(ScrollbackControl.caption.contains("about 1 KiB per line"))
        #expect(ScrollbackControl.caption.contains("10,000 lines is about 10 MiB each"))
    }

    @Test func theCaptionSaysWhenAChangeAppliesAndThatThePaneIsNotBounded() {
        #expect(ScrollbackControl.caption.contains("Applies to terminals opened after a change."))
        #expect(ScrollbackControl.caption.contains("This Mac's own pane keeps its own history."))
    }
}
