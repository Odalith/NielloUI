// Drag demo (TODO #27, §3.28): the three named consumers of the
// drag query in one window —
//
//   - a slider: press seeks on the spot, drag scrubs (drag_pos on
//     the track does both; this is Nachtul's seek-bar shape);
//   - a splitter: drag_total applied to a size the app owns;
//   - a modal dialog dragged by its header: the popup sits at an
//     app-owned .At point the drag moves, and the close button
//     inside the header does NOT drag (the F4 subtraction:
//     dragging(header) && !dragging(close)).
package main

import "core:fmt"

import niello "../.."
import niello_sdl "../../sdl"

BG := niello.rgb(0x181a22)
PANEL := niello.rgb(0x2a2e3c)
PANEL2 := niello.rgb(0x383d50)
INK := niello.rgb(0xe8eaf0)
DIM := niello.rgb(0x969aa8)
ACCENT := niello.rgb(0x5478c8)

root_u, title_u, hint_u, caption_u, value_u: niello.Unit
track_u, fill_u: niello.Unit
split_row_u, left_pane_u, divider_u, divider_hov_u, right_pane_u, pane_text_u: niello.Unit
btn_u, btn_hov_u, btn_press_u, btn_label_u: niello.Unit
dlg_u, dlg_header_u, dlg_title_u, dlg_body_u: niello.Unit

slider_value: f32 = 0.35
slider_i: niello.Instance

split_w: f32 = 280
split_grab_w: f32
divider_i: niello.Instance

dlg_open: bool
dlg_pos := niello.Vec2{190, 120}
dlg_grab := niello.Vec2{}
header_i, close_i, dlg_i: niello.Instance

main :: proc() {
	mint()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "NielloUI — drag", width = 760, height = 540}, declare)
}

mint :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = BG, padding = niello.pad(20), gap = 10,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 20, font_color = INK})
	niello.mint(&hint_u, niello.NO_UNIT, {font_size = 13, font_color = DIM, wrap = .Word})
	niello.mint(&caption_u, niello.NO_UNIT, {font_size = 13.5, font_color = INK})
	niello.mint(&value_u, niello.NO_UNIT, {font_size = 13.5, font_color = ACCENT})

	niello.mint(&track_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.size(niello.grow(), niello.fixed(26)),
		color = PANEL, corner_radius = 6,
	})
	niello.mint(&fill_u, niello.NO_UNIT, {
		color = ACCENT, corner_radius = 6,
	})

	niello.mint(&split_row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.size(niello.grow(), niello.fixed(150)),
		gap = 0,
	})
	niello.mint(&left_pane_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		color = PANEL, corner_radius = 6,
		padding = niello.pad_xy(10, 8),
	})
	niello.mint(&right_pane_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.size(niello.grow(), niello.grow()),
		color = PANEL, corner_radius = 6,
		padding = niello.pad_xy(10, 8),
	})
	niello.mint(&divider_hov_u, niello.NO_UNIT, {color = ACCENT})
	niello.mint(&divider_u, niello.NO_UNIT, {
		size = niello.size(niello.fixed(10), niello.grow()),
		cursor = niello.Cursor_Kind.Resize_EW,
		hover = divider_hov_u,
	})
	niello.mint(&pane_text_u, niello.NO_UNIT, {font_size = 13, font_color = DIM})

	niello.mint(&btn_hov_u, niello.NO_UNIT, {color = PANEL2})
	niello.mint(&btn_press_u, niello.NO_UNIT, {color = niello.rgb(0x282b38)})
	niello.mint(&btn_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.size(niello.fit(), niello.fixed(34)),
		color = PANEL, corner_radius = 6,
		padding = niello.pad_xy(14, 0),
		align = niello.CENTER,
		hover = btn_hov_u, press = btn_press_u, focusable = true,
	})
	niello.mint(&btn_label_u, niello.NO_UNIT, {font_size = 13.5, font_color = INK})

	niello.mint(&dlg_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.size(niello.fixed(330), niello.fixed(190)),
		color = PANEL, corner_radius = 8,
		padding = niello.pad(0), gap = 0,
	})
	niello.mint(&dlg_header_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.size(niello.grow(), niello.fixed(40)),
		color = PANEL2, corner_radius = 8,
		padding = niello.pad_each(12, 0, 8, 0),
		align = niello.align(.Start, .Center),
		gap = 8,
	})
	niello.mint(&dlg_title_u, niello.NO_UNIT, {
		font_size = 14, font_color = INK,
		size = niello.size(niello.grow(), niello.fit()),
	})
	niello.mint(&dlg_body_u, niello.NO_UNIT, {
		font_size = 13, font_color = DIM,
		padding = niello.pad(12),
	})
}

button :: proc(text: string, loc := #caller_location) -> (i: niello.Instance) {
	if niello.begin(btn_u, out = &i, loc = loc) {
		niello.show(btn_label_u, {text = text})
	}
	return
}

declare :: proc() {
	if niello.begin(root_u) {
		niello.show(title_u, {text = "Drag"})
		niello.show(hint_u, {text = "Press the slider to seek, drag to scrub. Drag the divider. Open the dialog and drag it by its header — the X button still just closes."})

		// --- slider ---
		niello.show(caption_u, {text = "Slider"})
		// begin goes in the if condition: its end runs when the if
		// ends. As a plain statement it would run at the end of the
		// root block, silently reparenting everything below into the
		// track.
		if niello.begin(track_u, out = &slider_i) {
			niello.set(fill_u, .Size, niello.size(niello.percent(slider_value), niello.percent(1)))
			if niello.begin(fill_u) {}
		}
		// The pointer only: key activation presses too, and must not seek.
		if niello.pointer_pressed(slider_i) || niello.dragging(slider_i) {
			if r, rok := niello.rect(slider_i); rok && r.size.x > 0 {
				slider_value = clamp(niello.drag_pos(slider_i).x / r.size.x, 0, 1)
			}
		}
		niello.show(value_u, {text = fmt.tprintf("value %.0f%%", slider_value * 100)})

		// --- splitter ---
		niello.show(caption_u, {text = "Splitter"})
		if niello.begin(split_row_u) {
			niello.set(left_pane_u, .Size, niello.size(niello.fixed(split_w), niello.percent(1)))
			if niello.begin(left_pane_u) {
				niello.show(pane_text_u, {text = fmt.tprintf("left pane, %.0f DIP wide", split_w)})
			}
			// Same rule as the track: the divider's end must pop at
			// the end of this statement's scope, not the row's,
			// or the right pane becomes a child of the divider.
			if niello.begin(divider_u, out = &divider_i) {
			}
			if niello.begin(right_pane_u) {
				niello.show(pane_text_u, {text = "right pane (grow)"})
			}
		}
		if niello.drag_started(divider_i) {
			split_grab_w = split_w
		}
		if niello.dragging(divider_i) {
			split_w = clamp(split_grab_w + niello.drag_total().x, 80, 620)
		}

		// --- dialog ---
		open_i := button("Open dialog")
		if niello.clicked(open_i) {
			dlg_open = true
		}
		niello.show(hint_u, {text = fmt.tprintf("dialog at (%.0f, %.0f)", dlg_pos.x, dlg_pos.y)})
	}

	if dlg_open {
		if niello.begin_popup(dlg_u, 0, .At, opts = {at = dlg_pos, modal = true}, out = &dlg_i) {
			if niello.begin(dlg_header_u, out = &header_i) {
				niello.show(dlg_title_u, {text = "Drag me"})
				close_i = button("X")
			}
			niello.show(dlg_body_u, {text = "The header drags the dialog: its .At point is app state, moved by drag_total. Pressing X and dragging does not move it (the drag belongs to X)."})
		}
		// The F4 subtraction, live: the header's drag counts only
		// when the close button isn't the one being dragged.
		if niello.drag_started(header_i) && !niello.dragging(close_i) {
			dlg_grab = dlg_pos
		}
		if niello.dragging(header_i) && !niello.dragging(close_i) {
			dlg_pos = dlg_grab + niello.drag_total()
		}
		if niello.clicked(close_i) || niello.dismiss_requested(dlg_i) {
			dlg_open = false
		}
	}
}
