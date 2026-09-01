import SwiftUI

struct AheadBehindView: View {
    let label: String
    let behind: Int
    let ahead: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 3) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                    Text("\(ahead)")
                }
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                    Text("\(behind)")
                }
                .foregroundStyle(behindColor)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// Colour of the behind (`↓`) group. A repo that is behind has commits to
    /// pull, the one number on the card that asks the user to act, so it reddens;
    /// level with the remote it stays the secondary of the rest of the row.
    var behindColor: Color { behind > 0 ? .red : .secondary }
}
