// The Getting started chapter's first window. Compile-checked in CI:
//	odin check docs/snippets/apps/hello -collection:niello=niello
package main

// ANCHOR: all
import niello "niello:."
import niello_sdl "niello:sdl"

// Units are minted once: each owns its style.
page, title: niello.Unit

// declare runs every frame and describes the whole UI.
declare :: proc() {
	if niello.begin(page) {
		niello.show(title, {text = "Hello, NielloUI"})
	}
}

main :: proc() {
	niello.mint(&page, niello.NO_UNIT, {
		layout = .Top_To_Bottom, padding = niello.pad(24),
		color = niello.rgb(0x1e2028),
	})
	niello.mint(&title, niello.NO_UNIT, {font_size = 24, font_color = niello.rgb(0xf0f0f5)})

	ctx := niello.context_create()
	defer niello.shutdown()
	niello_sdl.run(ctx, {title = "Hello", width = 640, height = 400}, declare)
}
// ANCHOR_END: all
