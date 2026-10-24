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

BG := niello.Color{24, 26, 34, 255}
PANEL := niello.Color{42, 46, 60, 255}
PANEL2 := niello.Color{56, 61, 80, 255}
INK := niello.Color{232, 234, 240, 255}
DIM := niello.Color{150, 154, 168, 255}
ACCENT := niello.Color{84, 120, 200, 255}

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
		color = BG, padding = [4]u16{20, 20, 20, 20}, gap = 10,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 20, font_color = INK})
	niello.mint(&hint_u, niello.NO_UNIT, {font_size = 13, font_color = DIM, wrap = .Word})
	niello.mint(&caption_u, niello.NO_UNIT, {font_size = 13.5, font_color = INK})
	niello.mint(&value_u, niello.NO_UNIT, {font_size = 13.5, font_color = ACCENT})

	niello.mint(&track_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.grow(), niello.fixed(26)},
		color = PANEL, corner_radius = 6,
	})
	niello.mint(&fill_u, niello.NO_UNIT, {
		color = ACCENT, corner_radius = 6,
	})

	niello.mint(&split_row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(150)},
		gap = 0,
	})
	niello.mint(&left_pane_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		color = PANEL, corner_radius = 6,
		padding = [4]u16{10, 8, 10, 8},
	})
	niello.mint(&right_pane_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.grow(), niello.grow()},
		color = PANEL, corner_radius = 6,
		padding = [4]u16{10, 8, 10, 8},
	})
	niello.mint(&divider_hov_u, niello.NO_UNIT, {color = ACCENT})
	niello.mint(&divider_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(10), niello.grow()},
		cursor = niello.Cursor_Kind.Resize_EW,
		hover = divider_hov_u,
	})
	niello.mint(&pane_text_u, niello.NO_UNIT, {font_size = 13, font_color = DIM})

	niello.mint(&btn_hov_u, niello.NO_UNIT, {color = PANEL2})
	niello.mint(&btn_press_u, niello.NO_UNIT, {color = niello.Color{40, 43, 56, 255}})
	niello.mint(&btn_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.fit(), niello.fixed(34)},
		color = PANEL, corner_radius = 6,
		padding = [4]u16{14, 0, 14, 0},
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		hover = btn_hov_u, press = btn_press_u, focusable = true,
	})
	niello.mint(&btn_label_u, niello.NO_UNIT, {font_size = 13.5, font_color = INK})

	niello.mint(&dlg_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(330), niello.fixed(190)},
		color = PANEL, corner_radius = 8,
		padding = [4]u16{0, 0, 0, 0}, gap = 0,
	})
	niello.mint(&dlg_header_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(), niello.fixed(40)},
		color = PANEL2, corner_radius = 8,
		padding = [4]u16{12, 0, 8, 0},
		align = [2]niello.Align_Kind{niello.Align_Kind.Start, niello.Align_Kind.Center},
		gap = 8,
	})
	niello.mint(&dlg_title_u, niello.NO_UNIT, {
		font_size = 14, font_color = INK,
		size = niello.Size{niello.grow(), niello.fit()},
	})
	niello.mint(&dlg_body_u, niello.NO_UNIT, {
		font_size = 13, font_color = DIM,
		padding = [4]u16{12, 12, 12, 12},
	})
}

button :: proc(key: string, text: string) -> niello.Instance {
	i, open := niello.begin(btn_u, niello.key(key))
	if open {
		niello.show(btn_label_u, 0, {text = text})
	}
	return i
}

declare :: proc() {
	if _, ok := niello.begin(root_u); ok {
		niello.show(title_u, 0, {text = "Drag"})
		niello.show(hint_u, 0, {text = "Press the slider to seek, drag to scrub. Drag the divider. Open the dialog and drag it by its header — the X button still just closes."})

		// --- slider ---
		niello.show(caption_u, niello.key("cap1"), {text = "Slider"})
		// NOTE: begin goes in the if initializer — a plain-statement
		// begin defers its end to the end of the root block, which
		// silently reparents everything below into the track.
		if ti, tok := niello.begin(track_u, niello.key("slider")); tok {
			slider_i = ti
			niello.set(fill_u, .Size, niello.Size{niello.percent(slider_value), niello.percent(1)})
			if _, fok := niello.begin(fill_u, niello.key("fill")); fok {}
		}
		if niello.pressed(slider_i) || niello.dragging(slider_i) {
			if r, rok := niello.rect(slider_i); rok && r.size.x > 0 {
				slider_value = clamp(niello.drag_pos(slider_i).x / r.size.x, 0, 1)
			}
		}
		niello.show(value_u, niello.key("val1"), {text = fmt.tprintf("value %.0f%%", slider_value * 100)})

		// --- splitter ---
		niello.show(caption_u, niello.key("cap2"), {text = "Splitter"})
		if _, ok2 := niello.begin(split_row_u, niello.key("split")); ok2 {
			niello.set(left_pane_u, .Size, niello.Size{niello.fixed(split_w), niello.percent(1)})
			if _, okl := niello.begin(left_pane_u, niello.key("left")); okl {
				niello.show(pane_text_u, 0, {text = fmt.tprintf("left pane, %.0f DIP wide", split_w)})
			}
			// Same rule as the track: the divider's end must pop at
			// the end of this statement's scope, not the row's,
			// or the right pane becomes a child of the divider.
			if di, dok := niello.begin(divider_u, niello.key("divider")); dok {
				divider_i = di
			}
			if _, okr := niello.begin(right_pane_u, niello.key("right")); okr {
				niello.show(pane_text_u, 0, {text = "right pane (grow)"})
			}
		}
		if niello.drag_started(divider_i) {
			split_grab_w = split_w
		}
		if niello.dragging(divider_i) {
			split_w = clamp(split_grab_w + niello.drag_total().x, 80, 620)
		}

		// --- dialog ---
		open_i := button("open", "Open dialog")
		if niello.clicked(open_i) {
			dlg_open = true
		}
		niello.show(hint_u, niello.key("hint2"), {text = fmt.tprintf("dialog at (%.0f, %.0f)", dlg_pos.x, dlg_pos.y)})
	}

	if dlg_open {
		pi, open := niello.begin_popup(dlg_u, 0, .At, {at = dlg_pos, modal = true}, key = niello.key("dlg"))
		dlg_i = pi
		if open {
			if hi, hok := niello.begin(dlg_header_u, niello.key("hdr")); hok {
				header_i = hi
				niello.show(dlg_title_u, 0, {text = "Drag me"})
				close_i = button("close", "X")
			}
			niello.show(dlg_body_u, 0, {text = "The header drags the dialog: its .At point is app state, moved by drag_total. Pressing X and dragging does not move it (the drag belongs to X)."})
		}
		// The F4 subtraction, live: the header's drag counts only
		// when the close button isn't the one being dragged.
		if niello.drag_started(header_i) && !niello.dragging(close_i) {
			dlg_grab = dlg_pos
		}
		if niello.dragging(header_i) && !niello.dragging(close_i) {
			dlg_pos = dlg_grab + niello.drag_total()
		}
		if niello.clicked(close_i) || niello.dismiss_requested(pi) {
			dlg_open = false
		}
	}
}
