// examples/hello — the smallest complete ui program.
//
// Mint units once (cold), declare them every frame (hot), read back rects.
// Only the public API (see public.odin) is used.
//
// Run from the repo root:
//
//	odin run examples/hello
package main

import niello "../.."
import "core:fmt"

main :: proc() {
	// ---- cold: mint units once; each owns its style ----
	window: niello.Unit
	niello.mint(&window, niello.NO_UNIT, {
		size   = niello.Size{niello.fixed(800), niello.fixed(600)},
		layout = .Top_To_Bottom,
	})
	toolbar: niello.Unit
	niello.mint(&toolbar, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(48)},
		gap    = 12,
	})
	title: niello.Unit
	niello.mint(&title, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})

	// ---- hot: three frames ----
	for frame in 0 ..< 3 {
		niello.frame_begin(niello.Input{viewport = {800, 600}}, 1.0 / 60.0)

		title_inst: niello.Instance
		if _, ok := niello.begin(window); ok {
			if _, ok := niello.begin(toolbar); ok {
				// Keyed: the same unit shown twice gets distinct identities.
				title_inst = niello.show(title, niello.key("title"), {text = "Hello, ui"})
				_ = niello.show(title, niello.key("subtitle"), {text = "frame demo"})
			}
		}

		// Mutate between frames; the engine finds the change next frame.
		if frame == 1 {
			niello.set(toolbar, .Gap, u16(24))
		}

		res := niello.frame_end()
		r, _ := niello.rect(title_inst)
		fmt.printf(
			"frame %d: changed=%v damage=%d title=(%.0f,%.0f %.0fx%.0f)\n",
			frame, res.changed, len(res.damage), r.pos.x, r.pos.y, r.size.x, r.size.y,
		)
	}
}
