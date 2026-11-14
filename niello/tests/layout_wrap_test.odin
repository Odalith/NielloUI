// Layout.Wrap: rows that wrap, with alignment per line, line_gap between
// lines, growing per line, and the container's own sizing.
package tests

import niello ".."
import "core:testing"

wr_root, wr_box: niello.Unit
wr_kids: [dynamic]niello.Unit
wr_withs: [dynamic]niello.With
wr_inst: [32]niello.Instance
wr_box_i: niello.Instance

wr_declare :: proc() {
	if niello.begin(wr_root) {
		if niello.begin(wr_box, out = &wr_box_i) {
			for u, k in wr_kids {
				w := k < len(wr_withs) ? wr_withs[k] : niello.With{}
				wr_inst[k] = niello.show(u, w, niello.key_int(k + 1))
			}
		}
	}
}

wr_frame :: proc(t: ^testing.T, loc := #caller_location) {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
	wr_declare()
	res := niello.frame_end()
	bad := niello.test_repaint_check(res)
	testing.expectf(t, bad == 0, "partial repaint differs in %d cells", bad, loc = loc)
}

// wr_setup mints the root (a column, or a row with row = true), the wrap
// box from decl, and resets the children.
wr_setup :: proc(box: niello.Style_Decl, row := false) {
	niello.test_reset()
	clear(&wr_kids)
	clear(&wr_withs)
	niello.mint(&wr_root, niello.NO_UNIT, {
		layout = row ? niello.Layout.Left_To_Right : niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(400), niello.fixed(300)},
	})
	d := box
	d.layout = niello.Layout.Wrap
	niello.mint(&wr_box, niello.NO_UNIT, d)
}

wr_teardown :: proc() {
	delete(wr_kids)
	delete(wr_withs)
	wr_kids, wr_withs = nil, nil
	niello.test_teardown()
}

wr_kid :: proc(w, h: niello.Sizing) -> niello.Unit {
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {size = niello.Size{w, h}, color = niello.Color{90, 90, 90, 255}})
	append(&wr_kids, u)
	return u
}

wr_rect :: proc(k: int) -> niello.Rect {
	r, _ := niello.rect(wr_inst[k])
	return r
}

@(test)
test_wrap_breaks_into_lines :: proc(t: ^testing.T) {
	wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}, gap = 10, line_gap = 6})
	defer wr_teardown()
	for k in 0 ..< 5 {
		wr_kid(niello.fixed(60), niello.fixed(k == 1 ? 30 : 20))
	}
	wr_frame(t)
	wr_frame(t)
	// 60+10+60+10+60 = 200: three per line
	testing.expect_value(t, wr_rect(0).pos, niello.Vec2{0, 0})
	testing.expect_value(t, wr_rect(1).pos, niello.Vec2{70, 0})
	testing.expect_value(t, wr_rect(2).pos, niello.Vec2{140, 0})
	// the first line is as tall as its tallest child (30), then line_gap 6
	testing.expect_value(t, wr_rect(3).pos, niello.Vec2{0, 36})
	testing.expect_value(t, wr_rect(4).pos, niello.Vec2{70, 36})
	box, _ := niello.rect(wr_box_i)
	testing.expect_value(t, box.size, niello.Vec2{200, 56}) // Fit height: 30 + 6 + 20
}

@(test)
test_wrap_align_x_per_line :: proc(t: ^testing.T) {
	for a in ([]niello.Align_Kind{.Center, .End}) {
		wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}, gap = 10, align = [2]niello.Align_Kind{a, .Start}})
		for _ in 0 ..< 5 {
			wr_kid(niello.fixed(60), niello.fixed(20))
		}
		wr_frame(t)
		wr_frame(t)
		// the full first line has no room to move; the second (130 wide)
		// is placed in its own leftover 70
		testing.expect_value(t, wr_rect(0).pos.x, 0)
		want := a == .Center ? f32(35) : f32(70)
		testing.expect_value(t, wr_rect(3).pos.x, want)
		testing.expect_value(t, wr_rect(4).pos.x, want + 70)
		wr_teardown()
	}
}

@(test)
test_wrap_align_y_block_and_within_line :: proc(t: ^testing.T) {
	for a in ([]niello.Align_Kind{.Center, .End}) {
		wr_setup({size = niello.Size{niello.fixed(200), niello.fixed(100)}, gap = 10, line_gap = 6, align = [2]niello.Align_Kind{.Start, a}})
		for k in 0 ..< 5 {
			wr_kid(niello.fixed(60), niello.fixed(k == 1 ? 30 : 20))
		}
		wr_frame(t)
		wr_frame(t)
		// lines take 56 of 100: the block moves by 22 (Center) or 44 (End)
		block := a == .Center ? f32(22) : f32(44)
		within := a == .Center ? f32(5) : f32(10) // a 20-tall child in a 30-tall line
		testing.expect_value(t, wr_rect(1).pos.y, block)
		testing.expect_value(t, wr_rect(0).pos.y, block + within)
		testing.expect_value(t, wr_rect(3).pos.y, block + 36)
		wr_teardown()
	}
}

@(test)
test_wrap_fit_width_in_a_column :: proc(t: ^testing.T) {
	wr_setup({gap = 10, line_gap = 4}) // Fit both ways, in a 400-wide column
	defer wr_teardown()
	for _ in 0 ..< 8 {
		wr_kid(niello.fixed(60), niello.fixed(20))
	}
	wr_frame(t)
	box, _ := niello.rect(wr_box_i)
	// one line would be 550: clamped to the column's 400, five per line
	testing.expect_value(t, box.size, niello.Vec2{400, 44})
	testing.expect_value(t, wr_rect(5).pos, niello.Vec2{0, 24})
}

@(test)
test_wrap_shrinks_to_its_widest_child :: proc(t: ^testing.T) {
	wr_setup({gap = 10}, row = true) // Fit width, in a 400-wide row
	defer wr_teardown()
	for _ in 0 ..< 8 {
		wr_kid(niello.fixed(60), niello.fixed(20))
	}
	// a 300-wide sibling leaves the box 100 of its 550
	side: niello.Unit
	niello.mint(&side, niello.NO_UNIT, {size = niello.Size{niello.fixed(300), niello.fixed(20)}})
	frame :: proc(side: niello.Unit) {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
		if niello.begin(wr_root) {
			niello.show(side)
			if niello.begin(wr_box, out = &wr_box_i) {
				for u, k in wr_kids {
					wr_inst[k] = niello.show(u, key = niello.key_int(k + 1))
				}
			}
		}
		niello.frame_end()
	}
	frame(side)
	box, _ := niello.rect(wr_box_i)
	testing.expect_value(t, box.size.x, 100) // a row would have kept 550
	testing.expect_value(t, wr_rect(1).pos.y, wr_rect(0).pos.y + 20) // one per line
}

@(test)
test_wrap_grow_per_line :: proc(t: ^testing.T) {
	wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}, gap = 10})
	defer wr_teardown()
	wr_kid(niello.fixed(60), niello.fixed(20))       // 0
	wr_kid(niello.grow(min = 40), niello.fixed(20))  // 1
	wr_kid(niello.fixed(60), niello.fixed(20))       // 2: line 1 is 180, 20 left
	wr_kid(niello.fixed(120), niello.fixed(30))      // 3: starts line 2
	wr_kid(niello.grow(min = 40), niello.grow())     // 4: line 2 is 170, 30 left
	wr_frame(t)
	testing.expect_value(t, wr_rect(1).size.x, 60) // 40 + line 1's 20
	testing.expect_value(t, wr_rect(2).pos.x, 140)
	testing.expect_value(t, wr_rect(4).size.x, 70) // 40 + line 2's 30
	testing.expect_value(t, wr_rect(4).size.y, 30) // Grow height: the line's height
}

@(test)
test_wrap_oversized_children :: proc(t: ^testing.T) {
	wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}, gap = 10})
	defer wr_teardown()
	wr_kid(niello.fixed(60), niello.fixed(20))
	wr_kid(niello.fixed(300), niello.fixed(20)) // wider than a line: its own line
	wr_kid(niello.fixed(60), niello.fixed(20))
	text: niello.Unit
	niello.mint(&text, niello.NO_UNIT, {font_size = 16})
	append(&wr_kids, text)
	resize(&wr_withs, 4)
	wr_withs[3] = niello.With{text = "a Fit text much wider than any line of the box"}
	wr_frame(t)
	testing.expect_value(t, wr_rect(1).pos, niello.Vec2{0, 20})
	testing.expect_value(t, wr_rect(1).size.x, 300)
	testing.expect_value(t, wr_rect(2).pos, niello.Vec2{0, 40})
	testing.expect_value(t, wr_rect(3).size.x, 200) // a Fit child shrinks to the line
	testing.expect_value(t, wr_rect(3).pos.y, 60)
}

@(test)
test_wrap_text_child_wraps :: proc(t: ^testing.T) {
	wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}})
	defer wr_teardown()
	text: niello.Unit
	niello.mint(&text, niello.NO_UNIT, {font_size = 16, wrap = .Word})
	append(&wr_kids, text)
	append(&wr_withs, niello.With{text = "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll"})
	wr_frame(t)
	// 12 words of 32 with 8 between: five fit in 200, so three lines of 16
	testing.expect_value(t, wr_rect(0).size, niello.Vec2{200, 48})
	box, _ := niello.rect(wr_box_i)
	testing.expect_value(t, box.size.y, 48)
}

@(test)
test_wrap_scrolling :: proc(t: ^testing.T) {
	wr_setup({size = niello.Size{niello.fixed(200), niello.fixed(40)}, gap = 10, line_gap = 6, scroll = .Vertical})
	for _ in 0 ..< 6 {
		wr_kid(niello.fixed(60), niello.fixed(20))
	}
	wr_frame(t)
	wr_frame(t)
	testing.expect_value(t, niello.scroll_range(wr_box_i), niello.Vec2{0, 6}) // 20 + 6 + 20 in 40
	wr_teardown()

	wr_setup({size = niello.Size{niello.fixed(200), niello.fixed(40)}, gap = 10, scroll = .Horizontal})
	defer wr_teardown()
	for _ in 0 ..< 6 {
		wr_kid(niello.fixed(60), niello.fixed(20))
	}
	wr_frame(t)
	testing.expect_value(t, wr_rect(3).pos, niello.Vec2{210, 0}) // one line
}

@(test)
test_wrap_anchored_and_edge_cases :: proc(t: ^testing.T) {
	wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}, gap = 10})
	wr_frame(t) // empty: no lines, height 0
	box, _ := niello.rect(wr_box_i)
	testing.expect_value(t, box.size, niello.Vec2{200, 0})
	wr_teardown()

	wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}, gap = 10})
	defer wr_teardown()
	wr_kid(niello.fixed(60), niello.fixed(20))
	wr_kid(niello.fixed(30), niello.fixed(30))
	wr_kid(niello.fixed(60), niello.fixed(20))
	resize(&wr_withs, 3)
	wr_withs[1] = niello.With{anchored = true} // chrome: no slot in a line
	wr_frame(t)
	testing.expect_value(t, wr_rect(2).pos, niello.Vec2{70, 0})
	box, _ = niello.rect(wr_box_i)
	testing.expect_value(t, box.size.y, 20) // the anchored child adds no height
}

@(test)
test_wrap_line_gap_glides_and_rewraps :: proc(t: ^testing.T) {
	wr_setup({size = niello.Size{niello.fixed(200), niello.fit()}, gap = 10, line_gap = 0})
	defer wr_teardown()
	for _ in 0 ..< 5 {
		wr_kid(niello.fixed(60), niello.fixed(20))
	}
	wr_frame(t)
	wr_frame(t)
	target: niello.Unit
	niello.mint(&target, niello.NO_UNIT, {line_gap = 30})
	niello.tween(wr_box, target, 100, {.Line_Gap})
	for _ in 0 ..< 12 {
		wr_frame(t)
	}
	testing.expect_value(t, wr_rect(3).pos.y, 50) // 20 + the line_gap it glided to
	// narrower: the children rewrap (and repaint correctly)
	niello.set(wr_box, .Size, niello.Size{niello.fixed(130), niello.fit()})
	wr_frame(t)
	testing.expect_value(t, wr_rect(2).pos, niello.Vec2{0, 50})
}
