import SwiftUI

struct SidebarSectionHeaderView: View {
    let title: String
    let collapsed: Bool
    let onToggle: () -> Void
    let buttons: [ButtonSpec]

    struct ButtonSpec: Identifiable {
        let id = UUID(); let system: String; let help: String; let action: () -> Void
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
