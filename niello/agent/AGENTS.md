# Using the agent harness (`niello/agent`)

These instructions are for coding agents building a NielloUI app. The harness
lets you see and check the UI you write without a window: it runs your
app's own `declare` proc headless, acts on it the way a user does, writes
each screen down as text, and reports what is wrong with a pointer to the
line of code that caused it.

Use it every time you change UI code. Don't stop at "it compiles": run a
scenario, read the snapshot and the findings, fix them, and run it again
until the report says PASS.

## The loop

1. Write or change the app's UI code.
2. Write a scenario: one `@(test)` that opens a session, does what a user
   would do, and takes a snapshot of each screen that matters.
3. Run it with `tools/agent.sh <app-package>`.
4. Read `findings.txt` first, then the snapshots. Each finding starts with
   `file:line`; go there.
5. Fix the code, not the scenario, and run it again. Exempt something with
   `allow` only when it is deliberate, and say why in a comment.

## A scenario

Put scenarios in the app's own package, in a file like `agent_test.odin`.
Import the packages the same way the app does. The template below uses the
`niello` collection (`-collection:niello=path/to/niello`); an app that
imports by relative path (`niello "../../niello"`, `"../../niello/agent"`)
does the same here.
Wrap them in `when niello.NIELLO_DEBUG`: the harness exists only in debug
builds, and the wrapper keeps the app's normal release test run building.

```odin
package main

import "core:testing"
import niello "niello:."
import "niello:agent"

when niello.NIELLO_DEBUG {

	@(test)
	add_item :: proc(t: ^testing.T) {
		// Set the app up exactly as main does (mint units, controls.init,
		// state), but don't call niello_sdl.run.
		app: App
		app_init(&app)
		defer app_destroy(&app) // and niello.shutdown(), as main does

		s := agent.session_open(declare, &app, ctx = app.ctx, viewport = {1180, 780})
		defer agent.session_close(s)
		agent.snapshot(s, "start")

		agent.click(s, agent.find(s, role = .Edit, name = "Item name"))
		agent.type_text(s, "Milk")
		agent.press_key(s, .Enter)
		agent.snapshot(s, "added")
		testing.expect(t, agent.exists(s, text = "Milk"), "the new item is listed")

		testing.expect(t, agent.report(s) == 0, "no findings")
	}
}
```

- **Typed or plain declare:** `session_open(declare, &state)` takes a typed
  declare proc. For a plain `proc()` that keeps its state in package
  variables, use `session_open_plain(declare)`.
- **The app's context:** if the app keeps its own `^niello.Context`, pass
  it as `ctx`. Otherwise the session makes one.
- **The viewport:** use the window size the app opens with. Text is
  checked only where it is drawn, so to check a whole scrolling page,
  open the session taller (for example `{1180, 3000}`).
- **Cleanup:** do the app's own teardown and call `niello.shutdown()`;
  otherwise the test runner reports leaks.
- **The scenario's name** is the test procedure's name. It names the
  report folder.

## Running it

```sh
tools/agent.sh path/to/app                  # every test in the package
tools/agent.sh path/to/app add_item         # one scenario
```

On Windows, use `tools\agent.ps1` the same way. It builds with
`-define:NIELLO_DEBUG=true -define:ODIN_TEST_THREADS=1`, which are both
required. It prints one summary line per scenario and its findings.

Reports land in `agent-out/<scenario>/`, under the directory you run from;
set `NIELLO_AGENT_OUT` to put them elsewhere:

- `findings.txt`: one finding per line;
- `summary.txt`: PASS or FAIL, the counts, the viewport, the text metrics
  used, the allows, and every step the scenario took;
- `NN-label.txt`: one per snapshot, in order.

## Reading a snapshot

```
# added: 1180x780 DIP, focus: Edit "Item name"
Text "Shopping" @16,16 80x20  app/main.odin:60
Edit "Item name" [focused] @16,44 1148x30  app/main.odin:61
Button "Add item" @16,82 84x30  app/main.odin:62
Text "Milk" @16,120 30x16  app/main.odin:67
Text "a label far too long for it" @16,176 60x16 !Truncated  app/main.odin:74
```

- **What gets a line:** each control, by its accessibility role and name
  (with `= value` and `[state]`), and each piece of text. A control's own
  label isn't repeated under it.
- **Indentation** is nesting under the control a line belongs to.
  Containers with nothing to show are skipped.
- **`@x,y wxh`** is the rect in DIP.
- **The trailing `file:line`** is where it was declared. For a control
  from `niello/controls`, that is your call to it.
- **`!Kind`** marks a node with a finding.
- **`[out of view]`** marks text the renderer did not draw, because it was
  scrolled or clipped away. A footer counts it: that text has not been
  checked yet.

## Finding controls

`find(s, role = …, name = …, text = …)` returns exactly one control. If
nothing matches, or more than one thing does, it records a finding that
lists what *is* there, and it returns a target that every action ignores.
Read that list: it usually shows the name you should have used.

What the shipped controls are called:

| Control | role | name |
|---|---|---|
| `controls.button`, `toggle_button` | `.Button` | its text |
| `controls.checkbox`, `toggle_switch` | `.CheckBox` | its label |
| `controls.radio_group` | `.Group`, with one `.RadioButton` per option | the group's label; each option's text |
| `controls.combo_box` | `.ComboBox`; while open, `.ComboBoxItem` per option | its label; the option's text |
| `controls.text_box` | `.Edit` | its placeholder |
| `controls.slider` / `progress_bar` | `.Slider` / `.ProgressBar` | its label |
| `controls.tooltip` | `.ToolTip` | its text |

For your own components, give the root a role and a label in its `With`
(`role = .Button, label = "…"`): that is what both screen readers and the
harness see. Use `text = "…"` to find plain text such as a label or a
status line. Use `exists(...)` to check whether something is there
without recording a finding.

## Acting

| Call | What it does |
|---|---|
| `click(s, t)` | moves the pointer to `t`'s center, presses and releases |
| `hover(s, t)` | moves the pointer there and leaves it there |
| `type_text(s, "…")` | types into whatever has keyboard focus (click the box first) |
| `press_key(s, .Enter)`, `press_key(s, .Tab, {.Shift})` | a key, with modifiers |
| `resize(s, {w, h})` | changes the window size |
| `wait(s, seconds)` | lets simulated time pass with no input |
| `step(s, n)` | runs `n` frames |
| `settle(s)` | runs until the screen is still |

Every action first scrolls its target into view (as a user would), and
settles afterwards. Settling runs in simulated time: animations play at
60 frames a second, and a delay with nothing animating (a tooltip's, a
timer's) is skipped straight to its end. So a snapshot taken after an
action always shows the finished result.

The actions report problems instead of acting:
- **Disabled_Target:** the target is disabled.
- **Covered_Target:** the pointer can't reach the target. Something lies
  over it, or it is outside the window with no scroller to bring it in.

## What the findings mean, and the usual fix

| Kind | Meaning | Usual fix |
|---|---|---|
| `Not_Found` | `find` matched nothing | Use the name from the candidates it lists; give your component a role or label |
| `Ambiguous` | `find` matched several | Give them different labels, or find by role and name together |
| `Truncated` | A line of text is cut short with "…" | Give it room: `wrap = .Word` for prose, a `grow()` width, a wider box, or a lower `priority` on a sibling that can give way |
| `Collapsed` | A control has no width or height, so it can't be seen or clicked | Something sized it `fit()` with nothing inside: give it a size. A `With.size` sets both axes; to set one, `keep()` the other: `size(fixed(240), keep())` |
| `Overflow` | Children, or drawn text, run past their box | Make the box `fit()` or `grow()`; let text wrap; give the box `scroll = .Vertical` if it is meant to scroll |
| `Unsettled` | The screen still changes after 10 simulated seconds | Something is shown that changes every frame: a frame counter, a timestamp, or a `hover_duration` readout. Show it only while needed |
| `Idle_Wakes` (warning) | Nothing changes, but the app keeps asking for frames | Usually `hover_duration` compared against a threshold: use `hovered_for(i, seconds)` instead |
| `Disabled_Target` / `Covered_Target` | The action could not happen | Check the state the scenario expects; a popup or overlay may be in the way |

Each node is reported once per kind, however many snapshots it appears in.
A finding inside a control (a button's label) is reported against the
control, at your line.

## Allowing what is deliberate

```odin
agent.allow(s, .Truncated, ui.demo_label)                       // every node of a unit
agent.allow(s, .Unsettled, agent.find(s, text = "not hovered")) // one node
```

Allows are listed in `summary.txt`. Don't use them to make a report pass;
fix the code instead.

## Good to know

- **Text metrics:** an app that imports `niello/sdl` measures text with
  the real fonts, the same ones the window draws with; `summary.txt` says
  which metrics were used. `metrics = .Mock` gives fixed-width text that
  measures the same on every machine. Use it only for golden-file
  comparisons, since it hides real truncation.
- **Assertions:** check what users see, through `exists` and `find`, not
  coordinates. Use snapshots to look; use `testing.expect` to pin
  behavior.
- **Golden files:** `agent.dump(s, label, locs = false)` returns a
  snapshot's text without the file:line columns, for comparing with an
  expected string.
- **The session's record:** `s.findings` holds every finding so far, and
  `s.steps` every step.
- **Read the snapshot, not just PASS:** the lints catch what can be
  measured exactly. A control in the wrong place, or one that is the right
  size but looks wrong, only shows when you read the snapshot.
- **Labels of `combo_box` and `slider`:** these name the control for
  screen readers and for `find`, and draw nothing. Show a visible label
  yourself when the screen needs one. `checkbox` draws its label.
- **Where focus goes:** focus moves only when a click, Tab or the app
  moves it. `type_text` with nothing focused types into nothing, so check
  the snapshot's `focus:` header.
