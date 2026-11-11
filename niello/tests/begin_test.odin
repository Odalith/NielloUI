// Headless tests for the container API: begin / begin_popup return the
// cull signal, write the instance through out, and current() names the
// innermost open container.
package tests

import niello ".."
import "core:testing"

bg_root, bg_row, bg_cell, bg_popup: niello.Unit

bg_mint :: proc() {
	niello.mint(&bg_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	niello.mint(&bg_row, niello.NO_UNIT, {layout = .Left_To_Right, size = niello.Size{niello.fit(), niello.fit()}})
	niello.mint(&bg_cell, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.fixed(20)}})
	niello.mint(&bg_popup, niello.NO_UNIT, {size = niello.Size{niello.fixed(80), niello.fixed(40)}})
}

bg_frame :: proc(declare: proc()) {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
	declare()
	niello.frame_end()
}

@(test)
test_begin_out_written_open_and_culled :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	bg_mint()
	@(static) row_i: niello.Instance
	@(static) open_seen, force_cull: bool
	declare :: proc() {
		if niello.begin(bg_root) {
			if force_cull {
				niello.test_force_cull_next()
			}
			open_seen = niello.begin(bg_row, out = &row_i)
		}
	}
	bg_frame(declare)
	testing.expect(t, open_seen, "an on-screen container is open")
	first := row_i
	testing.expect(t, first != 0, "out receives the instance")

	row_i = 0
	force_cull = true
	bg_frame(declare)
	testing.expect(t, !open_seen, "a culled container reports closed")
	testing.expect_value(t, row_i, first)
}

@(test)
test_begin_children_belong_to_the_if_block :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	bg_mint()
	@(static) a, b, after: niello.Instance
	declare :: proc() {
		if niello.begin(bg_root) {
			if niello.begin(bg_row) {
				a = niello.show(bg_cell, key = niello.key_int(1))
				b = niello.show(bg_cell, key = niello.key_int(2))
			}
			after = niello.show(bg_cell, key = niello.key_int(3))
		}
	}
	bg_frame(declare)
	ra, _ := niello.rect(a)
	rb, _ := niello.rect(b)
	rafter, _ := niello.rect(after)
	testing.expect(t, rb.pos.x == ra.pos.x + 50 && rb.pos.y == ra.pos.y, "both cells lay out in the row")
	testing.expect(t, rafter.pos.x == 0 && rafter.pos.y == ra.pos.y + 20, "the next declaration is the row's sibling")
}

@(test)
test_current_names_innermost_container :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	bg_mint()
	@(static) outside, in_root, in_row, back_in_root, root_i, row_i: niello.Instance
	declare :: proc() {
		outside = niello.current()
		if niello.begin(bg_root, out = &root_i) {
			in_root = niello.current()
			if niello.begin(bg_row, out = &row_i) {
				in_row = niello.current()
			}
			back_in_root = niello.current()
		}
	}
	bg_frame(declare)
	testing.expect_value(t, outside, niello.Instance(0))
	testing.expect_value(t, in_root, root_i)
	testing.expect_value(t, in_row, row_i)
	testing.expect_value(t, back_in_root, root_i)
}

@(test)
test_begin_popup_out_and_signal :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	bg_mint()
	@(static) anchor, pop_i, missing_i: niello.Instance
	@(static) pop_open, missing_open: bool
	declare :: proc() {
		if niello.begin(bg_root) {
			anchor = niello.show(bg_cell, key = niello.key_int(1))
		}
		// A block scopes each popup: its deferred end runs at the brace.
		{
			pop_open = niello.begin_popup(bg_popup, anchor, .Below, key = niello.key_int(1), opts = {gap = 4}, out = &pop_i)
		}
		{
			missing_open = niello.begin_popup(bg_popup, niello.Instance(424242), .Below, key = niello.key_int(2), out = &missing_i)
		}
	}
	bg_frame(declare) // the anchor gets its first committed rect
	bg_frame(declare)
	testing.expect(t, pop_open && pop_i != 0, "a popup on a live anchor opens and reports its instance")
	r, ok := niello.rect(pop_i)
	ra, _ := niello.rect(anchor)
	testing.expect(t, ok && r.pos.y == ra.pos.y + ra.size.y + 4, "opts.gap places it below the anchor")
	testing.expect(t, !missing_open && missing_i != 0, "an unanchored popup reports closed but still writes out")
	testing.expect(t, niello.test_stack_depth() == 0, "every container popped")
}
