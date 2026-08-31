import SwiftUI

/// The popover shown when the card's `!` marker is clicked: the freshness checks
/// that are asking for action, each with its instruction and, when the command
/// printed something, that output as secondary detail. Only actionable results are
/// listed; a clean check is not news.
struct FreshnessDetailView: View {
    let results: [FreshnessResult]

    static let title = "Needs attention"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.title)
                .font(.headline)
            ForEach(results.actionable) { result in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(result.message)
                    }
                    if !result.detail.isEmpty {
                        Text(result.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 18)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
    }
}
