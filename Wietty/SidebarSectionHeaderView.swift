import SwiftUI

struct SidebarSectionHeaderView: View {
    let title: String
    let collapsed: Bool
    let onToggle: () -> Void
    let buttons: [ButtonSpec]

    /// One icon button in a header or in the bar above the pane.
    ///
    /// The id is the symbol name rather than a `UUID`, and that is load bearing: the
    /// arrays are built inside `body`, so a fresh `UUID` per pass gave `ForEach` a new
    /// identity on every redraw and the `Button` was torn down and rebuilt rather than
    /// updated. A redraw landing between mouse down and mouse up then drops the click,
    /// and the bar above the pane redraws on every selection change and on every git
    /// poll. A symbol name is unique within one row of buttons and stable across
    /// redraws. It cannot be `Equatable` instead, because of the closure.
    struct ButtonSpec: Identifiable {
        var id: String { system }
        let system: String; let help: String; let action: () -> Void
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(title).font(.headline)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            ForEach(buttons) { b in
                Button(action: b.action) { Image(systemName: b.system).frame(width: 26, height: 26) }
                    .buttonStyle(.bordered).help(b.help).accessibilityLabel(b.help)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
