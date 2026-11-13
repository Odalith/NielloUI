package tests

import "core:testing"
import niello ".."

// The engine focus ring, focus-visible modality and reveal on keyboard
// focus (§3.17).
//
// Fixture: a column with a rounded button holding a label (default
// ring mode), a field (.Always), a variant of the field, a quiet
// control (.Never), and a plain button whose mode a With overrides.

fr_root, fr_btn, fr_lab, fr_field, fr_field2, fr_quiet, fr_plain: niello.Unit
fr_btn_i, fr_field_i, fr_field2_i, fr_quiet_i, fr_plain_i: niello.Instance
fr_plain_never: bool

fr_mint :: proc() {
	fr_plain_never = false
	niello.mint(&fr_root, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fixed(400), niello.fixed(300)),
		gap = 10, padding = niello.pad(20),
	})
	niello.mint(&fr_btn, niello.NO_UNIT, {
		layout = .Left_To_Right, size = niello.size(niello.fixed(100), niello.fixed(30)),
		corner_radius = 6, color = niello.rgb(0x334455), focusable = true,
	})
	niello.mint(&fr_lab, niello.NO_UNIT, {font_size = 14})
	niello.mint(&fr_field, niello.NO_UNIT, {
		size = niello.size(niello.fixed(200), niello.fixed(30)),
		color = niello.rgb(0x101010), focusable = true, focus_ring = .Always,
	})
	niello.mint(&fr_field2, fr_field, {color = niello.rgb(0x202020)})
	niello.mint(&fr_quiet, niello.NO_UNIT, {
		size = niello.size(niello.fixed(100), niello.fixed(30)),
		color = niello.rgb(0x303030), focusable = true, focus_ring = .Never,
	})
	niello.mint(&fr_plain, niello.NO_UNIT, {
		size = niello.size(niello.fixed(100), niello.fixed(20)),
		color = niello.rgb(0x404040), focusable = true,
	})
}

fr_declare :: proc() {
	if niello.begin(fr_root) {
		if niello.begin(fr_btn, out = &fr_btn_i) {
			niello.show(fr_lab, {text = "OK"})
		}
		fr_field_i = niello.show(fr_field)
		fr_field2_i = niello.show(fr_field2)
		fr_quiet_i = niello.show(fr_quiet)
		w := niello.With{}
		if fr_plain_never {
			w.focus_ring = .Never
		}
		fr_plain_i = niello.show(fr_plain, w)
	}
}

fr_frame :: proc(declare: proc(), keys: []niello.Key_Event = nil, click: Maybe(niello.Vec2) = nil) -> niello.Frame_Result {
	inp := idle_input(AWAY_PT)
	if p, ok := click.?; ok {
		inp = idle_input(p)
		inp.buttons_pressed = {.Left}
		inp.buttons_down = {.Left}
	}
	for ev, i in keys {
		inp.keys[i] = ev
	}
	inp.key_count = len(keys)
	niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
	return finish(declare)
}

fr_tab :: proc(declare: proc(), shift := false) -> niello.Frame_Result {
	mods := shift ? SHIFT : niello.Modifiers{}
	return fr_frame(declare, []niello.Key_Event{kev(.Tab, true, mods), kev(.Tab, false, mods)})
}

fr_click :: proc(declare: proc(), i: niello.Instance) -> niello.Frame_Result {
	r, _ := niello.rect(i)
	fr_frame(declare, click = r.pos + r.size / 2)
	// Release on the next frame so the press capture ends.
	return fr_frame(declare)
}

// ring_cmds collects the Overlay commands with a transparent fill and a
// border: the ring's shape (the fixture paints no overlay of its own).
ring_cmds :: proc() -> (out: [dynamic]niello.Draw_Cmd, idx: [dynamic]int) {
	for cmd, k in niello.draw_list() {
		if cmd.tag == .Overlay && cmd.color.a == 0 && cmd.border_width > 0 {
			append(&out, cmd)
			append(&idx, k)
		}
	}
	return
}

grow_rect :: proc(r: niello.Rect, e: f32) -> niello.Rect {
	return niello.Rect{r.pos - {e, e}, r.size + {2 * e, 2 * e}}
}

has_rect :: proc(rs: []niello.Rect, r: niello.Rect) -> bool {
	for x in rs {
		if x == r {
			return true
		}
	}
	return false
}

@(test)
test_focus_ring_on_tab :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fr_mint()
	fr_frame(fr_declare)
	fr_tab(fr_declare)
	testing.expect(t, niello.focused(fr_btn_i), "Tab focuses the first control")
	testing.expect(t, niello.focus_visible(fr_btn_i), "keyboard focus is visible")
	rings, idx := ring_cmds()
	defer delete(rings)
	defer delete(idx)
	testing.expect_value(t, len(rings), 1)
	if len(rings) != 1 {
		return
	}
	r, _ := niello.rect(fr_btn_i)
	ring := rings[0]
	d := niello.DEFAULT_FOCUS_RING
	testing.expect_value(t, ring.bounds, grow_rect(r, f32(d.offset) + f32(d.width)))
	testing.expect_value(t, ring.radius, u8(6 + d.offset + i16(d.width)))
	testing.expect_value(t, ring.border_color, d.color)
	testing.expect_value(t, ring.border_width, d.width)
	// Above the subtree: after the label's text command.
	last_text := -1
	for cmd, k in niello.draw_list() {
		if cmd.tag == .Text {
			last_text = k
		}
	}
	testing.expect(t, last_text >= 0 && idx[0] > last_text, "the ring paints after the button's children")
}

@(test)
test_focus_ring_hidden_on_click_until_key :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fr_mint()
	fr_frame(fr_declare)
	fr_click(fr_declare, fr_btn_i)
	testing.expect(t, niello.focused(fr_btn_i), "the click focuses the button")
	testing.expect(t, !niello.focus_visible(fr_btn_i), "pointer focus is not visible")
	rings, idx := ring_cmds()
	testing.expect_value(t, len(rings), 0)
	delete(rings); delete(idx)
	// A lone modifier is not keyboard use.
	fr_frame(fr_declare, []niello.Key_Event{kev(.Left_Shift, true)})
	testing.expect(t, !niello.focus_visible(fr_btn_i), "a modifier alone keeps the ring hidden")
	// Any other key while focus is held shows it.
	fr_frame(fr_declare, []niello.Key_Event{kev(.Down, true), kev(.Down, false)})
	testing.expect(t, niello.focus_visible(fr_btn_i), "a key press makes focus visible")
	rings, idx = ring_cmds()
	testing.expect_value(t, len(rings), 1)
	delete(rings); delete(idx)
	// Clicking the focused button again hides it.
	fr_click(fr_declare, fr_btn_i)
	testing.expect(t, !niello.focus_visible(fr_btn_i), "a click on the holder hides the ring again")
	// focus() on the holder shows it.
	niello.focus(fr_btn_i)
	testing.expect(t, niello.focus_visible(fr_btn_i), "programmatic focus is visible")
}

@(test)
test_focus_ring_modes :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fr_mint()
	fr_frame(fr_declare)
	fr_click(fr_declare, fr_field_i)
	testing.expect(t, niello.focus_visible(fr_field_i), ".Always: pointer focus is visible")
	rings, idx := ring_cmds()
	testing.expect_value(t, len(rings), 1)
	delete(rings); delete(idx)
	fr_click(fr_declare, fr_field2_i)
	rings, idx = ring_cmds()
	testing.expect(t, len(rings) == 1 && niello.focus_visible(fr_field2_i), "a variant inherits the base's ring mode")
	delete(rings); delete(idx)
	// Tab from field2 lands on the quiet control.
	fr_tab(fr_declare)
	testing.expect(t, niello.focused(fr_quiet_i), "Tab reaches the quiet control")
	testing.expect(t, niello.focus_visible(fr_quiet_i), ".Never still reports focus_visible")
	rings, idx = ring_cmds()
	testing.expect_value(t, len(rings), 0)
	delete(rings); delete(idx)
	// The plain button rings by default; a With override silences it.
	fr_tab(fr_declare)
	testing.expect(t, niello.focused(fr_plain_i), "Tab reaches the plain button")
	rings, idx = ring_cmds()
	testing.expect_value(t, len(rings), 1)
	delete(rings); delete(idx)
	fr_plain_never = true
	fr_frame(fr_declare)
	rings, idx = ring_cmds()
	testing.expect_value(t, len(rings), 0)
	delete(rings); delete(idx)
}

@(test)
test_focus_ring_config_and_damage :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fr_mint()
	fr_frame(fr_declare)
	res := fr_tab(fr_declare)
	r, _ := niello.rect(fr_btn_i)
	old_ring := grow_rect(r, 4)
	testing.expect(t, has_rect(res.damage, old_ring), "the ring's rect is damage when it appears")
	res = fr_frame(fr_declare)
	testing.expect(t, !res.changed, "a steady ring costs nothing")
	// Moving focus damages both rings, which lie outside the nodes.
	res = fr_tab(fr_declare)
	rf, _ := niello.rect(fr_field_i)
	testing.expect(t, has_rect(res.damage, old_ring), "the old ring is damaged")
	testing.expect(t, has_rect(res.damage, grow_rect(rf, 4)), "the new ring is damaged")
	// Re-theme: color, width and offset follow, and the change damages.
	red := niello.rgb(0xff0000)
	niello.set_focus_ring({color = red, width = 3, offset = 0})
	res = fr_frame(fr_declare)
	testing.expect(t, has_rect(res.damage, grow_rect(rf, 3)), "a config change damages the ring")
	rings, idx := ring_cmds()
	testing.expect(t, len(rings) == 1 && rings[0].border_color == red && rings[0].bounds == grow_rect(rf, 3), "the ring takes the new config")
	delete(rings); delete(idx)
	// Width 0 turns it off.
	niello.set_focus_ring({color = red, width = 0})
	res = fr_frame(fr_declare)
	rings, idx = ring_cmds()
	testing.expect_value(t, len(rings), 0)
	delete(rings); delete(idx)
	testing.expect(t, has_rect(res.damage, grow_rect(rf, 3)), "turning the ring off damages where it was")
}

// A clipped, translucent focus holder: the ring paints after its clip
// pops (it lies outside the rect) and before its opacity pops (it fades
// with the node).
fs_root, fs_box, fs_inner: niello.Unit
fs_box_i: niello.Instance

fs_declare :: proc() {
	if niello.begin(fs_root) {
		if niello.begin(fs_box, out = &fs_box_i) {
			niello.show(fs_inner)
		}
	}
}

@(test)
test_focus_ring_scope_order :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&fs_root, niello.NO_UNIT, {size = niello.size(niello.fixed(400), niello.fixed(300)), padding = niello.pad(20)})
	niello.mint(&fs_box, niello.NO_UNIT, {
		size = niello.size(niello.fixed(100), niello.fixed(50)), overflow = .Clip, opacity = 128,
		color = niello.rgb(0x222222), focusable = true,
	})
	niello.mint(&fs_inner, niello.NO_UNIT, {size = niello.size(niello.fixed(10), niello.fixed(10)), color = niello.rgb(0x999999)})
	fr_frame(fs_declare)
	fr_tab(fs_declare)
	cmds := niello.draw_list()
	ring := -1
	for cmd, k in cmds {
		if cmd.tag == .Overlay {
			ring = k
		}
	}
	testing.expect(t, ring > 0 && ring + 1 < len(cmds), "the ring is emitted inside the walk")
	if ring > 0 && ring + 1 < len(cmds) {
		testing.expect_value(t, cmds[ring - 1].tag, niello.Draw_Cmd_Tag.Pop_Clip)
		testing.expect_value(t, cmds[ring + 1].tag, niello.Draw_Cmd_Tag.Pop_Opacity)
	}
}

// Reveal: a 200x100 scroller of ten 30-DIP focusable rows (range 200).
rv_root, rv_scroller, rv_row, rv_outer, rv_spacer: niello.Unit
rv_rows: [10]niello.Instance
rv_scroller_i, rv_outer_i: niello.Instance

rv_mint :: proc() {
	niello.mint(&rv_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(400), niello.fixed(300))})
	niello.mint(&rv_scroller, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fixed(200), niello.fixed(100)), scroll = .Vertical,
	})
	niello.mint(&rv_row, niello.NO_UNIT, {size = niello.size(niello.fixed(180), niello.fixed(30)), color = niello.rgb(0x333333), focusable = true})
	niello.mint(&rv_outer, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fixed(220), niello.fixed(150)), scroll = .Vertical,
	})
	niello.mint(&rv_spacer, niello.NO_UNIT, {size = niello.size(niello.fixed(200), niello.fixed(120))})
}

rv_list :: proc() {
	if niello.begin(rv_scroller, out = &rv_scroller_i) {
		for k in 0 ..< len(rv_rows) {
			rv_rows[k] = niello.show(rv_row, key = niello.key_int(k))
		}
	}
}

rv_declare :: proc() {
	if niello.begin(rv_root) {
		rv_list()
	}
}

// The nested form: the list sits below a spacer inside an outer
// scroller (content 220 in a 150 viewport).
rv_nested_declare :: proc() {
	if niello.begin(rv_root) {
		if niello.begin(rv_outer, out = &rv_outer_i) {
			niello.show(rv_spacer)
			rv_list()
		}
	}
}

// inside_y: the scrolled axis only — the rows sit flush with the
// scroller's left edge, so the ring's horizontal margin is clipped
// there by design (an outset ring inside a clipping parent).
inside_y :: proc(inner, outer: niello.Rect) -> bool {
	return inner.pos.y >= outer.pos.y && inner.pos.y + inner.size.y <= outer.pos.y + outer.size.y
}

@(test)
test_focus_reveal_on_tab :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	rv_mint()
	fr_frame(rv_declare)
	for _ in 0 ..< 5 {
		fr_tab(rv_declare)
	}
	testing.expect(t, niello.focused(rv_rows[4]), "five Tabs reach row 4")
	res := fr_frame(rv_declare)
	_ = res
	rr, _ := niello.rect(rv_rows[4])
	sr, _ := niello.rect(rv_scroller_i)
	testing.expect(t, niello.scroll_offset(rv_scroller_i).y > 0, "the scroller moved")
	testing.expect(t, inside_y(grow_rect(rr, 4), sr), "the row and its ring are in view")
	testing.expect_value(t, niello.scroll_offset(rv_scroller_i).y, f32(4 * 30 + 30 + 4 - 100))
	// To the last row, then Tab wraps to row 0 and the list returns to the top.
	for _ in 0 ..< 5 {
		fr_tab(rv_declare)
	}
	fr_frame(rv_declare)
	testing.expect(t, niello.focused(rv_rows[9]), "row 9")
	testing.expect_value(t, niello.scroll_offset(rv_scroller_i).y, f32(200))
	fr_tab(rv_declare)
	fr_frame(rv_declare)
	testing.expect(t, niello.focused(rv_rows[0]), "Tab wraps to row 0")
	testing.expect_value(t, niello.scroll_offset(rv_scroller_i).y, f32(0))
}

@(test)
test_focus_reveal_pointer_and_programmatic :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	rv_mint()
	fr_frame(rv_declare)
	// Row 3 spans 90..120 in a 0..100 viewport: partly visible. Click
	// its visible part.
	r3, _ := niello.rect(rv_rows[3])
	fr_frame(rv_declare, click = r3.pos + {10, 5})
	fr_frame(rv_declare)
	fr_frame(rv_declare)
	testing.expect(t, niello.focused(rv_rows[3]), "the click focuses row 3")
	testing.expect_value(t, niello.scroll_offset(rv_scroller_i).y, f32(0))
	// focus() is keyboard focus: it reveals.
	niello.focus(rv_rows[7])
	fr_frame(rv_declare)
	fr_frame(rv_declare)
	r7, _ := niello.rect(rv_rows[7])
	sr, _ := niello.rect(rv_scroller_i)
	testing.expect(t, inside_y(grow_rect(r7, 4), sr), "focus() scrolls row 7 into view")
}

@(test)
test_focus_reveal_nested :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	rv_mint()
	fr_frame(rv_nested_declare)
	niello.focus(rv_rows[6])
	fr_frame(rv_nested_declare)
	fr_frame(rv_nested_declare)
	r6, _ := niello.rect(rv_rows[6])
	sr, _ := niello.rect(rv_scroller_i)
	or_, _ := niello.rect(rv_outer_i)
	testing.expect(t, niello.scroll_offset(rv_scroller_i).y > 0, "the inner list scrolled")
	testing.expect(t, niello.scroll_offset(rv_outer_i).y > 0, "the outer scroller scrolled")
	testing.expect(t, inside_y(grow_rect(r6, 4), sr), "the row is inside the list")
	testing.expect(t, inside_y(grow_rect(r6, 4), or_), "and inside the outer viewport")
}

// The per-unit overlay command now follows the node's corners.
orad_root, orad_box, orad_ring: niello.Unit
orad_box_i: niello.Instance

orad_declare :: proc() {
	if niello.begin(orad_root) {
		orad_box_i = niello.show(orad_box)
	}
}

@(test)
test_overlay_carries_corner_radius :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.set_focus_ring({width = 0})
	niello.mint(&orad_root, niello.NO_UNIT, {size = niello.size(niello.fixed(400), niello.fixed(300)), padding = niello.pad(20)})
	niello.mint(&orad_ring, niello.NO_UNIT, {overlay_border_color = niello.rgb(0x00ff00), overlay_border_width = 2})
	niello.mint(&orad_box, niello.NO_UNIT, {
		size = niello.size(niello.fixed(100), niello.fixed(40)), corner_radius = 8,
		focusable = true, focus = orad_ring,
	})
	fr_frame(orad_declare)
	fr_tab(orad_declare)
	found := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Overlay {
			found = true
			testing.expect_value(t, cmd.radius, u8(8))
		}
	}
	testing.expect(t, found, "the focus overlay paints")
}

// A smooth_scroll scroller glides to the revealed position like the
// wheel, instead of jumping.
@(test)
test_focus_reveal_glides_when_smooth :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	rv_mint()
	niello.set_many(rv_scroller, {smooth_scroll = true, smooth_ms = u16(100)})
	fr_frame(rv_declare)
	niello.focus(rv_rows[7])
	fr_frame(rv_declare)
	fr_frame(rv_declare)
	mid := niello.scroll_offset(rv_scroller_i).y
	target := f32(7 * 30 + 30 + 4 - 100)
	testing.expect(t, mid > 0 && mid < target, "the first frame is part-way there")
	for _ in 0 ..< 12 {
		fr_frame(rv_declare)
	}
	testing.expect_value(t, niello.scroll_offset(rv_scroller_i).y, target)
}
