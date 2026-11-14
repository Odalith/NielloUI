package model

import niello "niello:."

panel_u, heading_u, row_u, tag_u: niello.Unit

mint_declaring :: proc() {
	niello.mint(&panel_u, niello.NO_UNIT, {layout = .Top_To_Bottom, padding = niello.pad(12), gap = 4})
	niello.mint(&heading_u, niello.NO_UNIT, {font_size = 18})
	niello.mint(&row_u, niello.NO_UNIT, {padding = niello.pad_xy(8, 4)})
	niello.mint(&tag_u, niello.NO_UNIT, {padding = niello.pad_xy(6, 2), corner_radius = 4})
}

// ANCHOR: declare
declare_panel :: proc() {
	if niello.begin(panel_u) {
		niello.show(heading_u, {text = "Today"})
		niello.show(row_u, {text = "Write the docs"})
		niello.show(row_u, {text = "Review the PR"})
	} // the panel closes here
}
// ANCHOR_END: declare

// ANCHOR: settings
Settings :: struct {
	advanced: bool,
	save_i:   niello.Instance,
}

declare_settings :: proc(app: ^Settings) {
	if niello.begin(panel_u) {
		if app.advanced {
			niello.show(row_u, {text = "Advanced options"})
		}
		app.save_i = niello.show(row_u, {text = "Save"})
	}
}
// ANCHOR_END: settings

// ANCHOR: keys
Item :: struct {
	id:   int,
	name: string,
	row:  niello.Instance, // its row, kept for queries
}

declare_items :: proc(items: []Item) {
	if niello.begin(panel_u) {
		for &item in items {
			item.row = niello.show(row_u, {text = item.name}, niello.key_int(item.id))
		}
	}
}
// ANCHOR_END: keys

// declare_items_by_position is declare_items without keys: each row is
// named by its place in the loop. Used by the tests, not shown.
declare_items_by_position :: proc(items: []Item) {
	if niello.begin(panel_u) {
		for &item in items {
			item.row = niello.show(row_u, {text = item.name})
		}
	}
}

// ANCHOR: component
// tag declares a small label. It forwards its caller's location, so every
// place that calls tag is a call site of its own.
tag :: proc(text: string, loc := #caller_location) -> niello.Instance {
	return niello.show(tag_u, {text = text}, loc = loc)
}
// ANCHOR_END: component

// ANCHOR: out
Inbox :: struct {
	list_i: niello.Instance,
}

declare_inbox :: proc(app: ^Inbox) {
	if niello.begin(panel_u, out = &app.list_i) {
		tag("unread")
		tag("flagged")
	}
	if niello.clicked(app.list_i) {
		// the panel's instance, usable after its block too
	}
}
// ANCHOR_END: out
