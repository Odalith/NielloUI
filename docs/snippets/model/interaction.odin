package model

import niello "niello:."

bar_u, tool_u, tool_on, status_u, split_u, pane_u, handle_u: niello.Unit

mint_interaction :: proc() {
	niello.mint(&bar_u, niello.NO_UNIT, {layout = .Top_To_Bottom, gap = 4, padding = niello.pad(8)})
	niello.mint(&tool_on, niello.NO_UNIT, {color = niello.rgb(SELECTED)})
	niello.mint(&tool_u, niello.NO_UNIT, {padding = niello.pad_xy(10, 4), focusable = true})
	niello.mint(&status_u, niello.NO_UNIT, {font_size = 12})
	niello.mint(&split_u, niello.NO_UNIT, {layout = .Left_To_Right, size = niello.size(niello.grow(), niello.grow())})
	niello.mint(&pane_u, niello.NO_UNIT, {size = niello.size(niello.grow(), niello.grow())})
	niello.mint(&handle_u, niello.NO_UNIT, {size = niello.size(niello.fixed(6), niello.grow()), cursor = .Resize_EW})
}

// ANCHOR: toolbar
Editor :: struct {
	bold:   bool,
	saves:  int,
	save_i: niello.Instance,
	bold_i: niello.Instance,
}

declare_toolbar :: proc(app: ^Editor) {
	if niello.begin(bar_u) {
		app.save_i = niello.show(tool_u, {text = "Save"})
		if niello.clicked(app.save_i) {
			app.saves += 1
		}

		app.bold_i = niello.show(tool_u, {text = "Bold", variant = tool_on if app.bold else niello.NO_UNIT})
		if niello.clicked(app.bold_i) {
			app.bold = !app.bold
		}

		status := "Ready"
		if niello.hovered(app.bold_i) {
			status = "Make the selection bold"
		}
		niello.show(status_u, {text = status})
	}
}
// ANCHOR_END: toolbar

// ANCHOR: splitter
Split :: struct {
	left_w: f32,
}

// declare_split shows two panes and a handle between them; dragging the
// handle moves the boundary.
declare_split :: proc(app: ^Split) {
	if niello.begin(split_u) {
		niello.show(pane_u, {size = niello.size(niello.fixed(app.left_w), niello.grow())})
		h := niello.show(handle_u)
		if niello.dragging(h) {
			app.left_w = max(80, app.left_w + niello.drag_delta().x)
		}
		niello.show(pane_u)
	}
}
// ANCHOR_END: splitter
