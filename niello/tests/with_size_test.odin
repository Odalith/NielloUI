// Headless tests for With.size: a per-instance size over the unit's.
package tests

import niello ".."
import "core:testing"

wsz_root, wsz_box, wsz_hover: niello.Unit
wsz_a, wsz_b, wsz_c: niello.Instance
wsz_override_b: bool

wsz_declare :: proc() {
	if niello.begin(wsz_root) {
		wsz_a = niello.show(wsz_box)
		w := niello.With{}
		if wsz_override_b {
			w.size = niello.size(niello.fixed(120), niello.fixed(30))
		}
		wsz_b = niello.show(wsz_box, w)
		wsz_c = niello.show(wsz_box, {size = niello.size(niello.fixed(60), niello.fixed(10))})
	}
}

wsz_frame :: proc(mouse: niello.Vec2 = {}, valid := false) {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}, mouse = mouse, mouse_valid = valid}, 0.016)
	wsz_declare()
	niello.frame_end()
}

@(test)
test_with_size_overrides_per_instance :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&wsz_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(400), niello.fixed(300))})
	niello.mint(&wsz_hover, niello.NO_UNIT, {size = niello.size(niello.fixed(300), niello.fixed(5))})
	niello.mint(&wsz_box, niello.NO_UNIT, {size = niello.size(niello.fixed(40), niello.fixed(20)), hover = wsz_hover})
	wsz_override_b = true
	wsz_frame()
	wsz_frame()
	ra, _ := niello.rect(wsz_a)
	rb, _ := niello.rect(wsz_b)
	rc, _ := niello.rect(wsz_c)
	testing.expect_value(t, ra.size, niello.Vec2{40, 20})
	testing.expect_value(t, rb.size, niello.Vec2{120, 30})
	testing.expect_value(t, rc.size, niello.Vec2{60, 10})
	// Dropping the override returns the instance to the unit's size.
	wsz_override_b = false
	wsz_frame()
	rb, _ = niello.rect(wsz_b)
	testing.expect_value(t, rb.size, niello.Vec2{40, 20})
	// The override wins over a state overlay's size: hover c.
	rc, _ = niello.rect(wsz_c)
	wsz_frame(rc.pos + {2, 2}, true)
	wsz_frame(rc.pos + {2, 2}, true)
	testing.expect(t, niello.hovered(wsz_c), "c is hovered")
	rc, _ = niello.rect(wsz_c)
	testing.expect_value(t, rc.size, niello.Vec2{60, 10})
}
