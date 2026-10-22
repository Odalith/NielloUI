// niello/examples/scroll — the scrolling demo: wheel consumption,
// chaining, and programmatic scrolls.
//
// A scrollable list of rows with a second, smaller scroller embedded in
// it. The wheel goes to the deepest scrollable container under the
// cursor first: over the embedded panel, the panel scrolls until it
// reaches its end, and only the leftover chains up to the list (its
// scroll_chain is on, the default). Offsets are engine state keyed by
// identity — the app reads them with scroll_offset and writes them with
// scroll_to (the Back to top button), never per-frame bookkeeping.
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md):
//
//	odin run niello/examples/scroll -extra-linker-flags:"-L..."
package main

import "core:fmt"
import niello "../.."
import niello_sdl "../../sdl"

// Cold units.
window_u:  niello.Unit
title_u:   niello.Unit
hint_u:    niello.Unit
label_u:   niello.Unit
list_u:    niello.Unit
row_a_u:   niello.Unit // alternating row shades
row_b_u:   niello.Unit
panel_u:   niello.Unit
mini_u:    niello.Unit
bar_u:     niello.Unit
top_btn_u: niello.Unit
status_u:  niello.Unit
ov_hover_u: niello.Unit
ov_press_u: niello.Unit

list_i, panel_i, top_i: niello.Instance

mint_units :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		color   = niello.Color{30, 32, 40, 255},
		padding = [4]u16{24, 24, 24, 24},
		gap     = 14,
	})
	niello.mint(&title_u, niello.NO_UNIT, {
		font_size  = 26,
		font_color = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&hint_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.Color{150, 154, 168, 255},
	})
	niello.mint(&label_u, niello.NO_UNIT, {
		font_size  = 15,
		font_color = niello.Color{230, 232, 238, 255},
	})

	niello.mint(&list_u, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		size          = niello.Size{niello.grow(), niello.grow()},
		color         = niello.Color{38, 41, 52, 255},
		corner_radius = 10,
		padding       = [4]u16{10, 10, 10, 10},
		gap           = 8,
		scroll        = niello.Scroll.Vertical,
	})
	row := niello.Style_Decl{
		layout        = .Left_To_Right,
		size          = niello.Size{niello.grow(), niello.fixed(36)},
		corner_radius = 6,
		padding       = [4]u16{12, 0, 12, 0},
		align         = [2]niello.Align_Kind{.Start, .Center},
	}
	row_a := row
	row_a.color = niello.Color{52, 56, 70, 255}
	niello.mint(&row_a_u, niello.NO_UNIT, row_a)
	row_b := row
	row_b.color = niello.Color{46, 50, 63, 255}
	niello.mint(&row_b_u, niello.NO_UNIT, row_b)

	// The embedded scroller: a warm panel so it reads as a separate
	// region. Its own content is 6 x 26 = 156 in a 108 viewport.
	niello.mint(&panel_u, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		size          = niello.Size{niello.grow(), niello.fixed(108)},
		color         = niello.Color{84, 62, 44, 255},
		corner_radius = 6,
		padding       = [4]u16{8, 8, 8, 8},
		gap           = 4,
		scroll        = niello.Scroll.Vertical,
	})
	niello.mint(&mini_u, niello.NO_UNIT, {
		size      = niello.Size{niello.grow(), niello.fixed(26)},
		font_size = 13,
		font_color = niello.Color{245, 238, 228, 255},
	})

	niello.mint(&bar_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(44)},
		gap    = 12,
	})
	niello.mint(&ov_hover_u, niello.NO_UNIT, {color = niello.Color{64, 70, 90, 255}})
	niello.mint(&ov_press_u, niello.NO_UNIT, {color = niello.Color{92, 102, 130, 255}})
	niello.mint(&top_btn_u, niello.NO_UNIT, {
		layout        = .Left_To_Right,
		size          = niello.Size{niello.fixed(150), niello.fixed(44)},
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 10,
		align         = [2]niello.Align_Kind{.Center, .Center},
		cursor        = niello.Cursor_Kind.Pointer,
		hover         = ov_hover_u,
		press         = ov_press_u,
	})
	niello.mint(&status_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.Color{170, 174, 188, 255},
	})
}

declare_row :: proc(n: int) {
	u := row_a_u if n % 2 == 0 else row_b_u
	if _, ok := niello.begin(u, niello.key_int(n)); ok {
		niello.show(label_u, 0, {text = fmt.tprintf("Row %d", n + 1)})
	}
}

declare :: proc() {
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u, niello.key("title"), {text = "Scroll — wheel, chaining, scroll_to"})
		niello.show(hint_u, niello.key("hint"), {
			text = "Wheel over the list scrolls it. Wheel over the warm panel: the panel scrolls first, the leftover chains to the list.",
		})

		if li, ok := niello.begin(list_u); ok {
			list_i = li
			for n in 0 ..< 8 {
				declare_row(n)
			}
			// The embedded scroller sits in the list's flow; it is a
			// child of the list, so chaining has somewhere to go.
			if pi, ok2 := niello.begin(panel_u, niello.key("panel")); ok2 {
				panel_i = pi
				for k in 0 ..< 6 {
					niello.show(mini_u, niello.key_int(k), {
						text = fmt.tprintf("Panel item %d — the panel's own scroll region", k + 1),
					})
				}
			}
			for n in 8 ..< 20 {
				declare_row(n)
			}
		}

		if _, ok := niello.begin(bar_u); ok {
			if bi, ok2 := niello.begin(top_btn_u); ok2 {
				top_i = bi
				if niello.clicked(bi) {
					niello.scroll_to(list_i, {0, 0})
					niello.scroll_to(panel_i, {0, 0})
				}
				niello.show(label_u, niello.key("top"), {text = "Back to top"})
			}
			niello.show(status_u, niello.key("status"), {
				text = fmt.tprintf("List offset %.0f · panel offset %.0f",
					niello.scroll_offset(list_i).y, niello.scroll_offset(panel_i).y),
			})
		}
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "Scroll — NielloUI", width = 720, height = 560}, declare)
}
