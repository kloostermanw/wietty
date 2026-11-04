import Testing
import AppKit
import SwiftUI
@testable import Wietty

/// The window's top row holds buttons in the strip AppKit keeps for a title bar.
/// Whether a click there reaches a button is decided by AppKit (the scroll view's
/// own views and the title bar's), not by the order the SwiftUI views are declared,
/// so it is asserted by clicking a real window shaped like the app's.
@MainActor
@Suite struct TitleBarRowTests {
    final class Flag { var fired = false }

    /// A window the way `.hiddenTitleBar` builds one, holding content that runs up
    /// under the title bar the way `ContentView` does.
    private func window<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.ignoresSafeArea(.container, edges: .top))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }

    /// The regression: stacked above the workspace list, the buttons were covered by
    /// the scroll view, which reaches up into the title bar strip, and no click got
    /// through. The trailing button sits in the last 22 points before the 10 point
    /// inset, in the top 28 points of the window.
    @Test func aSidebarButtonOverTheWorkspaceListTakesTheClick() {
        let flag = Flag()
        let buttons = [SidebarSectionHeaderView.ButtonSpec(system: "plus", help: "Add",
                                                           action: { flag.fired = true })]
        let size = NSSize(width: 320, height: 200)
        let sidebar = ScrollView {
            LazyVStack(spacing: 0) { ForEach(0..<40) { Text("row \($0)") } }
        }
        .sidebarTopBar(buttons: buttons)
        let window = window(sidebar, size: size)
        window.orderFront(nil)
        defer { window.close() }
        click(window, at: NSPoint(x: size.width - 10 - 11, y: size.height - NavBarView.height / 2))
        #expect(flag.fired)
    }
}
