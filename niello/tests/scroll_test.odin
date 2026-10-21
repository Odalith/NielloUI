// Headless tests for scrolling (niello/input.odin's consume_wheel +
// layout.odin's pass F offset read). The harness feeds synthetic Input
// frames with wheel deltas and asserts on scroll_offset + committed
// rects. Remember the model: dispatch at frame_begin consumes against
// LAST frame's tree, so the wheel lands on the frame AFTER the tree
// first exists, and its effect renders in that same frame.
package tests

import niello ".."
import "core:testing"

// ---- shared trees -----------------------------------------------------------
//
// flat:   root 400x300 > outer scroller 200x100 (column, .Vertical) with
//         6 rows of 30 -> content 180, scroll range [0, 80].
// nested: root > outer (same) > [inner scroller 200x60 (.Vertical) with
//         4 rows of 30 -> range [0, 60]; then 4 plain rows] -> outer
//         content is again 180, range [0, 80].

sc_root, sc_outer, sc_inner, sc_row, sc_cell, sc_strip: niello.Unit
sc_outer_i, sc_inner_i, sc_strip_i: niello.Instance
sc_first_row_i, sc_mid_row_i, sc_first_cell_i: niello.Instance
sc_inner_disabled: bool

OUTER_PT :: niello.Vec2{100, 90} // inside outer, below the nested inner
INNER_PT :: niello.Vec2{100, 30} // inside the nested inner scroller
STRIP_PT :: niello.Vec2{100, 25} // inside the horizontal strip

mint_flat_tree :: proc() {
	sc_root = fixed_root()
	niello.mint(&sc_outer, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size   = niello.Size{niello.fixed(200), niello.fixed(100)},
		scroll = niello.Scroll.Vertical,
	})
	niello.mint(&sc_row, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(30)},
	})
}

declare_flat_tree :: proc() {
	if _, ok := niello.begin(sc_root); ok {
		if oi, ok2 := niello.begin(sc_outer); ok2 {
			sc_outer_i = oi
			for k in 0 ..< 6 {
				ri := niello.show(sc_row, niello.key_int(k))
				if k == 0 {
					sc_first_row_i = ri
				}
				if k == 2 {
					sc_mid_row_i = ri
				}
			}
		}
	}
}

mint_nested_tree :: proc(inner_chains: bool) {
	mint_flat_tree()
	niello.mint(&sc_inner, niello.NO_UNIT, {
		layout       = niello.Layout.Top_To_Bottom,
		size         = niello.Size{niello.fixed(200), niello.fixed(60)},
		scroll       = niello.Scroll.Vertical,
		scroll_chain = inner_chains,
	})
}

declare_nested_tree :: proc() {
	if _, ok := niello.begin(sc_root); ok {
		if oi, ok2 := niello.begin(sc_outer); ok2 {
			sc_outer_i = oi
			w := niello.With{}
			if sc_inner_disabled {
				w.disabled = true
			}
			if ii, ok3 := niello.begin(sc_inner, 0, w); ok3 {
				sc_inner_i = ii
				for k in 0 ..< 4 {
					ri := niello.show(sc_row, niello.key_int(k))
					if k == 0 {
						sc_first_row_i = ri
					}
				}
			}
			for k in 0 ..< 4 {
				niello.show(sc_row, niello.key_int(10 + k))
			}
		}
	}
}

plain_frame :: proc(declare: proc(), mouse: niello.Vec2) -> niello.Frame_Result {
	niello.frame_begin(idle_input(mouse), 0.016)
	return finish(declare)
}

wheel_frame :: proc(declare: proc(), mouse: niello.Vec2, wheel: niello.Vec2) -> niello.Frame_Result {
	inp := idle_input(mouse)
	inp.wheel = wheel
	niello.frame_begin(inp, 0.016)
	return finish(declare)
}

rect_contains :: proc(a, b: niello.Rect) -> bool {
	return(
		b.pos.x >= a.pos.x &&
		b.pos.y >= a.pos.y &&
		b.pos.x + b.size.x <= a.pos.x + a.size.x &&
		b.pos.y + b.size.y <= a.pos.y + a.size.y \
	)
}

// ---- tests ------------------------------------------------------------------

@(test)
test_wheel_scrolls_container :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_flat_tree()

	plain_frame(declare_flat_tree, OUTER_PT)
	r0, _ := niello.rect(sc_first_row_i)
	testing.expect(t, abs(r0.pos.y) < EPS, "row 0 starts at the top")

	// One wheel unit = WHEEL_UNIT_PX (48) of offset, rendered this frame.
	wheel_frame(declare_flat_tree, OUTER_PT, {0, 1})
	off := niello.scroll_offset(sc_outer_i)
	testing.expect(t, off == niello.Vec2{0, 48}, "one notch scrolls 48px")
	r1, _ := niello.rect(sc_first_row_i)
	testing.expect(t, abs(r1.pos.y - (-48)) < EPS, "content moved up by the offset")

	// Fractional (trackpad) deltas scale linearly, both directions.
	wheel_frame(declare_flat_tree, OUTER_PT, {0, -0.5})
	off = niello.scroll_offset(sc_outer_i)
	testing.expect(t, off == niello.Vec2{0, 24}, "half a notch back up")
}

@(test)
test_wheel_clamps_to_range :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_flat_tree()

	plain_frame(declare_flat_tree, OUTER_PT)
	wheel_frame(declare_flat_tree, OUTER_PT, {0, 10})
	off := niello.scroll_offset(sc_outer_i)
	testing.expect(t, off == niello.Vec2{0, 80}, "clamped at the scroll range end (180-100)")
	r, _ := niello.rect(sc_first_row_i)
	testing.expect(t, abs(r.pos.y - (-80)) < EPS, "content rests at the clamp")

	wheel_frame(declare_flat_tree, OUTER_PT, {0, -10})
	off = niello.scroll_offset(sc_outer_i)
	testing.expect(t, off == niello.Vec2{0, 0}, "clamped back at the top")
}

@(test)
test_wheel_chains_to_ancestor :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sc_inner_disabled = false
	mint_nested_tree(true)

	plain_frame(declare_nested_tree, INNER_PT)
	wheel_frame(declare_nested_tree, INNER_PT, {0, 1})
	testing.expect(t, niello.scroll_offset(sc_inner_i) == niello.Vec2{0, 48},
		"inner takes the first notch whole")
	testing.expect(t, niello.scroll_offset(sc_outer_i) == niello.Vec2{0, 0},
		"nothing left to chain yet")

	// Inner has 12px of range left; the other 36 chain to the outer.
	wheel_frame(declare_nested_tree, INNER_PT, {0, 1})
	testing.expect(t, niello.scroll_offset(sc_inner_i) == niello.Vec2{0, 60},
		"inner clamps at its own range end")
	testing.expect(t, niello.scroll_offset(sc_outer_i) == niello.Vec2{0, 36},
		"leftover chained to the outer scroller")
	ir, _ := niello.rect(sc_inner_i)
	testing.expect(t, abs(ir.pos.y - (-36)) < EPS, "the inner container itself rode the outer offset")
}

@(test)
test_wheel_chain_opt_out_drops_leftover :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sc_inner_disabled = false
	mint_nested_tree(false) // inner: scroll_chain = false

	plain_frame(declare_nested_tree, INNER_PT)
	wheel_frame(declare_nested_tree, INNER_PT, {0, 1})
	wheel_frame(declare_nested_tree, INNER_PT, {0, 1})
	testing.expect(t, niello.scroll_offset(sc_inner_i) == niello.Vec2{0, 60},
		"inner still scrolls to its own end")
	testing.expect(t, niello.scroll_offset(sc_outer_i) == niello.Vec2{0, 0},
		"opt-out ends the wheel region: leftover dropped, outer unmoved")
}

@(test)
test_wheel_disabled_absorbs :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sc_inner_disabled = true
	mint_nested_tree(true)

	plain_frame(declare_nested_tree, INNER_PT)
	wheel_frame(declare_nested_tree, INNER_PT, {0, 1})
	testing.expect(t, niello.scroll_offset(sc_inner_i) == niello.Vec2{0, 0},
		"disabled scroller does not scroll")
	testing.expect(t, niello.scroll_offset(sc_outer_i) == niello.Vec2{0, 0},
		"and the wheel does not fall through to its parent either")
	sc_inner_disabled = false
}

@(test)
test_scroll_damage_covers_moved_children :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_flat_tree()

	plain_frame(declare_flat_tree, OUTER_PT)
	old, _ := niello.rect(sc_mid_row_i)
	fr := wheel_frame(declare_flat_tree, OUTER_PT, {0, 1})
	new, _ := niello.rect(sc_mid_row_i)
	testing.expect(t, abs(new.pos.y - (old.pos.y - 48)) < EPS, "the row moved with the scroll")

	// No explicit damage call exists for scrolling: pass F's rect diff
	// (old ∪ new, expanded) must cover the moved row on its own.
	covered := false
	for d in fr.damage {
		if rect_contains(d, old) && rect_contains(d, new) {
			covered = true
		}
	}
	testing.expect(t, covered, "frame damage covers the scrolled row's old and new rects")
}

@(test)
test_scroll_to_and_offset :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_flat_tree()

	plain_frame(declare_flat_tree, OUTER_PT)
	niello.scroll_to(sc_outer_i, {0, 30})
	plain_frame(declare_flat_tree, OUTER_PT)
	testing.expect(t, niello.scroll_offset(sc_outer_i) == niello.Vec2{0, 30},
		"scroll_to lands and reports back")
	r, _ := niello.rect(sc_first_row_i)
	testing.expect(t, abs(r.pos.y - (-30)) < EPS, "content rendered at the programmatic offset")

	// Out-of-range requests land on the nearest end once rendered: the
	// stored value itself is re-clamped by pass F.
	niello.scroll_to(sc_outer_i, {0, 999})
	plain_frame(declare_flat_tree, OUTER_PT)
	testing.expect(t, niello.scroll_offset(sc_outer_i) == niello.Vec2{0, 80},
		"scroll_to past the end clamps to the range")
	niello.scroll_to(sc_outer_i, {0, 0})
	plain_frame(declare_flat_tree, OUTER_PT)
	testing.expect(t, niello.scroll_offset(sc_outer_i) == niello.Vec2{0, 0}, "back to top")
}

@(test)
test_wheel_horizontal :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sc_root = fixed_root()
	niello.mint(&sc_strip, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size   = niello.Size{niello.fixed(200), niello.fixed(50)},
		scroll = niello.Scroll.Horizontal,
	})
	niello.mint(&sc_cell, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(60), niello.fixed(50)},
	})

	plain_frame(declare_strip_tree, STRIP_PT)
	wheel_frame(declare_strip_tree, STRIP_PT, {1, 0})
	testing.expect(t, niello.scroll_offset(sc_strip_i) == niello.Vec2{48, 0},
		"wheel x scrolls the horizontal strip")
	r, _ := niello.rect(sc_first_cell_i)
	testing.expect(t, abs(r.pos.x - (-48)) < EPS, "cells moved left by the offset")
}

declare_strip_tree :: proc() {
	if _, ok := niello.begin(sc_root); ok {
		if si, ok2 := niello.begin(sc_strip); ok2 {
			sc_strip_i = si
			for k in 0 ..< 6 {
				ci := niello.show(sc_cell, niello.key_int(k))
				if k == 0 {
					sc_first_cell_i = ci
				}
			}
		}
	}
}
