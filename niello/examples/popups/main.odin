// popups — the popup layer (§3.19) end to end.
//
//   - File / Help buttons open dropdown menus (Help sits on the
//     bottom bar, so its menu flips above the anchor on its own).
//     Clicking the button again, clicking an item, pressing Esc, or
//     clicking anywhere else closes the menu — the engine only ever
//     *requests* dismissal; the bools below own the state.
//   - Clicking the canvas opens a context menu at the pointer,
//     placed with Placement.At (it reflects at the window corners).
//   - "Delete…" opens a modal dialog: presses outside it are
//     absorbed, Tab cycles inside it, focus returns to the Delete
//     button on close, and Esc cancels (via dismiss_requested).
package main

import "core:fmt"
import niello "../.."
import niello_sdl "../../sdl"

BG     :: niello.Color{32, 36, 44, 255}
BAR    :: niello.Color{43, 49, 61, 255}
PANEL  :: niello.Color{52, 59, 74, 255}
HOVER  :: niello.Color{66, 75, 94, 255}
PRESS  :: niello.Color{86, 98, 122, 255}
INK    :: niello.Color{232, 236, 242, 255}
DIM    :: niello.Color{150, 158, 172, 255}
ACCENT :: niello.Color{96, 165, 250, 255}
CANVAS :: niello.Color{38, 43, 53, 255}
SHADE  :: niello.Color{0, 0, 0, 120}

root_u, bar_u, status_u: niello.Unit
btn_u, btn_label_u, btn_hover_u, btn_press_u: niello.Unit
canvas_u: niello.Unit
menu_u, item_u, item_label_u, item_hover_u: niello.Unit
backdrop_u, panel_u, msg_u: niello.Unit

mint :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.size(niello.grow(), niello.grow()),
		color = BG, padding = niello.pad(16), gap = 12,
	})
	niello.mint(&bar_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.size(niello.grow(), niello.fixed(40)),
		gap = 8,
	})
	niello.mint(&btn_hover_u, niello.NO_UNIT, {color = HOVER})
	niello.mint(&btn_press_u, niello.NO_UNIT, {color = PRESS})
	// Focus shows through the engine's ring.
	niello.set_focus_ring({color = ACCENT, width = 2, offset = 2})
	niello.mint(&btn_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.size(niello.fixed(110), niello.fixed(40)),
		color = PANEL, corner_radius = 6,
		align = niello.CENTER,
		focusable = true,
		hover = btn_hover_u, press = btn_press_u,
	})
	niello.mint(&btn_label_u, niello.NO_UNIT, {font_size = 15, font_color = INK})
	niello.mint(&canvas_u, niello.NO_UNIT, {
		size = niello.size(niello.grow(), niello.grow()),
		color = CANVAS, corner_radius = 8,
	})
	niello.mint(&status_u, niello.NO_UNIT, {
		size = niello.size(niello.grow(), niello.fixed(24)),
		font_size = 14, font_color = DIM,
	})
	niello.mint(&item_hover_u, niello.NO_UNIT, {color = HOVER})
	niello.mint(&menu_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.size(niello.fixed(190), niello.fit()),
		color = PANEL, corner_radius = 8,
		border_width = 1, border_color = HOVER,
		padding = niello.pad(4), gap = 2,
	})
	niello.mint(&item_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.size(niello.grow(), niello.fixed(32)),
		corner_radius = 4, padding = niello.pad_xy(10, 0),
		align = niello.align(.Start, .Center),
		focusable = true,
		hover = item_hover_u,
	})
	niello.mint(&item_label_u, niello.NO_UNIT, {font_size = 15, font_color = INK})
	// The backdrop is a popup root of its own, sized by Percent so
	// it tracks the live viewport on resize (a Fixed root would
	// freeze it at the mint-time window size).
	niello.mint(&backdrop_u, niello.NO_UNIT, {
		size = niello.size(niello.percent(1), niello.percent(1)),
		color = SHADE,
	})
	niello.mint(&panel_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.size(niello.fixed(320), niello.fit()),
		color = PANEL, corner_radius = 10,
		padding = niello.pad(18), gap = 12,
	})
	niello.mint(&msg_u, niello.NO_UNIT, {font_size = 15, font_color = INK})
}

// ---- app state: the app owns openness; the engine owns geometry ----

file_btn_i, help_btn_i, del_btn_i, canvas_i: niello.Instance
file_menu_i, help_menu_i, ctx_menu_i, dlg_i: niello.Instance
file_open, help_open, ctx_open, dlg_open: bool
ctx_at: niello.Vec2

status_buf: [160]u8
status_len: int

set_status :: proc(format: string, args: ..any) {
	status_len = len(fmt.bprintf(status_buf[:], format, ..args))
}

// button is the demo's button component: a keyed container with a
// centered label. Returns the instance; ask niello.clicked on it.
button :: proc(text: string, loc := #caller_location) -> (i: niello.Instance) {
	if niello.begin(btn_u, out = &i, loc = loc) {
		niello.show(btn_label_u, {text = text})
	}
	return
}

main :: proc() {
	mint()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "NielloUI — popups", width = 680, height = 520}, declare)
}

declare :: proc() {
	// Dismissal bookkeeping first: the queries describe this frame's
	// dispatch against last frame's popups.
	if file_menu_i != 0 && niello.dismiss_requested(file_menu_i) {
		file_open = false
	}
	if help_menu_i != 0 && niello.dismiss_requested(help_menu_i) {
		help_open = false
	}
	if ctx_menu_i != 0 && niello.dismiss_requested(ctx_menu_i) {
		ctx_open = false
	}
	if dlg_i != 0 && niello.dismiss_requested(dlg_i) {
		dlg_open = false
		set_status("Delete cancelled.")
	}

	if niello.begin(root_u) {
		if niello.begin(bar_u) {
			file_btn_i = button("File")
			del_btn_i = button("Delete…")
		}
		canvas_i = niello.show(canvas_u)
		if niello.begin(bar_u) {
			help_btn_i = button("Help")
			niello.show(status_u, {
				text = string(status_buf[:status_len]),
			})
		}
	}

	// Main-tree interactions.
	if niello.clicked(file_btn_i) {
		file_open = !file_open
		help_open = false
		ctx_open = false
	}
	if niello.clicked(help_btn_i) {
		help_open = !help_open
		file_open = false
		ctx_open = false
	}
	if niello.clicked(del_btn_i) {
		dlg_open = true
		file_open = false
		help_open = false
		ctx_open = false
	}
	if niello.clicked(canvas_i) {
		if p, ok := niello.mouse_position(); ok {
			ctx_at = p
			ctx_open = true
			file_open = false
			help_open = false
		}
	}

	// Popups declare after the main tree (their roots live on the
	// layer regardless — order here is just readability).
	if file_open {
		items := []string{"New", "Open…", "Save", "Save As…"}
		if niello.begin_popup(menu_u, file_btn_i, .Below, opts = {gap = 4}, out = &file_menu_i) {
			for text, k in items {
				it: niello.Instance
				if niello.begin(item_u, out = &it) {
					niello.show(item_label_u, {text = text})
				}
				if niello.clicked(it) {
					set_status("File > %s", text)
					file_open = false
				}
			}
		}
	}
	if help_open {
		items := []string{"About", "Shortcuts"}
		if niello.begin_popup(menu_u, help_btn_i, .Below, opts = {gap = 4}, out = &help_menu_i) {
			for text, k in items {
				it: niello.Instance
				if niello.begin(item_u, out = &it) {
					niello.show(item_label_u, {text = text})
				}
				if niello.clicked(it) {
					set_status("Help > %s", text)
					help_open = false
				}
			}
		}
	}
	if ctx_open {
		items := []string{"Mark", "Flag", "Clear marks"}
		if niello.begin_popup(menu_u, 0, .At, opts = {at = ctx_at}, out = &ctx_menu_i) {
			for text, k in items {
				it: niello.Instance
				if niello.begin(item_u, out = &it) {
					niello.show(item_label_u, {text = text})
				}
				if niello.clicked(it) {
					set_status("Canvas: %s at (%d, %d)", text, int(ctx_at.x), int(ctx_at.y))
					ctx_open = false
				}
			}
		}
	}
	if dlg_open {
		// The backdrop declares first (below the dialog): a stay
		// popup that only shades. Presses on it land outside the
		// modal, so they absorb and light-dismiss the dialog —
		// backdrop click = cancel.
		niello.begin_popup(backdrop_u, 0, .At, opts = {stay = true, at = {0, 0}})
		if niello.begin_popup(panel_u, 0, .Center, opts = {modal = true}, out = &dlg_i) {
			niello.show(msg_u, {
				text = "Delete \"untitled.txt\"?",
			})
			if niello.begin(bar_u) {
				ok_i := button("Delete")
				cancel_i := button("Cancel")
				if niello.clicked(ok_i) {
					dlg_open = false
					set_status("Deleted (not really).")
				}
				if niello.clicked(cancel_i) {
					dlg_open = false
					set_status("Delete cancelled.")
				}
			}
		}
	}
}
