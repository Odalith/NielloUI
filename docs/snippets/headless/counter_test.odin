// Headless snippets: run by `odin test docs/snippets/headless
// -define:ODIN_TEST_THREADS=1 -collection:niello=niello`, so every
// documented example here is also a passing test. No window or native
// backend is needed.
package headless

import "core:testing"
import niello "niello:."
import counter "../counter"

// ANCHOR: test
@(test)
counter_counts_clicks :: proc(t: ^testing.T) {
	counter.mint()
	app: counter.App
	ctx := niello.context_create()
	defer {
		counter.destroy(&app)
		niello.shutdown()
	}
	// A frame: input in, declare, frame_end. Queries during declare see
	// the previous frame, so the first frame lays the button out.
	frame :: proc(ctx: ^niello.Context, app: ^counter.App, input: niello.Input) {
		input := input
		input.viewport = {480, 320}
		niello.frame_begin(ctx, input, 1.0 / 60.0)
		counter.declare(app)
		niello.frame_end()
	}
	frame(ctx, &app, {})

	// Click the button: press, then release, over its center.
	r, _ := niello.rect(app.count_i)
	at := r.pos + r.size / 2
	frame(ctx, &app, {mouse = at, mouse_valid = true, buttons_down = {.Left}, buttons_pressed = {.Left}})
	frame(ctx, &app, {mouse = at, mouse_valid = true, buttons_released = {.Left}})

	testing.expect_value(t, app.count, 1)
}
// ANCHOR_END: test
