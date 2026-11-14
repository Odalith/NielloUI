// niello/examples/hello — the smallest complete NielloUI app.
//
// Opens a real window via niello/sdl/app: units are minted once (cold) and
// declared every frame (hot). Only the public API is used.
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md):
//
//	odin run niello/examples/hello
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
		color   = niello.rgb(0x1e2028),
		padding = niello.pad(24),
		gap     = 16,
	})
	niello.mint(&toolbar, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.size(niello.grow(), niello.fixed(48)),
		gap    = 12,
	})
	niello.mint(&title, niello.NO_UNIT, {
		font_size  = 28,
		font_color = niello.rgb(0xf0f0f5),
	})
	niello.mint(&card, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		size          = niello.size(niello.grow(), niello.fixed(140)),
		color         = niello.rgb(0x2e323e),
		corner_radius = 10,
		padding       = niello.pad(20),
		gap           = 8,
	})
	niello.mint(&card_label, niello.NO_UNIT, {
		font_size  = 16,
		font_color = niello.rgb(0xc8c8d4),
	})
}

// Hot: declare the UI every frame. The engine diffs and re-renders only
// what changed.
declare :: proc() {
	if niello.begin(window) {
		if niello.begin(toolbar) {
			niello.show(title, {text = "Hello, NielloUI"})
		}
		if niello.begin(card) {
			niello.show(card_label, {
				text = "A real window, rendered by Skia through Dawn.",
			})
			niello.show(card_label, {
				text = "Close the window to quit.",
			})
		}
	}
}

main :: proc() {
	mint_units()
	// Who the app is, for the desktop: on Wayland the id is what matches
	// the app to its .desktop file (taskbar icon, grouping).
	niello_sdl.set_app_settings({name = "Hello, NielloUI", id = "dev.niello.hello"})
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {
		title  = "Hello, NielloUI",
		width  = 800,
		height = 600,
		icon   = #load("icon.png"),
	}, declare)
}
