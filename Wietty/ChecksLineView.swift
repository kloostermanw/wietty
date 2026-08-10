import SwiftUI

struct ChecksLineView: View {
    let summary: ChecksSummary

    var body: some View {
        Text(summary.summaryText)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var color: Color {
        switch summary.status {
        case .failed: return .red
        case .running: return .yellow
        case .passed: return .green
        }
    }
}
