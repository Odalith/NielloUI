// The Getting started chapter's counter window. Compile-checked in CI:
//	odin check docs/snippets/apps/counter -collection:niello=niello
package main

import niello "niello:."
import niello_sdl "niello:sdl"
import counter "../../counter"

// ANCHOR: main
main :: proc() {
	counter.mint()
	app: counter.App
	ctx := niello.context_create()
	defer {
		counter.destroy(&app)
		niello.shutdown()
	}
	// run's typed form hands &app to declare every frame.
	niello_sdl.run(ctx, {title = "Counter", width = 480, height = 320}, counter.declare, &app)
}
// ANCHOR_END: main
