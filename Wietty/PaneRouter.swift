import Foundation

/// What is covering the local terminal in the main window's pane.
///
/// A type of its own, and owned by the app rather than by `ContentView`, for one
/// reason: ⌘, and the app menu item are declared in the scene's `commands`, which
/// cannot reach a view's `@State`. Both ways in then set one property, and the pane
/// draws whatever it says.
///
/// Holds no rule. `PaneSelection.resolve` is what turns this and the local
/// selection into the thing on screen.
@MainActor
@Observable
final class PaneRouter {
    var override: PaneOverride?
}
