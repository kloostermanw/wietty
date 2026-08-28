# TestProcessesLineView

ASCII reference layout for `TestProcessesLineView`, a single line inside a
workspace card that surfaces the project's test-process buttons, kept in sync
with the SwiftUI view so the intended structure stays readable without running
the app.

## Line

One button per test process flowing (and wrapping) on the left, with an `All`
button pinned to the top right of the line. Rendered by `WorkspaceCardView`
only when the workspace defines at least one test (`!tests.isEmpty`); it sits
between the CI checks line and the Processes/terminal tree, indented with the
same leading padding as those lines.

```
[phpunit]  [feature-tests]  [⟳ npm-test]              [All]
[extra-test]
```

Legend:

- Each test button: `test.name`, a rounded, bordered capsule
  (`TestButton`/`TestFlowLayout`). Border color comes from
  `testButtonAppearance(for: test.state)`: green for the last run having
  passed, red for failed, gray/secondary (neutral) for never-run or stale
  (working tree changed since the last pass).
- `⟳` (shown as a spinner overlay, not a literal glyph): the button shows a
  `ProgressView` in place of/alongside its label while the test is running
  (`appearance.running`).
- `All`: a button pinned to the top right that runs every test (`onRunAll`).
  It has neutral styling and never shows a spinner of its own.
- Layout: the per-test buttons live in a `TestFlowLayout` that fills the width
  to the left of the `All` button and wraps onto additional rows left to right
  when they would otherwise overflow, so a workspace with many tests doesn't
  clip. The `All` button stays in the top right regardless of how many rows the
  test buttons occupy (the enclosing `HStack` is top-aligned).
- Click: runs that single test (`onRun`).
- Context menu per test button: Run (`onRun`); Cancel (`test.kill()`), shown
  only while that test is running; Open log (`onOpenLog`, opens a
  the pane with a `ProcessLogRef` carrying `isTest: true`, via `WorkspaceCardView.onOpenTestLog`);
  Copy ID for agent (`onCopyId`), which copies the test's `ManagedProcessID`
  (`<workspace-id>:test:<name>`) so the MCP tools can act on it from a prompt:
  `run_test` runs it (the Run button's equivalent, as `run_all_tests` is the All
  button's), and `get_managed_process_*` read its status and output. See
  `docs/mcp.md`.
- Tooltip (`.help`): "Running…" while running, otherwise "Not run" / "Passed" /
  "Failed" based on the button's style.
