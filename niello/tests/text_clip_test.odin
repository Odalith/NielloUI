package tests

import "core:testing"
import niello ".."

// text_width, the clipboard and press_clicks: the core services the
// shipped TextBox builds on.

@(test)
test_text_width_measures_uncached :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	u, big: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {font_size = 14})
	niello.mint(&big, niello.NO_UNIT, {font_size = 28})
	testing.expect_value(t, niello.text_width(u, ""), f32(0))
	a := niello.text_width(u, "hello")
	b := niello.text_width(u, "hello world")
	testing.expect(t, a > 0 && b > a, "a longer string is wider")
	// Spaces count: the width of a prefix with a trailing space exceeds
	// the prefix without it (a caret after a space moves).
	testing.expect(t, niello.text_width(u, "hello ") > a, "a trailing space has width")
	testing.expect(t, niello.text_width(big, "hello") > a, "the unit's font size applies")
}

@(test)
test_clipboard_fallback_round_trips :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	// Headless: the glue's hooks are not installed in the test binary.
	testing.expect(t, niello.clipboard_get_hook == nil, "tests run without the glue hooks")
	testing.expect_value(t, niello.clipboard_text(), "")
	niello.set_clipboard_text("copied ✓")
	testing.expect_value(t, niello.clipboard_text(), "copied ✓")
	niello.set_clipboard_text("")
	testing.expect_value(t, niello.clipboard_text(), "")
	niello.set_clipboard_text("kept for teardown") // freed by the store
}

@(test)
test_press_clicks :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	r: niello.Unit
	niello.mint(&r, niello.NO_UNIT, {size = niello.size(niello.fixed(100), niello.fixed(100))})
	@(static) root: niello.Unit
	@(static) seen: int
	root = r
	declare :: proc() {
		seen = niello.press_clicks()
		if niello.begin(root) {}
	}
	frame :: proc(inp: niello.Input) {
		inp := inp
		inp.viewport = {200, 200}
		inp.mouse = {10, 10}
		inp.mouse_valid = true
		niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
		declare()
		niello.frame_end()
	}
	frame({})
	testing.expect_value(t, seen, 0)
	frame({buttons_pressed = {.Left}, buttons_down = {.Left}, clicks = 2})
	testing.expect_value(t, seen, 2)
	frame({buttons_released = {.Left}})
	testing.expect_value(t, seen, 0)
	// A host that reports no count counts as a single click.
	frame({buttons_pressed = {.Left}, buttons_down = {.Left}})
	testing.expect_value(t, seen, 1)
	// A right press is not a left click.
	frame({buttons_released = {.Left}})
	frame({buttons_pressed = {.Right}, buttons_down = {.Right}, clicks = 3})
	testing.expect_value(t, seen, 0)
}

@(test)
test_text_line_height_follows_size :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a, b: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {font_size = 14})
	niello.mint(&b, niello.NO_UNIT, {font_size = 28})
	testing.expect(t, niello.text_line_height(a) > 0, "a line has height")
	testing.expect(t, niello.text_line_height(b) > niello.text_line_height(a), "and it grows with the font size")
}

// The text cache frees what nothing uses: a font size swept through 100
// values (a glide, a slider) leaves only the sizes still shown.
@(test)
test_text_cache_evicts_unused :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	@(static) root, label: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(400), niello.fixed(300))})
	niello.mint(&label, niello.NO_UNIT, {font_size = 10})
	frame :: proc() {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
		if niello.begin(root) {
			niello.show(label, {text = "a label whose size keeps changing"})
		}
		niello.frame_end()
	}
	for k in 0 ..< 100 {
		niello.set(label, .Font_Size, f32(10 + k))
		frame()
	}
	peak := niello.test_text_cache_len()
	testing.expect(t, peak >= 50, "every size was measured")
	for _ in 0 ..< niello.TEST_TEXT_KEEP_FRAMES + 2 * niello.TEST_TEXT_SWEEP_EVERY {
		frame()
	}
	testing.expect(t, niello.test_text_cache_len() <= 2, "only the size still shown stays cached")
}
