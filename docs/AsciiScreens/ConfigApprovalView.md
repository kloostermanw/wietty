# ConfigApprovalView

ASCII reference layout for `ConfigApprovalView`, kept in sync with the SwiftUI view
so the intended structure stays readable without running the app.

A sheet over the main window, shown by `ContentView` whenever
`ProjectStore.pendingConfigApproval` is not nil. It asks whether the shell lines in a
workspace's `wietty.json` may run. See `../wietty-json.md` for what the file can ask
for and `ConfigTrust` for what counts as a line worth asking about.

```
┌─ sheet (420 wide) ───────────────────────────────┐
│  Run commands from genotool?                     │
│                                                  │
│  This folder's wietty.json asks to run the lines │
│  below. They run in the folder, as you, and some │
│  can start without being clicked. Run them only  │
│  if you trust this folder.                       │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ codex --model o3                           │  │
│  │ npm run dev                                │  │
│  │ phpstan analyse                            │  │
│  │ export PATH=$HOME/bin:$PATH                │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  Nothing from the file is applied until you do,  │
│  and declining leaves the workspace as it is     │
│  rather than hiding it.                          │
│                                                  │
│                    [ Don't run ]      [ Run ]    │
└──────────────────────────────────────────────────┘
```

## What each part is

- The title names the workspace (`ConfigApprovalRequest.workspaceName`), because
  "this folder wants to run these commands" is not a question anyone can answer
  without knowing which folder.
- The command list is `ConfigApprovalRequest.commands`: exactly the lines not agreed
  to before, so a file that mostly repeats an approved one asks only about what is
  new. Monospaced, selectable, and scrolling between 80 and 200 points high. The
  lines are the whole question, so they get the room rather than a sentence
  summarising them: a user who cannot read the line cannot answer.
- `[ Don't run ]` is the cancel role and carries the escape shortcut, so dismissing
  the sheet any way at all declines. There is no path that runs the file by accident.
- `[ Run ]` is the default action. It calls `ProjectStore.approvePendingConfig()`,
  which records the lines against that workspace and then reconciles, so the rows and
  the process definitions arrive together with the approval.

## Why a sheet and not an alert

An alert gives a list of shell lines no room, and this is the one prompt in the app
where reading before pressing is the point.

## What the answer is remembered as

Per workspace, as the set of lines agreed to (`ProjectStore.approvedCommands`,
persisted under `wietty.approvedCommands`), not as a flag on the folder and not as a
hash of the file. So removing a row, renaming the workspace or reordering entries
never asks again, and a line nobody has seen always does, including one added to a
file that was approved a year ago.

Declining records nothing, so the question comes back the next time the file is
reached for. A decline is not a decision about the folder for good.
