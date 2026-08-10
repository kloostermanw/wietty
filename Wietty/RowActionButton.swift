import SwiftUI

/// A small, borderless icon button used for the hover-revealed actions on
/// process and terminal rows. Kept visually consistent between both row types.
struct RowActionButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
