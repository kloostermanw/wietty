import Foundation
import Testing
@testable import Wietty

/// What the pane of a terminal on another Mac draws for each state of its owner:
/// whether there is a bar above the surface, what it says, which button it has, and
/// whether the pane shows the surface or a message.
@Suite struct RemoteSurfacePaneTests {
    typealias Layout = RemotePaneLayout

    @Test func connectingShowsTheSurfaceWithNoBar() {
        let layout = Layout(state: .connecting)
        #expect(layout.bar == nil)
        #expect(layout.content == .surface)
    }

    @Test func liveShowsTheSurfaceWithNoBar() {
        let layout = Layout(state: .live)
        #expect(layout.bar == nil)
        #expect(layout.content == .surface)
    }

    @Test func reconnectingShowsTheBarWithReconnectNowOverTheSurface() {
        let layout = Layout(state: .reconnecting)
        #expect(layout.bar == Layout.Bar(text: "Connection lost. Reconnecting…", button: "Reconnect now"))
        #expect(layout.content == .surface)
    }

    @Test func waitingShowsTheBarWithReconnectOverTheSurface() {
        let layout = Layout(state: .waiting)
        #expect(layout.bar == Layout.Bar(text: "Connection lost.", button: "Reconnect"))
        #expect(layout.content == .surface)
    }

    @Test func endedShowsTheBarWithNoButtonAndKeepsTheSurface() {
        let layout = Layout(state: .ended)
        #expect(layout.bar == Layout.Bar(text: "This terminal has ended on the other Mac.", button: nil))
        #expect(layout.content == .surface)
    }

    @Test func refusedFillsThePaneWithTheMessageAndNoBar() {
        let layout = Layout(state: .refused("The other Mac refused the connection."))
        #expect(layout.bar == nil)
        #expect(layout.content == .refused("The other Mac refused the connection."))
        #expect(Layout.refusedTitle == "Cannot show this terminal")
    }

    @Test @MainActor func everyRefusalTextTheOwnerSetsIsShownAsItIs() {
        for message in [RemoteReconnectPolicy.tooOldText,
                        RemoteReconnectPolicy.connectionRemovedText,
                        RemotePane.surfaceFailedText,
                        RemotePane.helperGoneText] {
            #expect(Layout(state: .refused(message)).content == .refused(message))
        }
    }

    /// Before the registry has handed the view its pane (the first body, before
    /// `onAppear`), the pane is drawn as connecting: no bar, nothing in the surface's
    /// place yet.
    @Test func noPaneYetIsDrawnAsConnecting() {
        #expect(Layout(state: nil) == Layout(state: .connecting))
    }
}
