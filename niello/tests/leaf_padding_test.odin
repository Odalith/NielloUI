// Headless tests for leaf padding: a text or image leaf sizes to its
// content plus its padding, and paints the content inside it.
// Mock metrics: 8 px per byte at 16 px, lines 16 px tall.
package tests

import niello ".."
import "core:testing"

lp_root, lp_leaf: niello.Unit
lp_inst: niello.Instance
lp_text: string

lp_frame :: proc() {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0.016)
	if niello.begin(lp_root) {
		lp_inst = niello.show(lp_leaf, {text = lp_text})
	}
	niello.frame_end()
}

lp_setup :: proc(decl: niello.Style_Decl, text: string) {
	niello.test_reset()
	niello.mint(&lp_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(800), niello.fixed(600))})
	d := decl
	niello.mint(&lp_leaf, niello.NO_UNIT, d)
	lp_text = text
	lp_frame()
	lp_frame()
}

// lp_first_text returns the first Text command's bounds and its trim info.
lp_first_text :: proc() -> (niello.Rect, f32, bool, bool) {
	for cmd in niello.draw_list() {
		if cmd.tag == .Text {
			return cmd.bounds, cmd.max_width, cmd.truncated, true
		}
	}
	return {}, 0, false, false
}

@(test)
test_text_leaf_fit_includes_padding :: proc(t: ^testing.T) {
	lp_setup({padding = niello.pad_each(10, 4, 6, 2)}, "Button") // 48 x 16
	defer niello.test_teardown()
	r, _ := niello.rect(lp_inst)
	testing.expect_value(t, r.size, niello.Vec2{48 + 16, 16 + 6})
	b, _, _, ok := lp_first_text()
	testing.expect(t, ok, "the text is drawn")
	testing.expectf(t, abs(b.pos.x - (r.pos.x + 10)) < EPS && abs(b.pos.y - (r.pos.y + 4)) < EPS,
		"and inset by the left/top padding (text at %v, rect at %v)", b.pos, r.pos)
}

@(test)
test_text_leaf_wraps_inside_padding :: proc(t: ^testing.T) {
	// 100 wide with 10 px either side: an 80 px content box. "aaaa bbbb
	// cccc" is 32 + 8 + 32 + 8 + 32: two words fit per line.
	lp_setup({size = niello.size(niello.fixed(100), niello.fit()), padding = niello.pad(10), wrap = .Word}, "aaaa bbbb cccc")
	defer niello.test_teardown()
	r, _ := niello.rect(lp_inst)
	testing.expectf(t, abs(r.size.y - (2 * 16 + 20)) < EPS, "two lines plus the vertical padding (got %v)", r.size.y)
}

@(test)
test_text_leaf_trims_at_inner_width :: proc(t: ^testing.T) {
	// 100 wide, 10 px padding: the 80 px box trims a 160 px label.
	lp_setup({size = niello.size(niello.fixed(100), niello.fit()), padding = niello.pad(10)}, "aaaaaaaaaaaaaaaaaaaa")
	defer niello.test_teardown()
	_, max_w, truncated, ok := lp_first_text()
	testing.expect(t, ok && truncated, "the label is trimmed")
	testing.expectf(t, abs(max_w - 80) < EPS, "at the content box width (got %v)", max_w)
}
