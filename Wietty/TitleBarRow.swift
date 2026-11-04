import SwiftUI
import AppKit

/// The sidebar's half of the window's top row, the one the traffic lights sit in.
///
/// The window has no title bar of its own (`.hiddenTitleBar`) and its content runs
/// up under where one would be, so this row and `NavBarView` share that strip: the
/// sidebar's buttons here, beside the traffic lights, and the pane's title and gear
/// across the right column. Put on the workspace list with `sidebarTopBar(buttons:)`,
/// so the buttons stay put while the list scrolls under them.
struct SidebarTopBar: View {
    let buttons: [SidebarSectionHeaderView.ButtonSpec]

    var body: some View {
        HStack(spacing: 4) {
            // The traffic lights take the leading edge, so the buttons go trailing,
            // which is where they sat in the Local header before they moved here.
            Spacer(minLength: 0)
            ForEach(buttons) { TitleBarButton(spec: $0) }
        }
        .padding(.horizontal, 10)
        .frame(height: NavBarView.height)
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
    }
}

extension View {
    /// Puts `SidebarTopBar` over the top of this scroll view, as an inset rather than
    /// as a row stacked above it.
    ///
    /// Load bearing, not style. A SwiftUI `ScrollView` reaches up to the window's top
    /// edge whatever is stacked above it, and in a window whose content runs under the
    /// title bar AppKit lays a backdrop over that strip for the scroll edge effect. A
    /// bar stacked above the scroll view sat beneath both, and every click on its
    /// buttons went to the scroll view instead. An inset is drawn in front of the
    /// scroll view, and the list starts below it. `TitleBarRowTests` clicks it.
    func sidebarTopBar(buttons: [SidebarSectionHeaderView.ButtonSpec]) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { SidebarTopBar(buttons: buttons) }
    }
}

/// One icon button in the window's top row, drawn the way the gear always was:
/// plain, secondary, in a 22 point target. A bordered button is taller than the
/// 28 point row, which is why the sidebar's buttons changed style when they moved.
struct TitleBarButton: View {
    let spec: SidebarSectionHeaderView.ButtonSpec
    /// Tinted while what the button opens is on screen. Only the gear uses it.
    var highlighted = false

    var body: some View {
        Button(action: spec.action) {
            Image(systemName: spec.system)
                .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
                // The glyph alone is a roughly 13 point target. The frame and the
                // shape give it the row's height to be clicked in rather than the
                // icon's outline.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(spec.help)
        .accessibilityLabel(spec.help)
    }
}

/// The empty part of the top row, which moves the window the way a title bar does.
///
/// Needed because the content covers the title bar: what is under the pointer there
/// is this app's view, not AppKit's title bar, so nothing else would drag the window.
/// A double click does what the user set in System Settings › Desktop & Dock, the
/// same as double clicking a real title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        }
    }
}
