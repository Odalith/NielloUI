// debugger — TODO #18's host demo: a scene with real layout
// defects for the debugger window to find.
//
// Build it as a debug build (the define is the whole point):
//
//	odin run niello/examples/debugger -define:NIELLO_DEBUG=true -extra-linker-flags:"-L$PWD/third_party/native/linux-x64 -Wl,--start-group -lnui_render -lskia -ldawn_combined -lskcms -lwuffs -Wl,--end-group"
//
// Then press F12 in either window: the master debugger opens,
// targeted at that window. Hover tree rows (or overflow rows)
// and the node highlights in its own window; click a row for
// its rect / overflow / effective style; flip targets from the
// top bar; the "overflow tint" chip paints every overflowing
// node in the target at once.
//
// The scene's defects, deliberately: a 340px child in a 240px
// panel (child-extent overflow on the panel), a long line of
// text in a 120px label (intrinsic spill on the label), and a
// scroller whose 300px content is NOT a defect (scrollable axes
// are ranges, not overflows — it must not appear in the report).
// Closing the second window drops it from the debugger's
// target bar; closing every app window closes the debugger
// too, so the app can exit. The debugger never targets itself.
// Built without the define, install() is a no-op and the app
// has no debugger at all.
package main

import niello "../.."
import niello_sdl "../../sdl"
import debugui "../../debugui"

root_u, title_u, panel_u, wide_u, leaf_u, scroll_u, tall_u: niello.Unit
open_btn_u, open_btn_hover_u, open_btn_label_u: niello.Unit
win2_root_u, win2_box_u: niello.Unit

main_ctx: ^niello.Context
win2_open: bool

declare_main :: proc() {
	if _, open := niello.begin(root_u); open {
		niello.show(title_u, 0, {text = "Debugger host — press F12"})
		if _, open2 := niello.begin(panel_u); open2 {
			niello.show(wide_u)
			niello.show(leaf_u)
		}
		if _, open3 := niello.begin(scroll_u); open3 {
			niello.show(tall_u)
		}
		btn: niello.Instance
		if b, open4 := niello.begin(open_btn_u); open4 {
			btn = b
			niello.show(open_btn_label_u)
		}
		if niello.clicked(btn) && !win2_open {
			win2_open = true
			ctx2 := niello.context_create()
			niello_sdl.open_window(ctx2, {title = "Second window", width = 320, height = 240}, declare_win2)
		}
	}
}

declare_win2 :: proc() {
	if _, open := niello.begin(win2_root_u); open {
		niello.show(win2_box_u)
		niello.show(title_u, 0, {text = "F12 works here too"})
	}
}

mint_units :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.percent(1), niello.percent(1)},
		color = niello.Color{26, 26, 34, 255},
		padding = [4]u16{16, 16, 16, 16}, gap = 12,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 15, font_color = niello.Color{228, 228, 236, 255}})
	niello.mint(&panel_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.fixed(240), niello.fixed(110)},
		color = niello.Color{38, 38, 52, 255}, corner_radius = 8,
		padding = [4]u16{10, 10, 10, 10}, gap = 8,
	})
	niello.mint(&wide_u, niello.NO_UNIT, {size = niello.Size{niello.fixed(340), niello.fixed(36)}, color = niello.Color{196, 90, 70, 255}, corner_radius = 6})
	niello.mint(&leaf_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(120), niello.fixed(24)},
		text = "a label far too wide for its box",
		font_size = 14, font_color = niello.Color{230, 226, 210, 255},
	})
	niello.mint(&scroll_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(240), niello.fixed(90)},
		scroll = niello.Scroll.Vertical,
		color = niello.Color{38, 44, 40, 255}, corner_radius = 8,
	})
	niello.mint(&tall_u, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(300)}, color = niello.Color{80, 140, 100, 255}, corner_radius = 6})
	niello.mint(&open_btn_hover_u, niello.NO_UNIT, {color = niello.Color{64, 84, 130, 255}})
	niello.mint(&open_btn_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(170), niello.fixed(36)},
		color = niello.Color{48, 62, 100, 255}, corner_radius = 6,
		align = [2]niello.Align_Kind{.Center, .Center},
		hover = open_btn_hover_u,
	})
	niello.mint(&open_btn_label_u, niello.NO_UNIT, {text = "Open second window", font_size = 14, font_color = niello.Color{235, 238, 245, 255}})
	niello.mint(&win2_root_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.percent(1), niello.percent(1)},
		color = niello.Color{30, 34, 30, 255},
		padding = [4]u16{14, 14, 14, 14}, gap = 10,
	})
	niello.mint(&win2_box_u, niello.NO_UNIT, {size = niello.Size{niello.fixed(90), niello.fixed(60)}, color = niello.Color{90, 120, 190, 255}, corner_radius = 8})
}

main :: proc() {
	mint_units()
	debugui.install() // a no-op unless built with NIELLO_DEBUG
	main_ctx = niello.context_create()
	defer niello.context_destroy(main_ctx)
	niello_sdl.run(main_ctx, {title = "Debugger host — NielloUI", width = 480, height = 420}, declare_main)
}
