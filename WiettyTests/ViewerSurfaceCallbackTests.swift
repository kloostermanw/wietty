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
}
