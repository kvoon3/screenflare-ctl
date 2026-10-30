# How Screenflare's menus are driven

Screenflare (0.1.24) has no URL scheme, AppleScript dictionary, CLI or Shortcuts
actions. Its menu bar is the only external surface, and every action this tool
exposes is one menu item. That is why `--json` reports the menu titles it pressed:
if Screenflare renames one, you see exactly which id broke.

## Reading the tree

One `AXUIElementCreateApplication(pid)` per run walks `AXMenuBar` → menu bar items →
menus → menu items. For each item the tool reads:

| Attribute | Used for |
| --- | --- |
| `AXTitle` | matching against `Localizable.strings` |
| `AXEnabled` | refusing to press a disabled item; `Stop Recording`'s bit is "is recording" |
| `AXMenuItemCmdChar` + `AXMenuItemCmdModifiers` | the shortcut a user assigned in Settings ▸ Shortcuts |
| `AXMenuItemMarkChar` | checkmark (unused today, kept for completeness) |

This needs only the caller's own Accessibility trust. It performs no Apple Events, so
no Automation grant, and no `osascript` child processes.

## Titles come from the app, not from English

`Contents/Resources/<lang>.lproj/Localizable.strings` holds the menu titles. The tool
picks the language Screenflare will actually render — per-app `AppleLanguages`, then
the global one, then `Locale.preferredLanguages` — and looks each id up by key:

| id | menu | key |
| --- | --- | --- |
| `capture-area` | File | `menu.file.captureScreenshot` |
| `capture-window` | File | `menu.file.captureWindow` |
| `capture-fullscreen` | File | `menu.file.captureFullscreen` |
| `capture-scrolling` | File | `menu.file.captureScrolling` |
| `capture-text` | File | `menu.file.captureText` |
| `record-display` | File | `menu.file.recordDisplay` |
| `record-window` | File | `menu.file.recordWindow` |
| `record-area` | File | `menu.file.recordArea` |
| `record-or-capture` | File | `menu.file.captureBar` |
| `stop-recording` | File | `menu.file.stopRecording` |
| `pause-recording` | File | `menu.file.pauseRecording` |
| `new-recording` | File | `menu.file.newRecording` |
| `open-last-recording` | File | `menu.file.openLastProject` |
| `screenshot-history` | File | `menu.file.screenshotHistory` |
| `recording-history` | File | `menu.file.previousProjects` |
| `open-image` / `open-image-editor` | File | `menu.file.openImage` / `menu.file.openImageEditor` |
| `settings` | Screenflare | `menu.app.settings` |

Matching falls back from exact title → normalized title (ellipsis, case, spacing) →
the trailing words of the key (`recordWindow` → "record window"), because the app menu's
bar title is the product name and carries no localization key.

`screenflare-ctl list` prints the resolved titles, enabled state and live shortcut of
every id — that output is the ground truth after any Screenflare update.

## Default shortcuts

Read off a running 0.1.24; all ten are rebindable in **Settings ▸ Shortcuts**, and
the menu reflects whatever the user set.

| Action | Default |
| --- | --- |
| Capture Screenshot (region) | ⇧⌘4 |
| Capture Window | ⌥⇧⌘3 |
| Capture Fullscreen | ⇧⌘3 |
| Scrolling Capture | ⌥⇧⌘4 |
| Capture Text | ⌥⌘8 |
| Record Display | ⌥⌘3 |
| Record Window | ⌥⌘4 |
| Record Area | ⌥⌘5 |
| Record or Capture… | ⇧⌘5 |
| Pause Recording | ⌥⌘2 |

*Stop Recording* has none; its enabled bit doubles as the recording state.

## What a press does and does not guarantee

- Region and window captures wait for the user (drag a box, pick a window, press
  `Space`, `Esc` to cancel), so `--no-wait` returns before any artifact exists.
- `capture-text` copies the recognised text itself; the tool waits for the pasteboard
  `changeCount` to move rather than polling for different text.
- Artifacts are found by diffing `~/Screenflare/{screenshots,recordings}` before and
  after the press — Screenflare decides the file names, and its `meta.json` (schema
  version 1) is passed through untouched.
