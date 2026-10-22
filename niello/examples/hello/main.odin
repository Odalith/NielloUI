// niello/examples/hello — the smallest complete NielloUI app.
//
// Opens a real window via niello/sdl/app: units are minted once (cold) and
// declared every frame (hot). Only the public API is used.
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md):
//
//	odin run niello/examples/hello -extra-linker-flags:"-L..."
package main

import niello "../.."
import niello_sdl "../../sdl"

// Cold units, minted once. Each owns its style.
window:     niello.Unit
toolbar:    niello.Unit
title:      niello.Unit
card:       niello.Unit
card_label: niello.Unit

mint_units :: proc() {
	niello.mint(&window, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		color   = niello.Color{30, 32, 40, 255},
		padding = [4]u16{24, 24, 24, 24},
		gap     = 16,
	})
	niello.mint(&toolbar, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(48)},
		gap    = 12,
	})
	niello.mint(&title, niello.NO_UNIT, {
		font_size  = 28,
		font_color = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&card, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		size          = niello.Size{niello.grow(), niello.fixed(140)},
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 10,
		padding       = [4]u16{20, 20, 20, 20},
		gap           = 8,
	})
	niello.mint(&card_label, niello.NO_UNIT, {
		font_size  = 16,
		font_color = niello.Color{200, 200, 212, 255},
	})
}

// Hot: declare the UI every frame. The engine diffs and re-renders only
// what changed.
declare :: proc() {
	if _, ok := niello.begin(window); ok {
		if _, ok := niello.begin(toolbar); ok {
			niello.show(title, niello.key("title"), {text = "Hello, NielloUI"})
		}
		if _, ok := niello.begin(card); ok {
			niello.show(card_label, niello.key("body"), {
				text = "A real window, rendered by Skia through Dawn.",
			})
			niello.show(card_label, niello.key("hint"), {
				text = "Close the window to quit.",
			})
		}
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "Hello, NielloUI", width = 800, height = 600}, declare)
}
