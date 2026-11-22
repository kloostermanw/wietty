import AppKit
import Foundation
import WiettyCore

/// Handing a session's surface view to the pane.
///
/// Split from `TerminalSurfaceHosting` because `NSView` is the only thing in that
/// protocol that needs AppKit. A host conforms to both; only the app, which is the
/// half with a window, ever asks for this one.
@MainActor
protocol TerminalSurfaceViewing: AnyObject {
    /// The view this surface renders into, for the pane to show. Nil for an id
    /// with no surface.
    func view(id: String) -> NSView?
}

extension InertSurfaceHost: TerminalSurfaceViewing {
    func view(id: String) -> NSView? { nil }
}
