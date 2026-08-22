# Prompt templates

A prompt template is a reusable prompt for an AI agent, stored as a markdown file and
typed into the focused terminal from a popup. They are conceptually similar to Claude's
command feature: a folder of markdown files, optional frontmatter, and argument
placeholders.

## Where they live

Each template is one markdown file in `~/.config/wietty/prompt_templates/`, beside the
`config` and `ghostty.cfg` files. The file is the template's identity: renaming the
display name in the frontmatter keeps the same file, and editing rewrites it in place.
The directory is read when the popup opens and when the Settings tab appears, so a file
added or edited outside the app shows without a relaunch. Wietty does not watch the
directory the way it watches `ghostty.cfg`.

`PromptTemplateFile` reads and writes the directory, `PromptTemplate` is the parsed
value, and `PromptTemplateStore` owns the in-memory list the popup and the settings
page share.

## File format

Optional YAML frontmatter between `---` lines, then the prompt body:

```markdown
---
name: Fix bug
description: Investigate and propose a fix
argument-hint: <ticket-id> <area>
---
Investigate bug $1 in $2. Focus on $ARGUMENTS.
```

- **`name`** is the display name in the popup and the settings list. When it is absent
  (or there is no frontmatter at all), the filename without `.md` is used instead, so a
  plain body file a user drops in by hand still works.
- **`description`** is a one-line summary, shown under the name.
- **`argument-hint`** is a space-separated list of tokens that label the argument
  fields, one token per placeholder. In the example, `<ticket-id>` labels `$1` and
  `<area>` labels `$2`.

Frontmatter is optional and tolerant. A file that does not open with a `---` line, or
whose frontmatter is never closed by a second `---`, is treated as all body, so nothing
is silently dropped.

## Placeholders

The body may reference values the popup asks for before it types the template in:

- **`$1`, `$2`, ...** are positional. Each becomes its own field in the popup, in
  ascending order.
- **`$ARGUMENTS`** is every field value joined by a space. A body that uses only
  `$ARGUMENTS` and no `$N` gets a single field, labelled by the whole argument hint.

A `$N` left blank renders as empty rather than staying a literal `$N`. Multi-digit
indices are handled, so `$10` is not confused with `$1`. A body with no placeholders is
typed straight in with no argument step.

## Using one

The popup opens two ways: ⌘P, and the "Prompt templates" item in the app menu (between
"Settings…" and the "Group" submenu). Search filters the list by a subsequence match on
the name and description; the arrow keys move the highlight and Return chooses it. A
template with placeholders then asks for their values; one without is typed in straight
away.

The rendered body is written into the local terminal on screen through
`GhosttyService.send`, the write path MCP `send_input` and remote keystrokes use. No
trailing newline is sent: the cursor is left in the prompt so the text can be edited
before it is sent to the agent. With no local terminal on screen (the pane is showing
settings, a remote session, or a log) there is nowhere the user can see it typed, so
Wietty asks for a terminal to be brought forward rather than writing to the hidden one.

See AsciiScreens/PromptTemplatePickerView.md for the popup and AsciiScreens/SettingsView.md
for the Settings › Prompts tab that creates, edits, and deletes templates.

## Managing them

The Settings › Prompts tab lists every template with edit and delete buttons and a form
to add one. Adding writes a new file named from a slug of the name (for example
`fix-bug.md`), with a numeric suffix when that name is already taken. Editing rewrites
the same file; deleting removes it. You can also add or edit the files directly in
`~/.config/wietty/prompt_templates/`; the changes show the next time the popup or the
tab is opened.
