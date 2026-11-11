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
//	odin run niello/examples/scroll
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
		color   = niello.rgb(0x1e2028),
		padding = niello.pad(24),
		gap     = 14,
	})
	niello.mint(&title_u, niello.NO_UNIT, {
		font_size  = 26,
		font_color = niello.rgb(0xf0f0f5),
	})
	niello.mint(&hint_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.rgb(0x969aa8),
	})
	niello.mint(&label_u, niello.NO_UNIT, {
		font_size  = 15,
		font_color = niello.rgb(0xe6e8ee),
	})

	niello.mint(&list_u, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		size          = niello.size(niello.grow(), niello.grow()),
		color         = niello.rgb(0x262934),
		corner_radius = 10,
		padding       = niello.pad(10),
		gap           = 8,
		scroll        = niello.Scroll.Vertical,
	})
	row := niello.Style_Decl{
		layout        = .Left_To_Right,
		size          = niello.size(niello.grow(), niello.fixed(36)),
		corner_radius = 6,
		padding       = niello.pad_xy(12, 0),
		align         = niello.align(.Start, .Center),
	}
	row_a := row
	row_a.color = niello.rgb(0x343846)
	niello.mint(&row_a_u, niello.NO_UNIT, row_a)
	row_b := row
	row_b.color = niello.rgb(0x2e323f)
	niello.mint(&row_b_u, niello.NO_UNIT, row_b)

	// The embedded scroller: a warm panel so it reads as a separate
	// region. Its own content is 6 x 26 = 156 in a 108 viewport.
	niello.mint(&panel_u, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		size          = niello.size(niello.grow(), niello.fixed(108)),
		color         = niello.rgb(0x543e2c),
		corner_radius = 6,
		padding       = niello.pad(8),
		gap           = 4,
		scroll        = niello.Scroll.Vertical,
	})
	niello.mint(&mini_u, niello.NO_UNIT, {
		size      = niello.size(niello.grow(), niello.fixed(26)),
		font_size = 13,
		font_color = niello.rgb(0xf5eee4),
	})

	niello.mint(&bar_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.size(niello.grow(), niello.fixed(44)),
		gap    = 12,
	})
	niello.mint(&ov_hover_u, niello.NO_UNIT, {color = niello.rgb(0x40465a)})
	niello.mint(&ov_press_u, niello.NO_UNIT, {color = niello.rgb(0x5c6682)})
	niello.mint(&top_btn_u, niello.NO_UNIT, {
		layout        = .Left_To_Right,
		size          = niello.size(niello.fixed(150), niello.fixed(44)),
		color         = niello.rgb(0x2e323e),
		corner_radius = 10,
		align         = niello.CENTER,
		cursor        = niello.Cursor_Kind.Pointer,
		hover         = ov_hover_u,
		press         = ov_press_u,
	})
	niello.mint(&status_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.rgb(0xaaaebc),
	})
}

declare_row :: proc(n: int) {
	u := row_a_u if n % 2 == 0 else row_b_u
	if niello.begin(u) {
		niello.show(label_u, {text = fmt.tprintf("Row %d", n + 1)})
	}
}

declare :: proc() {
	if niello.begin(window_u) {
		niello.show(title_u, {text = "Scroll — wheel, chaining, scroll_to"})
		niello.show(hint_u, {
			text = "Wheel over the list scrolls it. Wheel over the warm panel: the panel scrolls first, the leftover chains to the list.",
		})

		if niello.begin(list_u, out = &list_i) {
			for n in 0 ..< 8 {
				declare_row(n)
			}
			// The embedded scroller sits in the list's flow; it is a
			// child of the list, so chaining has somewhere to go.
			if niello.begin(panel_u, out = &panel_i) {
				for k in 0 ..< 6 {
					niello.show(mini_u, {
						text = fmt.tprintf("Panel item %d — the panel's own scroll region", k + 1),
					})
				}
			}
			for n in 8 ..< 20 {
				declare_row(n)
			}
		}

		if niello.begin(bar_u) {
			if niello.begin(top_btn_u, out = &top_i) {
				if niello.clicked(top_i) {
					niello.scroll_to(list_i, {0, 0})
					niello.scroll_to(panel_i, {0, 0})
				}
				niello.show(label_u, {text = "Back to top"})
			}
			niello.show(status_u, {
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
