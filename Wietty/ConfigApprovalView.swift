import SwiftUI

/// Asks whether the commands in a workspace's `wietty.json` may run.
///
/// The commands are shown in full and are the reason the sheet exists, so they get
/// the room: a scrolling monospaced list rather than a sentence summarising them.
/// A user who cannot read the line cannot answer the question.
///
/// "Don't run" is the default action, and there is no way to dismiss this into
/// running the file by accident: closing it is declining.
struct ConfigApprovalView: View {
    let request: ConfigApprovalRequest
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run commands from \(request.workspaceName)?")
                .font(.headline)
            Text("This folder's wietty.json asks to run the lines below. They run in the folder, as you, and some can start without being clicked. Run them only if you trust this folder.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(request.commands.enumerated()), id: \.offset) { _, command in
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 80, maxHeight: 200)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))

            Text("Nothing from the file is applied until you do, and declining leaves the workspace as it is rather than hiding it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Don't run", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: onRun)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
