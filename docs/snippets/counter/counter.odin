// The Getting started chapter's counter: the app's UI, kept apart from
// main so the window program (apps/counter) and a headless test
// (headless/counter_test.odin) run the same code.
package counter

import "core:fmt"
import niello "niello:."
import controls "niello:controls"

// ANCHOR: state
// App is everything the UI shows and edits. It is plain data the app owns.
App :: struct {
	count:   int,
	name:    controls.Text_Box,
	count_i: niello.Instance, // the button, kept so a test can click it
}
// ANCHOR_END: state

page: niello.Unit

// ANCHOR: mint
// mint creates the units, once, before the first frame. The page joins the
// theme's bg role, so controls.apply_theme recolors it with the controls.
mint :: proc() {
	controls.init()
	niello.mint(&page, niello.NO_UNIT, {
		layout = .Top_To_Bottom, padding = niello.pad(24), gap = 12,
		color = controls.theme.bg,
		group_masks = []niello.Group_Mask{controls.as(controls.groups.bg, .Color)},
	})
}
// ANCHOR_END: mint

// ANCHOR: declare
// declare describes the UI from app's state, every frame. Interaction is
// polled where it is declared: no callbacks.
declare :: proc(app: ^App) {
	if niello.begin(page) {
		controls.text_box(&app.name, "Your name")
		app.count_i = controls.button("Count", .Primary)
		if niello.clicked(app.count_i) {
			app.count += 1
		}
		who := controls.text_box_text(&app.name)
		if who == "" {
			who = "nobody"
		}
		niello.show(controls.parts.label.text, {text = fmt.tprintf("%s clicked %d times", who, app.count)})
	}
}
// ANCHOR_END: declare

destroy :: proc(app: ^App) {
	controls.text_box_destroy(&app.name)
}
