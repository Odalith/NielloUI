// chrome_test.odin — tests for the scrollbar-chrome engine surface
// (§3.20): the scroll_range query and With.anchored (chrome children
// of a scroller neither scroll nor count as content).
package tests

import niello ".."

import "core:testing"

ch_root_u, ch_stack_u, ch_content_u, ch_row_u, ch_chip_u: niello.Unit
ch_scroll_i, ch_content_i, ch_chip_i: niello.Instance
ch_row_i: [10]niello.Instance
ch_fit: bool

ch_mint :: proc() {
	ch_root_u = fixed_root() // minted ONCE: a per-frame root would
	// re-key every identity under it and orphan scroll_off
	niello.mint(&ch_stack_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.fixed(200), niello.fixed(100)},
		scroll = niello.Scroll.Vertical,
		align = [2]niello.Align_Kind{.End, .Start},
	})
	niello.mint(&ch_content_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		// Fit height: the content child of a stack scroller is sized
		// by its content, so it genuinely extends past the viewport
		// and the scroller has something to scroll.
		size = niello.Size{niello.grow(1), niello.fit()},
	})
	niello.mint(&ch_row_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(30)},
	})
	niello.mint(&ch_chip_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(20), niello.fixed(20)},
	})
}

ch_declare :: proc() {
	if _, ok := niello.begin(ch_root_u); ok {
		if si, ok2 := niello.begin(ch_stack_u); ok2 {
			ch_scroll_i = si
			if ci, ok3 := niello.begin(ch_content_u); ok3 {
				ch_content_i = ci
				for k in 0 ..< 10 {
					ch_row_i[k] = niello.show(ch_row_u, niello.key_int(k + 1))
				}
			}
			ch_chip_i = niello.show(ch_chip_u, niello.key_int(99), {anchored = true})
		}
	}
}

ch_frame :: proc() {
	niello.frame_begin(niello.Input{viewport = {400, 300}}, 0.016)
	ch_declare()
	niello.frame_end()
}

@(test)
test_scroll_range_query :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ch_mint()
	ch_frame()
	// Content is 10 x 30 = 300 tall in a 100 viewport: range 200.
	rng := niello.scroll_range(ch_scroll_i)
	testing.expect(t, abs(rng.x - 0) < EPS && abs(rng.y - 200) < EPS,
		"range = content - viewport on the scroll axis")
	// A non-scroller has no range.
	rng = niello.scroll_range(ch_chip_i)
	testing.expect(t, rng == niello.Vec2{0, 0}, "no range for plain instances")
	// The anchored chip does not inflate the range (it is 20 tall
	// and inside the viewport anyway — the FIT test below is the
	// discriminating one for content exclusion).
}

@(test)
test_anchored_child_does_not_scroll :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ch_mint()
	ch_frame()
	chip0, _ := niello.rect(ch_chip_i)
	testing.expect(t, abs(chip0.pos.x - 180) < EPS && abs(chip0.pos.y - 0) < EPS,
		"chip starts at the stack's End/Start corner")
	niello.scroll_to(ch_scroll_i, {0, 50})
	ch_frame()
	row0, _ := niello.rect(ch_row_i[0])
	testing.expect(t, abs(row0.pos.y - (-50)) < EPS, "content scrolled by 50")
	chip1, _ := niello.rect(ch_chip_i)
	testing.expect(t, abs(chip1.pos.x - 180) < EPS && abs(chip1.pos.y - 0) < EPS,
		"the anchored chip did not move")
	off := niello.scroll_offset(ch_scroll_i)
	testing.expect(t, abs(off.y - 50) < EPS, "offset reports the scroll")
}

@(test)
test_anchored_child_is_not_content_for_fit :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	// A FIT-height stack scroller holding 90px of content and a
	// 500px anchored chip: its height must come from the content.
	fit_stack: niello.Unit
	niello.mint(&fit_stack, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		size = niello.Size{niello.fixed(200), niello.fit()},
		scroll = niello.Scroll.Vertical,
	})
	content: niello.Unit
	niello.mint(&content, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(200), niello.fixed(90)},
	})
	big_chip: niello.Unit
	niello.mint(&big_chip, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(20), niello.fixed(500)},
	})
	scroll_i: niello.Instance
	niello.frame_begin(niello.Input{viewport = {400, 300}}, 0.016)
	if _, ok := niello.begin(ch_root_u); ok {
		if si, ok2 := niello.begin(fit_stack); ok2 {
			scroll_i = si
			niello.show(content, niello.key_int(1))
			niello.show(big_chip, niello.key_int(2), {anchored = true})
		}
	}
	niello.frame_end()
	r, _ := niello.rect(scroll_i)
	testing.expect(t, abs(r.size.y - 90) < EPS,
		"FIT height comes from content; the anchored chip is not content")
	rng := niello.scroll_range(scroll_i)
	testing.expect(t, rng.y == 0, "and it contributes no scroll range")
}

// ---------------------------------------------------------------------------
// Anchored in a FLOW scroller (§3.20 generalized): the bar is a
// direct child of the Column scroller — no Stack wrapper. It takes
// no flow slot, positions like a Stack child, and does not scroll.

fl_scroll_u, fl_row_u, fl_strip_u: niello.Unit
fl_scroll_i, fl_strip_i: niello.Instance
fl_row_i: [10]niello.Instance

fl_declare :: proc() {
	if _, ok := niello.begin(ch_root_u); ok {
		if si, ok2 := niello.begin(fl_scroll_u); ok2 {
			fl_scroll_i = si
			for k in 0 ..< 10 {
				fl_row_i[k] = niello.show(fl_row_u, niello.key_int(k + 1))
			}
			fl_strip_i = niello.show(fl_strip_u, niello.key_int(99), {anchored = true})
		}
	}
}

fl_frame :: proc() {
	niello.frame_begin(niello.Input{viewport = {400, 300}}, 0.016)
	fl_declare()
	niello.frame_end()
}

@(test)
test_anchored_in_flow_scroller :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ch_root_u = fixed_root()
	niello.mint(&fl_scroll_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(200), niello.fixed(100)},
		scroll = niello.Scroll.Vertical,
		align = [2]niello.Align_Kind{.Start, .End},
		padding = [4]u16{10, 10, 10, 10},
	})
	niello.mint(&fl_row_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(30)},
	})
	niello.mint(&fl_strip_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(12), niello.grow(1)},
	})
	fl_frame()
	sr, _ := niello.rect(fl_strip_i)
	testing.expect(t, abs(sr.pos.x - 188) < EPS && abs(sr.pos.y - 0) < EPS &&
		abs(sr.size.x - 12) < EPS && abs(sr.size.y - 100) < EPS,
		"strip: flush with the panel edge — padding does not inset overlays")
	r0, _ := niello.rect(fl_row_i[0])
	testing.expect(t, abs(r0.pos.x - 10) < EPS && abs(r0.pos.y - 10) < EPS,
		"rows inset by the padding, undisplaced by the strip")
	rng := niello.scroll_range(fl_scroll_i)
	testing.expect(t, abs(rng.y - 220) < EPS, "range: content + padding, strip excluded")
	niello.scroll_to(fl_scroll_i, {0, 50})
	fl_frame()
	r0, _ = niello.rect(fl_row_i[0])
	r1, _ := niello.rect(fl_row_i[1])
	testing.expect(t, abs(r0.pos.y - (-40)) < EPS && abs(r1.pos.y - (-10)) < EPS,
		"rows scroll normally, no slot was consumed")
	sr, _ = niello.rect(fl_strip_i)
	testing.expect(t, abs(sr.pos.y - 0) < EPS && abs(sr.size.y - 100) < EPS,
		"the strip does not scroll")
}
