import SwiftUI

/// The number of uncommitted paths in a workspace's working tree, drawn at the
/// leading edge of the card's ahead/behind block. Work that was never committed
/// is something to act on, so the count is red; a clean tree draws nothing, not
/// a `0`, so a tidy workspace stays quiet. Issue #81.
struct UncommittedCountView: View {
    let count: Int

    var body: some View {
        if isVisible {
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
                .fixedSize()
                .help("\(count) uncommitted \(count == 1 ? "path" : "paths")")
        }
    }

    var isVisible: Bool { count > 0 }

    var color: Color { .red }
}
