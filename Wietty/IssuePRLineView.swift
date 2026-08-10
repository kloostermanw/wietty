import SwiftUI
import AppKit

struct IssuePRLineView: View {
    let branch: String
    let issueNumber: Int?
    let issueURL: URL?
    let prNumber: Int?
    let prURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            if let issueNumber {
                pill(text: "Issue #\(issueNumber)", url: issueURL)
            } else {
                Text(branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let prNumber {
                pill(text: "PR #\(prNumber)", url: prURL)
            }
        }
    }

    @ViewBuilder
    private func pill(text: String, url: URL?) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Text(text)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.22), in: Capsule())
                .foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}
