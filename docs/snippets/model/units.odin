// The model chapter's examples. Each page includes its procs by anchor, and
// the tests in docs/snippets/headless run them and check what the page
// says they do.
package model

import niello "niello:."

INK :: 0x1e2028
BLUE :: 0x0b57d0

// ANCHOR: mint
body, title, card: niello.Unit

mint_text :: proc() {
	niello.mint(&body, niello.NO_UNIT, {font_size = 14, font_color = niello.rgb(INK)})
	// A variant: a copy of body's style, with its own changes on top.
	niello.mint(&title, body, {font_size = 22, font_weight = .Bold})
	niello.mint(&card, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		padding       = niello.pad(16),
		gap           = 8,
		color         = niello.rgb(0xffffff),
		corner_radius = 8,
	})
}
// ANCHOR_END: mint

// ANCHOR: set
emphasize :: proc() {
	niello.set(body, .Font_Color, niello.rgb(BLUE)) // one field
	niello.set_many(card, {padding = niello.pad(24), corner_radius = 12}) // several
}
// ANCHOR_END: set

// ANCHOR: propagate
// follow_body pushes body's text color to the units minted from it. A unit
// that set the field itself keeps its own value.
follow_body :: proc() {
	niello.propagate(body, {.Font_Color})
}
// ANCHOR_END: propagate

// ANCHOR: overlays
button, button_hover, button_press: niello.Unit

mint_button :: proc() {
	// Overlays name only what changes; the rest comes from the button.
	niello.mint(&button_hover, niello.NO_UNIT, {color = niello.rgb(0xe8eaed)})
	niello.mint(&button_press, niello.NO_UNIT, {color = niello.rgb(0xd2d5da)})
	niello.mint(&button, niello.NO_UNIT, {
		color         = niello.rgb(0xf1f3f4),
		padding       = niello.pad_xy(12, 6),
		corner_radius = 6,
		hover         = button_hover,
		press         = button_press,
		focusable     = true,
	})
}
// ANCHOR_END: overlays
