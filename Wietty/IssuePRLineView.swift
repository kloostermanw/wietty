import SwiftUI
import AppKit

struct IssuePRLineView: View {
    let branch: String
    let issueNumber: Int?
    let issueURL: URL?
    let prNumber: Int?
    let prURL: URL?

    @Environment(\.sidebarColors) private var sidebarColors

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
                .background(IssuePRPillColors.fill(override: sidebarColors.pillBackground), in: Capsule())
                .foregroundStyle(IssuePRPillColors.text(override: sidebarColors.pillForeground))
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}

/// The colours the Issue/PR pills draw, resolved from the optional overrides in
/// `SidebarColors`. Nil keeps the default an untouched install has (the fill is a
/// faint accent wash, the text the fixed `#5fdeff`); a set colour is used as-is. Pure
/// so the fallback and the override are both asserted in CI.
enum IssuePRPillColors {
    /// The default Issue/PR pill text colour, used when no override is set.
    static let defaultText = ColorHex.color(from: "#5fdeff") ?? .accentColor

    static func fill(override: Color?) -> Color {
        override ?? Color.accentColor.opacity(0.22)
    }

    static func text(override: Color?) -> Color {
        override ?? defaultText
    }
}
