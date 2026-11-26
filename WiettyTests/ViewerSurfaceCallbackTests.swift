import Foundation
import Testing
@testable import Wietty

/// What `GhosttySurfaceHost` passes on of each callback of a surface, for a viewer of a
/// terminal on another Mac against a surface of this Mac's own terminal. The decision
/// is the host's own (`passesOn(_:viewer:)`), so it is checked here without a surface.
@Suite struct ViewerSurfaceCallbackTests {
    typealias Callback = GhosttySurfaceHost.SurfaceCallback

    /// What a viewer drops: everything that would reach `GhosttyService`, the store,
    /// `GhosttyMonitor` or Notification Center.
    @Test(arguments: [Callback.title, .bell, .desktopNotification, .closeRequest, .input])
    func aViewerDropsWhatWouldReachTheApp(_ callback: Callback) {
        #expect(!GhosttySurfaceHost.passesOn(callback, viewer: true))
        #expect(GhosttySurfaceHost.passesOn(callback, viewer: false))
    }

    /// What works for a viewer as for any surface.
    @Test(arguments: [Callback.render, .cellSize, .background, .grid, .metrics, .userAction])
    func aViewerKeepsWhatDrawsAndSizesTheSurface(_ callback: Callback) {
        #expect(GhosttySurfaceHost.passesOn(callback, viewer: true))
        #expect(GhosttySurfaceHost.passesOn(callback, viewer: false))
    }

    /// The "Paste into the terminal?" question: asked for the user's own paste on any
    /// surface, and never for a program's `OSC 52` request on a viewer, which is
    /// dropped (left uncompleted) with no alert.
    @Test func aViewerAsksOnlyAboutTheUsersOwnPaste() {
        #expect(GhosttySurfaceHost.passesOn(.confirmClipboard(.paste), viewer: true))
        #expect(!GhosttySurfaceHost.passesOn(.confirmClipboard(.osc52Read), viewer: true))
        #expect(!GhosttySurfaceHost.passesOn(.confirmClipboard(.osc52Write), viewer: true))
        #expect(!GhosttySurfaceHost.passesOn(.confirmClipboard(nil), viewer: true))
        for request in [GhosttySurfaceHost.ClipboardRequest.paste, .osc52Read, .osc52Write] {
            #expect(GhosttySurfaceHost.passesOn(.confirmClipboard(request), viewer: false))
        }
    }

    /// libghostty's request kinds, by their raw values in `ghostty.h`
    /// (`ghostty_clipboard_request_e`), and nil for one this build does not know.
    @Test func theRequestKindsAreReadFromLibghosttysValues() {
        #expect(GhosttySurfaceHost.ClipboardRequest(kind: 0) == .paste)
        #expect(GhosttySurfaceHost.ClipboardRequest(kind: 1) == .osc52Read)
        #expect(GhosttySurfaceHost.ClipboardRequest(kind: 2) == .osc52Write)
        #expect(GhosttySurfaceHost.ClipboardRequest(kind: 3) == nil)
    }

    /// The settings a viewer surface's configuration adds over the app's, which make
    /// libghostty itself refuse a program's `OSC 52` read and write on it. Read back through libghostty from a configuration made of the overlay alone,
    /// so nothing here reads the Ghostty config of whoever runs the suite.
    @MainActor
    @Test func aViewersConfigurationDeniesTheProgramsClipboard() throws {
        let url = TestScratch.root.appendingPathComponent("wietty-viewer-\(UUID().uuidString).cfg")
        try GhosttySurfaceHost.viewerOverlay.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let access = GhosttySurfaceHost.clipboardAccess(loading: url)
        #expect(access.read == "deny")
        #expect(access.write == "deny")
    }

    /// Every action the host takes from libghostty, mapped to its callback and passed
    /// on or not, for a viewer and for this Mac's own terminal: what `apply` decides.
    @Test func everyActionIsMappedAndDecidedAsExpected() {
        typealias Event = GhosttySurfaceHost.SurfaceEvent
        let table: [(Event, Callback, viewerKeeps: Bool)] = [
            (.render, .render, true),
            (.cellSize, .cellSize, true),
            (.background(r: 1, g: 2, b: 3), .background, true),
            (.title("t"), .title, false),
            (.bell, .bell, false),
            (.notification(title: "t", body: "b"), .desktopNotification, false),
        ]
        for (event, callback, viewerKeeps) in table {
            #expect(GhosttySurfaceHost.callback(for: event) == callback)
            #expect(GhosttySurfaceHost.passesOn(GhosttySurfaceHost.callback(for: event), viewer: true) == viewerKeeps)
            #expect(GhosttySurfaceHost.passesOn(GhosttySurfaceHost.callback(for: event), viewer: false))
        }
    }

    /// Only a configuration that resolves both keys to `deny` counts as closed.
    @Test func onlyDenyOnBothKeysIsClosed() {
        #expect(GhosttySurfaceHost.isClosed(read: "deny", write: "deny"))
        for (read, write) in [("ask", "deny"), ("deny", "allow"), ("allow", "allow"),
                              (nil, "deny"), ("deny", nil), (nil, nil)] as [(String?, String?)] {
            #expect(!GhosttySurfaceHost.isClosed(read: read, write: write))
        }
    }

    /// A path libghostty cannot read sets nothing, which is not closed: why the host
    /// checks the configuration it built rather than the file it wrote.
    @MainActor
    @Test func aConfigurationWhoseFileWasNotReadIsNotClosed() {
        let missing = TestScratch.root.appendingPathComponent("wietty-viewer-missing-\(UUID().uuidString).cfg")
        let access = GhosttySurfaceHost.clipboardAccess(loading: missing)
        #expect(!GhosttySurfaceHost.isClosed(read: access.read, write: access.write))
    }
}
