// Headless tests for call-site identity: with no key an instance is
// named by its call site (plus the site's occurrence under the same
// parent, for loops); an explicit key alone names it.
package tests

import niello ".."
import "core:testing"

id_root, id_a, id_b, id_box, id_pop: niello.Unit

id_mint :: proc() {
	niello.mint(&id_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	niello.mint(&id_a, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fixed(10)}})
	niello.mint(&id_b, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fixed(10)}})
	niello.mint(&id_box, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.fit(), niello.fit()}})
	niello.mint(&id_pop, niello.NO_UNIT, {size = niello.Size{niello.fixed(60), niello.fixed(30)}})
}

id_frame :: proc(declare: proc()) {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
	declare()
	niello.frame_end()
}

@(test)
test_identity_conditional_sibling_shifts_nothing :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	id_mint()
	@(static) show_extra: bool
	@(static) same_unit, other_unit: niello.Instance
	declare :: proc() {
		if niello.begin(id_root) {
			if show_extra {
				niello.show(id_a) // same unit as the next line
				niello.show(id_b) // and another unit
			}
			same_unit = niello.show(id_a)
			other_unit = niello.show(id_b)
		}
	}
	id_frame(declare)
	a0, b0 := same_unit, other_unit
	show_extra = true
	id_frame(declare)
	testing.expect_value(t, same_unit, a0)
	testing.expect_value(t, other_unit, b0)
	show_extra = false
	id_frame(declare)
	testing.expect_value(t, same_unit, a0)
}

@(test)
test_identity_loop_occurrences :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	id_mint()
	@(static) n: int
	@(static) rows: [4]niello.Instance
	declare :: proc() {
		if niello.begin(id_root) {
			for k in 0 ..< n {
				rows[k] = niello.show(id_a)
			}
		}
	}
	n = 3
	id_frame(declare)
	first := rows
	testing.expect(t, first[0] != first[1] && first[1] != first[2], "one site in a loop gives each pass its own instance")
	n = 4
	id_frame(declare)
	testing.expect(t, rows[0] == first[0] && rows[1] == first[1] && rows[2] == first[2], "appending a row keeps the others")
}

@(test)
test_identity_occurrences_survive_nested_containers :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	id_mint()
	@(static) boxes: [3]niello.Instance
	@(static) inner: [3]niello.Instance
	declare :: proc() {
		if niello.begin(id_root) {
			for k in 0 ..< 3 {
				if niello.begin(id_box, out = &boxes[k]) {
					inner[k] = niello.show(id_a)
				}
			}
		}
	}
	id_frame(declare)
	testing.expect(t, boxes[0] != boxes[1] && boxes[1] != boxes[2], "the loop's containers are distinct")
	testing.expect(t, inner[0] != inner[1] && inner[1] != inner[2], "each container's child is its own")
	b, i := boxes, inner
	id_frame(declare)
	testing.expect(t, boxes == b && inner == i, "and all of it is stable across frames")
}

@(test)
test_identity_explicit_key_ignores_call_site :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	id_mint()
	@(static) wide: bool
	@(static) inst: niello.Instance
	declare :: proc() {
		if niello.begin(id_root) {
			if wide {
				inst = niello.show(id_a, niello.key_int(42))
			} else {
				inst = niello.show(id_a, niello.key_int(42))
			}
		}
	}
	id_frame(declare)
	narrow := inst
	wide = true
	id_frame(declare)
	testing.expect_value(t, inst, narrow)
}

@(test)
test_identity_popups_stable_when_another_toggles :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	id_mint()
	@(static) menu_open: bool
	@(static) dialog: niello.Instance
	declare :: proc() {
		if niello.begin(id_root) {}
		if menu_open {
			if niello.begin_popup(id_pop, 0, .At) {}
		}
		if niello.begin_popup(id_pop, 0, .Center, out = &dialog) {}
	}
	id_frame(declare)
	d0 := dialog
	menu_open = true
	id_frame(declare)
	testing.expect_value(t, dialog, d0)
}

// id_helper stands in for a component: it forwards its caller's
// location, so each use is its own call site.
id_helper :: proc(loc := #caller_location) -> (i: niello.Instance) {
	if niello.begin(id_box, out = &i, loc = loc) {
		niello.show(id_a)
	}
	return
}

@(test)
test_identity_helpers_forward_loc :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	id_mint()
	@(static) show_first: bool
	@(static) first, second: niello.Instance
	declare :: proc() {
		if niello.begin(id_root) {
			if show_first {
				first = id_helper()
			}
			second = id_helper()
		}
	}
	show_first = true
	id_frame(declare)
	testing.expect(t, first != second, "two uses of a component are two instances")
	s0 := second
	show_first = false
	id_frame(declare)
	testing.expect_value(t, second, s0)
}
