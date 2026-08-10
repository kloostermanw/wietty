import SwiftUI

/// A line of test-process buttons with an `All` button pinned to the top right.
/// The per-test buttons flow (and wrap) on the left; each button's border color
/// reflects the last outcome (green passed, red failed, neutral for
/// never-run/stale) and shows a spinner while running. Clicking a button runs
/// that test; `All` runs every test (and never shows a spinner itself). Rendered
/// only when the workspace defines at least one test (the caller guards on
/// `!tests.isEmpty`).
struct TestProcessesLineView: View {
    let tests: [ManagedProcess]
    let onRun: (ManagedProcess) -> Void
    let onRunAll: () -> Void
    let onOpenLog: (ManagedProcess) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            TestFlowLayout(spacing: 6) {
                ForEach(tests) { test in
                    TestButton(
                        label: test.name,
                        appearance: testButtonAppearance(for: test.state),
                        action: { onRun(test) }
                    )
                    .contextMenu {
                        Button("Run") { onRun(test) }
                        if processIsRunning(for: test.state) {
                            Button("Cancel") { test.kill() }
                        }
                        Divider()
                        Button("Open log") { onOpenLog(test) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TestButton(
                label: "All",
                appearance: TestButtonAppearance(style: .neutral, running: false),
                action: onRunAll
            )
        }
    }
}

/// One test button: a rounded, bordered capsule whose border color comes from
/// the appearance style; a spinner overlays the label while running.
private struct TestButton: View {
    let label: String
    let appearance: TestButtonAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if appearance.running {
                    ProgressView().controlSize(.mini)
                }
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var borderColor: Color {
        switch appearance.style {
        case .neutral: return .secondary.opacity(0.5)
        case .passed: return .green
        case .failed: return .red
        }
    }

    private var helpText: String {
        if appearance.running { return "Running…" }
        switch appearance.style {
        case .neutral: return "Not run"
        case .passed: return "Passed"
        case .failed: return "Failed"
        }
    }
}

/// A minimal flow layout: lays children left to right, wrapping to a new line
/// when the row width is exceeded. Keeps the button line from clipping when a
/// workspace defines many tests.
private struct TestFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0, totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalWidth = max(totalWidth, rowWidth - spacing)
                totalHeight += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth - spacing)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
