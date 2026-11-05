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
│ ● MCP 127.0.0.1:7433 ⟳                                ⚙ 6 running   ▤ 412 MB │
└─────────────────────────────────────────────────────────────────────────────┘
  StatusBarView, 22 points, full width. The MCP item on the left, the process
  count and memory on the right, with a spacer between.
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

## Running processes

```
⚙ 6 running        tooltip: "2 terminals, 1 agent, 2 processes and 1 test running"
```

`RunningProcessCounts`, read from `ProjectStore.runningProcessCounts`, across every
workspace. It counts four kinds:

- Terminals and agents, by `isSessionRunning`, the rule that tints a row's glyph
  green in the sidebar. A terminal counts while its shell lives. An agent counts only
  while the agent is the foreground job, so one that quit back to its shell does not.
- The managed processes and tests that workspaces declare in `wietty.json`, by
  `processIsRunning`, the rule the rows use for their stop button. A process that is
  starting, stopping, or orphaned but still alive counts.

Everything it reads is `@Observable` (the store's job names and both supervisors), so
the count redraws as soon as something starts or ends.

## Memory

```
▤ 412 MB           below a gigabyte, whole megabytes
▤ 1.5 GB           from a gigabyte, one decimal
```

`AppMemory.footprintBytes()`: the process's physical footprint (`phys_footprint`
from `TASK_VM_INFO`), which is the number Activity Monitor's Memory column shows,
in the same binary units. It is Wietty's own process only. The shells and agents
in its terminals are separate processes and are not included, which the tooltip
says. `AppMemoryMonitor`, owned by `ContentView`, samples it every two seconds and
only writes when the value changed. The item is left out until the first sample.

## Always there

The bar is always present, for the same reason `NavBarView` is: a bar that came and
went would move the terminal above it. Its height is part of
`SidebarWidth.windowMinimumHeight`.
