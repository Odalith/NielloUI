// Headless tests for grow weights and the style shorthands.
package tests

import niello ".."
import "core:testing"

gw_row: niello.Unit
gw_kids: [3]niello.Unit
gw_kid_i: [3]niello.Instance
gw_count: int

gw_declare :: proc() {
	if niello.begin(gw_row) {
		for k in 0 ..< gw_count {
			gw_kid_i[k] = niello.show(gw_kids[k])
		}
	}
}

gw_layout :: proc(row_w: f32, sizes: []niello.Sizing) -> [3]f32 {
	niello.test_reset()
	niello.mint(&gw_row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = niello.size(niello.fixed(row_w), niello.fixed(20)),
	})
	for s, k in sizes {
		niello.mint(&gw_kids[k], niello.NO_UNIT, {size = niello.size(s, niello.fixed(20))})
	}
	gw_count = len(sizes)
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {1000, 100}}, 0.016)
	gw_declare()
	niello.frame_end()
	out: [3]f32
	for k in 0 ..< gw_count {
		r, _ := niello.rect(gw_kid_i[k])
		out[k] = r.size.x
	}
	niello.test_teardown()
	return out
}

@(test)
test_grow_weights_split_proportionally :: proc(t: ^testing.T) {
	w := gw_layout(300, {niello.grow(2), niello.grow()})
	testing.expectf(t, abs(w[0] - 200) < EPS && abs(w[1] - 100) < EPS, "grow(2) and grow() split 2:1 (got %v)", w)
	w = gw_layout(300, {niello.grow(), niello.grow(), niello.grow()})
	testing.expectf(t, abs(w[0] - 100) < EPS && abs(w[2] - 100) < EPS, "equal weights split evenly (got %v)", w)
	w = gw_layout(300, {niello.grow(0), niello.grow()})
	testing.expectf(t, abs(w[0]) < EPS && abs(w[1] - 300) < EPS, "grow(0) takes no share (got %v)", w)
}

@(test)
test_grow_weight_respects_max :: proc(t: ^testing.T) {
	// grow(2) would take 200 of 400, but stops at 100; the other two
	// share the remaining 300.
	w := gw_layout(400, {niello.grow(2, max = 100), niello.grow(), niello.grow()})
	testing.expectf(t, abs(w[0] - 100) < EPS && abs(w[1] - 150) < EPS && abs(w[2] - 150) < EPS,
		"a capped grower gives its excess to the others (got %v)", w)
}

@(test)
test_style_shorthands :: proc(t: ^testing.T) {
	testing.expect_value(t, niello.rgb(0x1e2028), niello.Color{0x1e, 0x20, 0x28, 255})
	testing.expect_value(t, niello.rgb(0x000000, 120), niello.Color{0, 0, 0, 120})
	testing.expect_value(t, niello.pad(8), [4]u16{8, 8, 8, 8})
	testing.expect_value(t, niello.pad_xy(12, 4), [4]u16{12, 4, 12, 4})
	testing.expect_value(t, niello.pad_each(1, 2, 3, 4), [4]u16{1, 2, 3, 4})
	testing.expect_value(t, niello.align(.Start, .End), [2]niello.Align_Kind{.Start, .End})
	testing.expect_value(t, niello.CENTER, [2]niello.Align_Kind{.Center, .Center})
	s := niello.size(niello.grow(), niello.fixed(40))
	testing.expect(t, s[0].kind == .Grow && s[1].kind == .Fixed && s[1].value == 40, "size pairs width and height")
}
