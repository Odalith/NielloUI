// Form demo: keyboard focus and text input (TODO #8, §3.17), on the
// shipped controls (niello/controls) — and the seed of TODO #10's form
// example.
//
// Two text boxes, two buttons, one tab order (declaration order).
// Tab / Shift+Tab moves, clicking a box focuses it, Enter inside a box
// jumps to the next stop. Space/Enter activates the focused button. The
// app owns each box's state (controls.Text_Box); the box applies the
// input the engine routes to it and declares itself.
package main

import "core:fmt"
import niello "../.."
import controls "../../controls"
import niello_sdl "../../sdl"

window_u, title_u, hint_u, caption_u, status_u, buttons_row_u: niello.Unit

// The app's state lives in one struct, handed to declare every frame
// by niello_sdl.run's typed form — no package globals for it.
Form :: struct {
	name, quest:       controls.Text_Box,
	clear_i, submit_i: niello.Instance,
	status:            string,
	status_buf:        [512]u8,
	focus_buf:         [128]u8,
}

mint :: proc() {
	t := controls.DARK
	controls.init(t)
	ink := []niello.Group{controls.groups.ink}
	dim := []niello.Group{controls.groups.dim}
	niello.mint(&window_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = t.bg, padding = niello.pad(24), gap = 10,
		groups = []niello.Group{controls.groups.bg},
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 24, font_color = t.ink, groups = ink})
	niello.mint(&hint_u, niello.NO_UNIT, {font_size = 13.5, font_color = t.dim, groups = dim})
	niello.mint(&caption_u, niello.NO_UNIT, {font_size = 13, font_color = t.dim, groups = dim})
	niello.mint(&status_u, niello.NO_UNIT, {font_size = 13.5, font_color = t.dim, groups = dim})
	niello.mint(&buttons_row_u, niello.NO_UNIT, {layout = niello.Layout.Left_To_Right, gap = 12})
}

declare :: proc(app: ^Form) {
	if niello.begin(window_u) {
		niello.show(title_u, {text = "Form"})
		niello.show(hint_u, {text = "Tab / Shift+Tab to move · click a box to focus · Enter jumps on · Space/Enter pushes a focused button"})

		niello.show(caption_u, {text = "NAME"})
		if controls.text_box(&app.name, "e.g. Ada").submitted {
			niello.focus_next() // Enter commits and moves on
		}
		niello.show(caption_u, {text = "QUEST"})
		if controls.text_box(&app.quest, "e.g. To seek the grail").submitted {
			niello.focus_next()
		}

		declare_buttons(app)

		focus_name := "nothing"
		if niello.focused(app.name.inst) {
			focus_name = "Name"
		} else if niello.focused(app.quest.inst) {
			focus_name = "Quest"
		} else if niello.focused(app.clear_i) {
			focus_name = "Clear"
		} else if niello.focused(app.submit_i) {
			focus_name = "Submit"
		}
		niello.show(status_u, {text = fmt.bprintf(app.focus_buf[:], "focused: %s", focus_name)})
		niello.show(status_u, {text = app.status})
	}
}

declare_buttons :: proc(app: ^Form) {
	if niello.begin(buttons_row_u) {
		app.clear_i = controls.button("Clear")
		if niello.clicked(app.clear_i) {
			controls.text_box_set(&app.name, "")
			controls.text_box_set(&app.quest, "")
			app.status = "Cleared."
		}
		app.submit_i = controls.button("Submit", .Primary)
		if niello.clicked(app.submit_i) {
			name := controls.text_box_text(&app.name)
			if len(name) == 0 {
				app.status = "The name box is empty — Tab over and type something."
			} else {
				app.status = fmt.bprintf(
					app.status_buf[:],
					"Submitted — name: %s · quest: %s",
					name,
					controls.text_box_text(&app.quest),
				)
			}
		}
	}
}

main :: proc() {
	mint()
	ctx := niello.context_create()
	app := Form{status = "Tab into a box and type."}
	defer {
		controls.text_box_destroy(&app.name)
		controls.text_box_destroy(&app.quest)
		niello.shutdown()
	}
	niello_sdl.run(ctx, {title = "NielloUI — form", width = 680, height = 520}, declare, &app)
}
