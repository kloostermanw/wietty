import AppKit
import Foundation
import Testing
import WiettyCore
@testable import Wietty

/// What `GhosttySurfaceView` hands the pane's grid, checked on a view with no surface
/// and no host: the grid that fits the pane, and the user's actions.
///
/// Not reachable without a real surface (and so left to the gated tests and the hand
/// check): `keyDown` and `sendText` (a file drop, dictation, a Services item), which
/// return before anything when the view has no surface.
@MainActor
@Suite struct SurfaceViewPaneTests {
    private let metrics = SurfaceMetrics(cellWidth: 10, cellHeight: 20, paddingX: 0, paddingY: 0, scale: 1)

    private func paned(width: CGFloat = 800, height: CGFloat = 600)
        -> (NSWindow, SurfaceContainerView, GhosttySurfaceView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = SurfaceContainerView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = container
        let view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), host: nil, id: "gt:test")
        container.hold(view)
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, container, view)
    }

    /// The own grid is the container's, whatever frame the surface itself has (an
    /// imposed size gives it another), so an imposed grid cannot feed back into the
    /// grid the pane claims.
    @Test func theOwnGridIsTheContainersNotTheSurfaces() {
        let (window, container, view) = paned()
        defer { window.close() }
        #expect(container.bounds.size == NSSize(width: 800, height: 600))
        #expect(view.ownGrid(at: metrics) == TerminalSize(cols: 80, rows: 30))
        view.setFrameSize(NSSize(width: 300, height: 200))
        #expect(view.frame.size == NSSize(width: 300, height: 200))
        #expect(view.ownGrid(at: metrics) == TerminalSize(cols: 80, rows: 30))
    }

    /// Off display there is no own grid: not in a window, or not in a pane.
    @Test func offDisplayThereIsNoOwnGrid() {
        let (window, container, view) = paned()
        defer { window.close() }
        container.removeFromSuperview()
        #expect(view.ownGrid(at: metrics) == nil)
        let loose = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), host: nil, id: "gt:loose")
        #expect(loose.ownGrid(at: metrics) == nil)
        #expect(view.ownGrid(at: nil) == nil)
    }

    /// A click with any button and a paste are user actions; a release, a move and a
    /// drag are not.
    @Test func clicksAndAPasteAreUserActions() throws {
        let (window, _, view) = paned()
        defer { window.close() }
        var actions = 0
        view.onUserAction = { actions += 1 }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown))
        view.rightMouseDown(with: try event(.rightMouseDown))
        view.otherMouseDown(with: try event(.otherMouseDown))
        view.paste(nil)
        #expect(actions == 4)
        view.mouseUp(with: try event(.leftMouseUp))
        view.rightMouseUp(with: try event(.rightMouseUp))
        view.mouseMoved(with: try event(.mouseMoved))
        view.mouseDragged(with: try event(.leftMouseDragged))
        #expect(actions == 4)
    }
}
