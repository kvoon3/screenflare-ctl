# screenflare-ctl

A stable automation surface for [Screenflare](https://screenflare.app) — the macOS
screen recorder/screenshot app that ships no URL scheme, AppleScript dictionary,
CLI or App Intents.

Screenflare's menu bar is the only hook it offers. The usual way to drive it is
AppleScript → System Events, which needs the **Automation** grant, spawns three
or four processes per action (each an Apple Event round-trip), and depends on
matching localized menu titles. `screenflare-ctl` replaces that with a single
Accessibility call:

* one `AXUIElementCreateApplication` per run, the menu tree is walked in-process
  (microseconds, no helper processes, no Apple Events);
* menu titles are resolved from Screenflare's own `Localizable.strings`, so every
  UI language works (en, es, fr, ja, zh-Hans);
* menu item **key equivalents and enabled bits** are reported, so callers learn
  the real state instead of guessing ("is it recording?" is the enabled bit of
  *Stop Recording*);
* results are read back from the library on disk, so a capture returns the file it
  produced instead of "the clipboard changed".

It performs no Apple Events. The only permission involved is **Accessibility**,
and it applies to the process that *launches* this tool (Raycast, your terminal,
the OpenLogi agent) — all of which typically already hold it.

## Build

```sh
make            # → bin/screenflare-ctl
make install    # symlink into ~/.local/bin
```

Requires the Swift toolchain from Command Line Tools (`swiftc`). Single file,
no dependencies.

## Use

```sh
screenflare-ctl doctor                 # environment + per-action resolution report
screenflare-ctl list                   # capabilities: titles, state, shortcuts
screenflare-ctl state --json           # {running, recording, paused, …}
screenflare-ctl action capture-window --json
screenflare-ctl action capture-text --json          # waits, prints the recognised text
screenflare-ctl action record-window --json         # waits until recording starts
screenflare-ctl action stop-recording --json        # returns the new recording dir
screenflare-ctl toggle --as window --json           # stop if recording, else start a window recording
```

All commands accept `--json` (one JSON object per run, stable `schema: 1`).
Exit codes: `0` ok, `2` usage, `3` app not running, `4` accessibility denied,
`5` menu item unresolved (app changed), `6` item disabled, `7` timeout,
`8` press refused.

### Actions

| id | Screenflare menu item | default shortcut |
| --- | --- | --- |
| `capture-area` | File ▸ Capture Screenshot | ⇧⌘4 |
| `capture-window` | File ▸ Capture Window | ⌥⇧⌘3 |
| `capture-fullscreen` | File ▸ Capture Fullscreen | ⇧⌘3 |
| `capture-scrolling` | File ▸ Scrolling Capture | ⌥⇧⌘4 |
| `capture-text` | File ▸ Capture Text | ⌥⌘8 |
| `record-display` | File ▸ Record Display | ⌥⌘3 |
| `record-window` | File ▸ Record Window | ⌥⌘4 |
| `record-area` | File ▸ Record Area | ⌥⌘5 |
| `record-or-capture` | File ▸ Record or Capture… | ⇧⌘5 |
| `stop-recording` | File ▸ Stop Recording | — |
| `pause-recording` | File ▸ Pause Recording | ⌥⌘2 |
| `new-recording` | File ▸ New Recording | ⌘N |
| `open-last-recording` | File ▸ Open Last Recording | ⌥⌘Z |
| `screenshot-history` | File ▸ Screenshot History… | — |
| `recording-history` | File ▸ Recording History… | — |
| `open-image` | File ▸ Open Image… | — |
| `open-image-editor` | File ▸ Open Image Editor | — |
| `settings` | Screenflare ▸ Settings… | ⌘, |

Shortcuts are read live from the menu, so they reflect whatever the user set in
**Screenflare ▸ Settings ▸ Shortcuts** (that page binds all ten actions, including
*Record Window*).

### JSON shape

```json
{"schema":1,"ok":true,"action":"capture-fullscreen","kind":"screenshot",
 "titles":["File","Capture Fullscreen"],"shortcut":"⇧⌘3",
 "dir":"/Users/me/Screenflare/screenshots/9C1F…","name":"9C1F…",
 "image":"/Users/me/Screenflare/screenshots/Screenshot 2026-10-29 at 19.03.05.png",
 "thumb":"…/thumbnail.png","meta":{"version":1,"kind":"display","pixelWidth":3024,…}}

{"schema":1,"ok":false,
 "error":{"code":"menu_item_disabled","message":"File ▸ Stop Recording is disabled right now.",
          "hint":"Nothing is recording."},
 "state":{"recording":false,…}}
```

`--no-wait` returns immediately after the press (`"pending": true`) for captures
that require user input.

`toggle` is a composite command, not a Screenflare menu item: it reads the
recording state first and then stops or starts. Shell-based launchers (OpenLogi,
Raycast, Hammerspoon) cannot branch on state themselves, so the branch lives here.
Add `--dry-run` to see which action it would press.

## Integration: OpenLogi (Logitech mice)

[OpenLogi](https://openlogi.org) binds buttons to an `Action` enum, and
`Action::RunShellCommand` is a first-class member of it: the button editor *and*
the Actions Ring editor both offer it (security-sensitive actions such as
`RunShellCommand` live under "power user" kinds in the pickers). A ring slot is
`{ action, icon?, label? }`, ring layouts are per device with per-app overrides,
and the ring is opened by binding any button to `ShowActionsRing`. So every
capability here works on a mouse button and inside the ring with **no code change
on either side**.

```toml
# ~/.config/openlogi/config.toml — buttons
[devices."unit:69ac62c8".bindings]
WheelTiltLeft  = { RunShellCommand = "$HOME/i/screenflare-ctl/bin/screenflare-ctl action capture-area --no-wait" }
WheelTiltRight = { RunShellCommand = "$HOME/i/screenflare-ctl/bin/screenflare-ctl toggle --as window --no-wait" }
Back           = "ShowActionsRing"
```

```toml
# ~/.config/openlogi/config.toml — Actions Ring (eight fixed slots, clockwise)
[devices."unit:69ac62c8".action_ring.default.slots]
Top    = { action = { RunShellCommand = "$HOME/i/screenflare-ctl/bin/screenflare-ctl action capture-window --no-wait" }, icon = "Camera", label = "Capture Window" }
Right  = { action = { RunShellCommand = "$HOME/i/screenflare-ctl/bin/screenflare-ctl action capture-scrolling --no-wait" }, icon = "Monitor", label = "Scrolling Capture" }
Bottom = { action = { RunShellCommand = "$HOME/i/screenflare-ctl/bin/screenflare-ctl action capture-text --no-wait" }, icon = "Search", label = "Capture Text" }
Left   = { action = { RunShellCommand = "$HOME/i/screenflare-ctl/bin/screenflare-ctl toggle --as display --no-wait" }, icon = "Camera", label = "Record / Stop" }

# Per-app override: the same ring in Safari loses the window capture and gains
# a page capture at the same position.
[devices."unit:69ac62c8".action_ring.per_app."com.apple.Safari".slots]
Right = { action = { RunShellCommand = "$HOME/i/screenflare-ctl/bin/screenflare-ctl action capture-scrolling --no-wait" }, icon = "Monitor", label = "Scrolling Capture" }
```

In the GUI the same thing is: button → *Run Shell Command*; ring slot → *Run Shell
Command*, then set the slot's label and one of the ring glyphs (`Camera`,
`Monitor`, `Search`, `Terminal`, `Grid`, …). Prefer authoring in OpenLogi's own UI:
its config writer re-flows hand-edited inline tables, so a hand edit can land as
invalid TOML (see `~/playground/my-mouse/README.md`).

### Always pass `--no-wait` from OpenLogi

`openlogi-inject` runs the command with `std::process::Command::output()` — it
**waits for the child to exit and drains its pipes, on the hook/gesture dispatch
thread**. A capture that waits for the artifact (the default) would stall that
thread for as long as the overlay stays open. `--no-wait` makes every command
return in ~40 ms:

* `capture-*` presses the menu item and exits; Screenflare's overlay continues on
  its own, and the finished screenshot still lands in the library.
* `toggle` reads the recording state, presses *Stop Recording* or *Record …*, and
  exits; the take is finalised in the background.

The cost of `--no-wait` is that nobody sees the artifact path or the OCR text —
the host has nowhere to show it. Raycast, which can await, omits the flag.

### What is still missing (a PR, not a config)

OpenLogi has no plugin or external-action catalog (`grep -r plugin crates/` finds
nothing), so Screenflare shows up in the ring as an anonymous shell command with
a glyph, not as a named integration that can render state. Two shapes would fix
that, in increasing order of effort:

1. `Action::Screenflare(ScreenflareAction)` appended to
   `crates/openlogi-core/src/binding/action.rs` (the enum is append-only on disk,
   so no `schema_version` bump), with catalog rows for label/icon/i18n and
   `openlogi-inject` executing `screenflare-ctl action <id> --no-wait`.
2. A generic external-action catalog (`~/.config/openlogi/actions.d/*.json`
   listing id, label, icon, command, optional state probe) rendered by the same
   pickers. Bigger, but it would let any CLI — this one included — become a
   first-class ring citizen.
