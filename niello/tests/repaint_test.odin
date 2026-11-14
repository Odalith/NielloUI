// Partial repaint (TODO #37): Frame_Result.repaint, draw_list(rects), and
// the check that a host repainting only those regions ends with the same
// pixels as one repainting everything (test_repaint_check).
package tests

import niello ".."
import "core:testing"

rp_root, rp_box, rp_hover, rp_sel, rp_text, rp_scroller, rp_row, rp_menu: niello.Unit

rp_mint :: proc() {
	niello.mint(&rp_root, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(400), niello.fixed(300)},
		color = niello.Color{240, 240, 240, 255}, padding = niello.pad(10), gap = 6,
	})
	niello.mint(&rp_hover, niello.NO_UNIT, {color = niello.Color{200, 210, 250, 255}})
	niello.mint(&rp_sel, niello.NO_UNIT, {color = niello.Color{40, 90, 200, 255}})
	niello.mint(&rp_box, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(60), niello.fixed(24)},
		color = niello.Color{220, 220, 220, 255}, corner_radius = 4,
		hover = rp_hover, focusable = true,
	})
	niello.mint(&rp_text, niello.NO_UNIT, {font_size = 14, font_color = niello.Color{20, 20, 20, 255}})
	niello.mint(&rp_scroller, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(200), niello.fixed(80)},
		scroll = niello.Scroll.Vertical, color = niello.Color{255, 255, 255, 255},
	})
	niello.mint(&rp_row, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(20)}, font_size = 12})
	niello.mint(&rp_menu, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom, padding = niello.pad(6),
		color = niello.Color{255, 255, 255, 230}, corner_radius = 6,
	})
}

// The scene's knobs, set by each test.
rp_label:      string = "Hello"
rp_show_third: bool
rp_selected:   int
rp_menu_open:  bool
rp_boxes:      [3]niello.Instance
rp_scroll_i:   niello.Instance

rp_declare :: proc() {
	if niello.begin(rp_root) {
		for k in 0 ..< 3 {
			if k == 2 && !rp_show_third {
				continue
			}
			rp_boxes[k] = niello.show(rp_box, {variant = rp_sel if rp_selected == k + 1 else niello.NO_UNIT}, niello.key_int(k + 1))
		}
		niello.show(rp_text, {text = rp_label})
		if niello.begin(rp_scroller, out = &rp_scroll_i) {
			for k in 0 ..< 12 {
				niello.show(rp_row, {text = "row"}, niello.key_int(100 + k))
			}
		}
		if rp_menu_open {
			if niello.begin_popup(rp_menu, rp_boxes[0], .Below, opts = {gap = 2}) {
				niello.show(rp_text, {text = "First item"})
				niello.show(rp_text, {text = "Second item"})
			}
		}
	}
}

rp_frame :: proc(t: ^testing.T, inp: niello.Input = {}, dt: f32 = 0.016, loc := #caller_location) -> niello.Frame_Result {
	inp := inp
	inp.viewport = {400, 300}
	inp.window_focused = true
	niello.frame_begin(niello.test_context(), inp, dt)
	rp_declare()
	res := niello.frame_end()
	bad := niello.test_repaint_check(res)
	testing.expectf(t, bad == 0, "partial repaint differs from a full repaint in %d cells", bad, loc = loc)
	return res
}

rp_setup :: proc() {
	niello.test_reset()
	rp_mint()
	rp_label, rp_show_third, rp_selected, rp_menu_open = "Hello", false, 0, false
}

rp_at :: proc(p: niello.Vec2, down := false, pressed := false, released := false) -> niello.Input {
	inp := niello.Input{mouse = p, mouse_valid = true}
	if down { inp.buttons_down = {.Left} }
	if pressed { inp.buttons_pressed = {.Left} }
	if released { inp.buttons_released = {.Left} }
	return inp
}

rp_center :: proc(i: niello.Instance) -> niello.Vec2 {
	r, _ := niello.rect(i)
	return r.pos + r.size / 2
}

@(test)
test_repaint_rects_merge_and_cap :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_frame(t)
	res := rp_frame(t)
	testing.expect_value(t, len(res.repaint), 0) // nothing changed

	// One box: one rect, whole DIP, covering the box.
	rp_selected = 1
	res = rp_frame(t)
	testing.expect_value(t, len(res.repaint), 1)
	if len(res.repaint) == 1 {
		r := res.repaint[0]
		b, _ := niello.rect(rp_boxes[0])
		testing.expect(t, r.pos.x <= b.pos.x && r.pos.y <= b.pos.y &&
			r.pos.x + r.size.x >= b.pos.x + b.size.x && r.pos.y + r.size.y >= b.pos.y + b.size.y, "covers the box")
		testing.expect(t, r.pos.x == f32(int(r.pos.x)) && r.size.y == f32(int(r.size.y)), "whole DIP")
	}

	// Two neighbours (the selection moves): their rects touch and merge.
	rp_selected = 2
	res = rp_frame(t)
	testing.expect_value(t, len(res.repaint), 1)

	// Far apart: the first box and the text below the scroller.
	rp_selected = 1
	rp_label = "Hello there"
	res = rp_frame(t)
	testing.expect(t, len(res.repaint) >= 1 && len(res.repaint) <= 8, "a few rects at most")
}

@(test)
test_repaint_rects_clip_to_the_window :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	res := rp_frame(t) // the first frame: everything is born
	for r in res.repaint {
		testing.expect(t, r.pos.x >= 0 && r.pos.y >= 0 && r.pos.x + r.size.x <= 400 && r.pos.y + r.size.y <= 300,
			"repaint rects stay inside the window")
	}
}

// draw_list(rects) holds every command of the full list that touches the
// rects, in the same order, with balanced scopes.
@(test)
test_draw_list_rects_is_an_ordered_superset :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_menu_open = true
	rp_frame(t)
	rp_frame(t)
	rp_label = "Changed label"
	res := rp_frame(t)
	testing.expect(t, len(res.repaint) > 0, "something to repaint")

	leaf :: proc(c: niello.Draw_Cmd) -> bool {
		return c.tag == .Rect || c.tag == .Text || c.tag == .Overlay || c.tag == .Image
	}
	want := make([dynamic]niello.Draw_Cmd, context.temp_allocator)
	for c in niello.draw_list() {
		if leaf(c) && niello.draw_cmd_visible(c, res.repaint) {
			append(&want, c)
		}
	}
	part := niello.draw_list(res.repaint)
	k := 0
	depth := 0
	for c in part {
		switch c.tag {
		case .Push_Clip, .Push_Opacity:
			depth += 1
		case .Pop_Clip, .Pop_Opacity:
			depth -= 1
			testing.expect(t, depth >= 0, "pops never outnumber pushes")
		case .Rect, .Text, .Overlay, .Image:
			if k < len(want) && c == want[k] {
				k += 1
			}
		}
	}
	testing.expect_value(t, depth, 0)
	testing.expect_value(t, k, len(want))
	testing.expect(t, len(part) < len(niello.draw_list()), "the partial list is smaller")
}

@(test)
test_repaint_hover_and_variants :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_frame(t)
	rp_frame(t)
	rp_frame(t, rp_at(rp_center(rp_boxes[1]))) // hover on
	rp_frame(t, rp_at({390, 290}))              // and off
	rp_selected = 2
	rp_frame(t)
	rp_selected = 0
	rp_frame(t)
}

@(test)
test_repaint_text_grows_and_shrinks :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_frame(t)
	rp_label = "Hello, a much longer label than before"
	rp_frame(t)
	rp_label = "Hi"
	rp_frame(t)
	rp_label = ""
	rp_frame(t)
}

@(test)
test_repaint_scroll :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_frame(t)
	rp_frame(t)
	at := rp_center(rp_scroll_i)
	for _ in 0 ..< 3 {
		inp := rp_at(at)
		inp.wheel = {0, -1}
		rp_frame(t, inp)
	}
	for _ in 0 ..< 20 {
		rp_frame(t, rp_at(at)) // glides settle
	}
}

@(test)
test_repaint_popup_and_disappearing :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_show_third = true
	rp_frame(t)
	rp_frame(t)
	rp_menu_open = true
	rp_frame(t)
	rp_frame(t)
	rp_menu_open = false
	rp_frame(t)
	rp_show_third = false // an instance goes
	rp_frame(t)
}

@(test)
test_repaint_focus_ring :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_show_third = true
	rp_frame(t)
	tab := niello.Input{keys = {niello.Key_Event{key = .Tab, physical = .Tab, down = true}}}
	for _ in 0 ..< 4 {
		rp_frame(t, tab) // the ring walks the boxes and wraps
		rp_frame(t)
	}
}

@(test)
test_repaint_glide :: proc(t: ^testing.T) {
	rp_setup()
	defer niello.test_teardown()
	rp_frame(t)
	rp_frame(t)
	target: niello.Unit
	niello.mint(&target, niello.NO_UNIT, {color = niello.Color{10, 200, 90, 255}, size = niello.Size{niello.fixed(90), niello.fixed(30)}})
	niello.tween(rp_box, target, 200, {.Color, .Size})
	for _ in 0 ..< 16 {
		rp_frame(t)
	}
}
