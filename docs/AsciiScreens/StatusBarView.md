# StatusBarView

ASCII reference layout for `StatusBarView`, the bar along the bottom of the main
window, kept in sync with the SwiftUI view.

## Where it sits

Under both halves of the window, the sidebar and the right column alike. It reports
on the app rather than on whatever the pane shows, so it does not belong to the right
column the way `NavBarView` does. `ContentView` attaches it as a bottom safe area
inset of the whole row, with a `Divider` along its top edge.

```
┌──────────────────────────────────┬──────────────────────────────────────────┐
│ sidebar                          │ pane                                     │
├──────────────────────────────────┴──────────────────────────────────────────┤
│ ● MCP 127.0.0.1:7433 ⟳                                                       │
└─────────────────────────────────────────────────────────────────────────────┘
  StatusBarView, 22 points, full width
```

## The MCP item

```
running:    ● MCP 127.0.0.1:7433 ⟳        green dot
starting:   ◌ MCP starting ⟳              grey dotted circle
failed:     ⚠ MCP not running ⟳           red triangle
stopped:    ⚠ MCP stopped ⟳               red triangle
```

Legend:

- The symbol and its colour come from `MCPServerStatus.health`, through
  `StatusBarView.symbol(for:)` and `StatusBarView.color(for:)`. The MCP tab of
  Settings uses the same two functions, so both places say it the same way.
- The text is `MCPServerStatus.summary`. Hovering the item shows
  `MCPServerStatus.detail`, which carries what the summary leaves out: the full URL
  when running, the reason when it failed (for example the port is already in use).
- `⟳`: restarts the MCP server on the port it already has
  (`MCPServerHost.restart()`, through `ContentView.restartMCPServer`).
- Right click: "Restart MCP Server", and "Copy Endpoint URL" while the server is
  running.

`running` means the port is bound. The host only enters it from Hummingbird's
`onServerRunning`, so a server that tried to start and could not bind never shows
green. See `docs/mcp.md`.

The bar is always present, for the same reason `NavBarView` is: a bar that came and
went would move the terminal above it. Its height is part of
`SidebarWidth.windowMinimumHeight`.
