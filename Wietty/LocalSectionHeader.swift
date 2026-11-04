/// What the sidebar's Local section header shows, and whether the section under it
/// is collapsed.
///
/// The title exists to tell the local Mac's workspaces apart from one section per
/// remote connection. With no connection configured there is no second section, so
/// the word and its chevron say nothing and the header is not drawn at all. Its
/// buttons are not lost with it: refreshing git status and adding a folder live in
/// the window's top row (`SidebarTopBar`), not in this header.
///
/// Dropping the chevron takes the only way to expand the section with it, so a
/// stored collapse is ignored rather than obeyed while the title is hidden. Ignored,
/// not cleared: adding a connection puts the chevron back and the section is
/// collapsed again, which is what the user last asked for.
///
/// A rule with its own type rather than two expressions inside `ContentView.body`,
/// so both parts are asserted in CI. See `LocalSectionHeaderTests`.
struct LocalSectionHeader: Equatable {
    /// Nil when there is no header to draw, so no chevron either.
    let title: String?
    let collapsed: Bool

    static func resolve(hasRemoteConnections: Bool, storedCollapsed: Bool) -> LocalSectionHeader {
        guard hasRemoteConnections else { return LocalSectionHeader(title: nil, collapsed: false) }
        return LocalSectionHeader(title: "Local", collapsed: storedCollapsed)
    }
}
