# PromptTemplatePickerView

ASCII reference layout for `PromptTemplatePickerView`, kept in sync with the SwiftUI
view so the intended structure stays readable without running the app.

The popup for picking a prompt template and typing it into the focused terminal. It is
a sheet over the main window, opened two ways: ⌘P, and the "Prompt templates" item in
the app menu (between "Settings…" and the "Group" submenu). Both go through
`PromptTemplatesCommand` (in `WiettyApp.swift`), which flips the app-owned
`PromptTemplatePresentation.isPresented`; `ContentView` binds a `.sheet` to it. The
flag lives above the window for the same reason `PaneRouter` does: a command declared
in the scene's `commands` cannot reach a view's `@State`. See prompt-templates.md for
the file format and the substitution rules.

It has two steps. First a search over the templates. A template with `$1`/`$2`/
`$ARGUMENTS` in its body then asks for those values; a template with none is typed in
straight away.

## Step one: choosing

```
┌─ sheet ──────────────────────────────────────┐
│  Search prompt templates                      │
│ ───────────────────────────────────────────  │
│  Fix bug                                      │
│    Investigate and propose a fix             │
│  Refactor helper                             │
│    Reduce nesting                            │
│  Explain this code                           │
│    <highlighted row is selected>             │
│                                              │
│                                              │
└──────────────────────────────────────────────┘
```

The search field keeps the focus, and it is where the keyboard drives the list from:
typing filters, the up and down arrows move the highlight (`onMoveCommand`), and Return
chooses the highlighted row (`onSubmit`). A mouse click chooses a row directly. The
filter is `PromptTemplateFilter.match`, a subsequence match over the display name and
the description (so "fb" finds "Fix bug"), asserted in `PromptTemplateFilterTests`. As
the query narrows the results, a highlight that scrolled out of them jumps to the first
remaining row, so Return never acts on a template that is no longer shown.

Each row is the display name with the description under it in secondary text, or the
argument hint when there is no description, or nothing when there is neither.

With no templates at all the list is replaced by "No prompt templates yet." and a line
pointing at Settings › Prompts. With templates present but none matching the query, it
says "No matches."

## Step two: arguments

Shown only for a template whose body has placeholders (`PromptTemplate.hasArguments`).
One field per distinct `$N`, labelled from the `argument-hint` tokens where there is
one, or by `$N` where there is not. A body that uses only `$ARGUMENTS` gets a single
field labelled by the whole hint. `PromptTemplateTests` pins which fields a body asks
for.

```
┌─ sheet ──────────────────────────────────────┐
│  Fix bug                                      │
│                                              │
│  <ticket-id>                                 │
│  [__________________________________ ]       │
│  <area>                                      │
│  [__________________________________ ]       │
│                                              │
│                                              │
│  [ Back ]                        [ Insert ]  │
└──────────────────────────────────────────────┘
```

"Back" (Esc) returns to the search; "Insert" (Return) renders the template with the
typed values and hands the text to `onInject`. `$ARGUMENTS` becomes the field values
joined by a space, and each `$N` becomes its field's value, empty when the field was
left blank.

## What "insert" does

The view knows nothing about terminals: it hands the rendered text to `onInject` and
lets `ContentView` decide where it goes. `ContentView.injectTemplate` dismisses the
sheet, then writes the text to the focused local terminal through
`GhosttyService.send(sessionId:text:)`, the same write path a pasted keystroke takes.
No trailing newline is sent, so the cursor is left in the prompt and the text can be
edited before it is sent to the agent.

With no local terminal selected there is nowhere to type it, so `ContentView` reports
that through `store.lastError` rather than dropping the text: the popup is reachable
from the app menu even when the pane is showing settings or a remote session.

Legend:

- The sheet is bound to `PromptTemplatePresentation.isPresented`, flipped by ⌘P and
  the app menu item. That the menu item is present, kept ⌘P, and sits between Settings
  and Group is asserted in `SettingsPaneTests` against the running app's real menu.
- Only one step is on screen at a time, and the argument step is driven by internal
  state, so `PromptTemplatePickerView.init` takes a `showingArgumentsFor:` for the
  render test the way `AgentRow` takes `isEditing`
  (`PromptTemplatePickerTests.theArgumentStepRenders`).
- Editing the templates themselves is not here: that is the Settings › Prompts tab
  (see SettingsView.md). This popup only picks one to type in.
