import Testing
import AppKit
@testable import Wietty

/// The two pure pieces of mouse forwarding.
///
/// Nothing else about input can be asserted without a live surface, and creating
/// one initialises libghostty, which `TerminalStackTests` asserts no other test
/// does. These two are where a silent mistake would live: a click landing on the
/// wrong row, or a scroll that a trackpad reports differently from a wheel.
@MainActor
@Suite struct GhosttySurfaceInputTests {
    /// libghostty's origin is the top left, an `NSView`'s is the bottom left, so
    /// the y axis is flipped. Getting this wrong puts every click and every drag
    /// selection on the mirrored row, which reads as a mysterious off by many
    /// rather than as an obvious flip.
    @Test func aViewPointIsFlippedOntoTheSurface() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(GhosttySurfaceView.surfacePoint(of: CGPoint(x: 10, y: 0), in: bounds)
            == CGPoint(x: 10, y: 300))
        #expect(GhosttySurfaceView.surfacePoint(of: CGPoint(x: 10, y: 300), in: bounds)
            == CGPoint(x: 10, y: 0))
        #expect(GhosttySurfaceView.surfacePoint(of: CGPoint(x: 40, y: 100), in: bounds)
            == CGPoint(x: 40, y: 200))
    }

    /// Bit 0 is "these deltas are precise", the bits above it hold the momentum
    /// phase. A wheel with no momentum is a zero, which is why the packing has to
    /// be right for anything else to be noticed at all.
    @Test func scrollModifiersPackPrecisionIntoBitZero() {
        #expect(GhosttySurfaceView.scrollMods(precision: false, momentum: 0) == 0)
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 0) == 1)
    }

    @Test func scrollModifiersPackMomentumAboveIt() {
        // The momentum values are `ghostty_input_mouse_momentum_e`'s own: 1 began,
        // 3 changed, 4 ended.
        #expect(GhosttySurfaceView.scrollMods(precision: false, momentum: 1) == 2)
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 1) == 3)
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 3) == 7)
        // Four needs a third momentum bit. A two bit mask would report this as
        // "none", so an inertial scroll would never be told it had stopped.
        #expect(GhosttySurfaceView.scrollMods(precision: true, momentum: 4) == 9)
    }
}
