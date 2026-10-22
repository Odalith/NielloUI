package tests

import "core:testing"
import niello ".."

// Focus traversal, routing, and activation (TODO #8, §3.17).
//
// Fixture: a column with three focusable buttons (A, B, C), a fourth
// focusable button shown disabled (D), and a plain label (L).
// Tab order is declaration order; D and L never participate.

fo_root, fo_btn, fo_press_u, fo_label: niello.Unit
fo_a, fo_b, fo_c, fo_d: niello.Instance
fo_hide_c, fo_disable_b: bool
fo_cap_pressed_a, fo_cap_clicked_a: bool
fo_cap_text_a, fo_cap_text_b: string
fo_cap_keys_a, fo_cap_keys_b: int

fo_mint :: proc() {
	niello.mint(&fo_root, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(400), niello.fixed(300)},
		gap = 10, padding = [4]u16{10, 10, 10, 10},
	})
	niello.mint(&fo_press_u, niello.NO_UNIT, {color = niello.Color{200, 60, 60, 255}})
	niello.mint(&fo_btn, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(40)},
		color = niello.Color{60, 60, 70, 255},
		press = fo_press_u,
		focusable = true,
	})
	niello.mint(&fo_label, niello.NO_UNIT, {font_size = 14})
}

fo_declare :: proc() {
	fo_cap_pressed_a = false
	fo_cap_clicked_a = false
	fo_cap_text_a = niello.input_text(fo_a)
	fo_cap_text_b = niello.input_text(fo_b)
	fo_cap_keys_a = len(niello.input_keys(fo_a))
	fo_cap_keys_b = len(niello.input_keys(fo_b))
	if _, ok := niello.begin(fo_root); ok {
		fo_a = niello.show(fo_btn, niello.key_int(1))
		fo_b = niello.show(fo_btn, niello.key_int(2), {disabled = fo_disable_b})
		if !fo_hide_c {
			fo_c = niello.show(fo_btn, niello.key_int(3))
		}
		fo_d = niello.show(fo_btn, niello.key_int(4), {disabled = true})
		niello.show(fo_label, 0, {text = "label"})
		if niello.pressed(fo_a) { fo_cap_pressed_a = true }
		if niello.clicked(fo_a) { fo_cap_clicked_a = true }
		fo_cap_text_a = niello.input_text(fo_a)
		fo_cap_text_b = niello.input_text(fo_b)
		fo_cap_keys_a = len(niello.input_keys(fo_a))
		fo_cap_keys_b = len(niello.input_keys(fo_b))
	}
}

kev :: proc(scan: u32, down: bool, mods: u16 = 0, repeat: bool = false) -> niello.Key_Event {
	return niello.Key_Event{scancode = scan, down = down, mods = mods, repeat = repeat}
}

fo_frame :: proc(keys: []niello.Key_Event = nil, text: string = "") {
	inp := idle_input(AWAY_PT)
	for ev, i in keys {
		inp.keys[i] = ev
	}
	inp.key_count = len(keys)
	inp.text = text
	niello.frame_begin(inp, 1.0 / 60.0)
	finish(fo_declare)
}

TAB_EV :: niello.SCANCODE_TAB
SHIFT :: u16(0x0003)

@(test)
test_tab_traversal_order_and_wrap :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fo_mint()
	fo_hide_c, fo_disable_b = false, false
	fo_frame() // settle
	testing.expect(t, !niello.focused(fo_a) && !niello.focused(fo_b), "nothing focused initially")
	fo_frame({kev(TAB_EV, true)})
	testing.expect(t, niello.focused(fo_a), "Tab from nothing lands on the first focusable")
	fo_frame({kev(TAB_EV, true)})
	testing.expect(t, niello.focused(fo_b), "Tab advances in declaration order")
	fo_frame({kev(TAB_EV, true)})
	testing.expect(t, niello.focused(fo_c), "and again (the disabled D is not next)")
	fo_frame({kev(TAB_EV, true)})
	testing.expect(t, niello.focused(fo_a), "Tab wraps, skipping disabled D and the label")
	fo_frame({kev(TAB_EV, true, SHIFT)})
	testing.expect(t, niello.focused(fo_c), "Shift+Tab reverses, wrapping backward")
	fo_frame({kev(TAB_EV, true, SHIFT)})
	testing.expect(t, niello.focused(fo_b), "and keeps reversing")
}

@(test)
test_input_routing_to_focused :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fo_mint()
	fo_frame()
	fo_frame({kev(TAB_EV, true)}) // focus A
	fo_frame({kev(TAB_EV, true)}) // focus B
	letter := kev(u32('A'), true) // scancode space is opaque for letters
	fo_frame({letter}, "x")
	testing.expect(t, fo_cap_text_b == "x", "committed text routes to the focused instance")
	testing.expect(t, fo_cap_text_a == "", "and nowhere else")
	testing.expect(t, fo_cap_keys_b == 1, "key events route to the focused instance")
	testing.expect(t, fo_cap_keys_a == 0, "and nowhere else")
	fo_frame({}, "y")
	testing.expect(t, fo_cap_text_b == "y", "text with no keys still routes")
	// A frame whose Tab moves focus: the text goes to the NEW focus
	// (routing freezes after traversal), and Tab itself is consumed.
	fo_frame({kev(TAB_EV, true)}, "z")
	testing.expect(t, niello.focused(fo_c), "Tab moved focus to C")
	testing.expect(t, fo_cap_text_b == "", "B gets nothing after losing focus")
	testing.expect(t, fo_cap_keys_b == 0, "and no keys either (Tab was consumed)")
}

@(test)
test_click_to_focus :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fo_mint()
	fo_frame() // settle
	rb, _ := niello.rect(fo_b)
	center := rb.pos + rb.size / 2
	inp := idle_input(center)
	inp.buttons_pressed = {.Left}
	inp.buttons_down = {.Left}
	niello.frame_begin(inp, 1.0 / 60.0)
	finish(fo_declare)
	testing.expect(t, niello.focused(fo_b), "pressing a focusable instance focuses it")
	// Pressing unfocusable ground clears focus (rule flipped after
	// the form demo's first run: leaving it read as stuck focus).
	inp2 := idle_input({350, 285}) // below every control, root only
	inp2.buttons_pressed = {.Left}
	inp2.buttons_down = {.Left}
	niello.frame_begin(inp2, 1.0 / 60.0)
	finish(fo_declare)
	testing.expect(t, !niello.focused(fo_b), "pressing empty space clears focus")
	// Refocus B for the disabled check below.
	rb2, _ := niello.rect(fo_b)
	inp2b := idle_input(rb2.pos + rb2.size / 2)
	inp2b.buttons_pressed = {.Left}
	inp2b.buttons_down = {.Left}
	niello.frame_begin(inp2b, 1.0 / 60.0)
	finish(fo_declare)
	testing.expect(t, niello.focused(fo_b), "B refocused")
	// Pressing disabled D does not focus it.
	rd, _ := niello.rect(fo_d)
	inp3 := idle_input(rd.pos + rd.size / 2)
	inp3.buttons_pressed = {.Left}
	inp3.buttons_down = {.Left}
	niello.frame_begin(inp3, 1.0 / 60.0)
	finish(fo_declare)
	testing.expect(t, niello.focused(fo_b), "pressing a disabled control does not focus it")
	testing.expect(t, !niello.focused(fo_d), "D never takes focus")
}

@(test)
test_key_activation :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fo_mint()
	fo_frame()
	fo_frame({kev(TAB_EV, true)}) // focus A
	SPACE :: niello.SCANCODE_SPACE
	fo_frame({kev(SPACE, true)})
	testing.expect(t, fo_cap_pressed_a, "Space down presses the focused instance")
	r, _ := niello.rect(fo_a)
	c, _ := fill_color_at(r)
	testing.expect(t, c.r == 200, "the press overlay paints during a key press")
	fo_frame({kev(SPACE, false)})
	testing.expect(t, fo_cap_clicked_a, "Space up completes the click")
	// Enter activates too.
	fo_frame({kev(niello.SCANCODE_RETURN, true)})
	fo_frame({kev(niello.SCANCODE_RETURN, false)})
	testing.expect(t, fo_cap_clicked_a, "Enter activates as well")
	// Moving focus mid-press cancels: down, Tab away, up -> no click.
	fo_cap_clicked_a = false
	fo_frame({kev(SPACE, true)})
	fo_frame({kev(TAB_EV, true)})
	fo_frame({kev(SPACE, false)})
	testing.expect(t, !fo_cap_clicked_a, "focus leaving mid-press cancels the click")
	testing.expect(t, niello.focused(fo_b), "focus did move to B")
}

@(test)
test_focus_survival :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fo_mint()
	fo_frame()
	fo_frame({kev(TAB_EV, true)})
	fo_frame({kev(TAB_EV, true)})
	fo_frame({kev(TAB_EV, true)}) // focus C
	testing.expect(t, niello.focused(fo_c), "C focused")
	fo_hide_c = true
	fo_frame()
	testing.expect(t, !niello.focused(fo_c), "focus clears when the instance leaves the tree")
	fo_hide_c = false
	fo_frame({kev(TAB_EV, true)}) // focus A again (fresh tree has C back)
	fo_frame({kev(TAB_EV, true)}) // focus B
	testing.expect(t, niello.focused(fo_b), "B focused")
	fo_disable_b = true
	fo_frame()
	testing.expect(t, !niello.focused(fo_b), "focus clears when the instance becomes disabled")
	fo_disable_b = false
}

@(test)
test_focus_next_prev_verbs :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fo_mint()
	fo_frame()
	niello.focus_next()
	testing.expect(t, niello.focused(fo_a), "focus_next lands on the first focusable")
	niello.focus_next()
	testing.expect(t, niello.focused(fo_b), "and advances")
	niello.focus_prev()
	testing.expect(t, niello.focused(fo_a), "focus_prev steps back")
}

// With.focusable: the per-instance override. A unit that is NOT
// focusable contributes a tab stop only where shown with
// focusable = true; a focusable unit's instance shown with
// focusable = false drops out.

fw_root, fw_row, fw_bar: niello.Unit
fw_r1, fw_r2, fw_r3, fw_b1, fw_b2: niello.Instance

fw_declare :: proc() {
	if _, ok := niello.begin(fw_root); ok {
		fw_r1 = niello.show(fw_row, niello.key_int(1))
		fw_r2 = niello.show(fw_row, niello.key_int(2), {focusable = true})
		fw_r3 = niello.show(fw_row, niello.key_int(3))
		fw_b1 = niello.show(fw_bar, niello.key_int(4))
		fw_b2 = niello.show(fw_bar, niello.key_int(5), {focusable = false})
	}
}

@(test)
test_with_focusable_override :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&fw_root, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(400), niello.fixed(300)},
		gap = 10, padding = [4]u16{10, 10, 10, 10},
	})
	niello.mint(&fw_row, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(30)},
		color = niello.Color{60, 60, 70, 255},
	}) // NOT focusable at the unit level
	niello.mint(&fw_bar, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(30)},
		color = niello.Color{70, 60, 60, 255},
		focusable = true,
	})
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	finish(fw_declare) // settle
	// Tab: candidates in declaration order are r2 (With on) and b1
	// (unit on, not overridden off). Everything else is skipped.
	inp := idle_input(AWAY_PT)
	inp.keys[0] = kev(TAB_EV, true)
	inp.key_count = 1
	niello.frame_begin(inp, 1.0 / 60.0)
	finish(fw_declare)
	testing.expect(t, niello.focused(fw_r2), "only the With-enabled row instance is a tab stop")
	niello.frame_begin(inp, 1.0 / 60.0)
	finish(fw_declare)
	testing.expect(t, niello.focused(fw_b1), "then the focusable unit's plain instance")
	niello.frame_begin(inp, 1.0 / 60.0)
	finish(fw_declare)
	testing.expect(t, niello.focused(fw_r2), "wrap: the With-disabled instance never joins")
	testing.expect(t, !niello.focused(fw_r1) && !niello.focused(fw_r3) && !niello.focused(fw_b2), "non-stops stay unfocused")
}

// Instance death is damage (regression: the form demo's Clear). A
// node that disappears leaves pixels behind; when a previously-seen
// instance returns with the same rect and content hash, the frame
// must still report damage — for the DEAD node's rect — or the old
// content lingers until an unrelated repaint.

dd_root, dd_a, dd_b: niello.Unit
dd_show_a: bool
dd_a_rect: niello.Rect

dd_declare :: proc() {
	if _, ok := niello.begin(dd_root); ok {
		if dd_show_a {
			i := niello.show(dd_a, niello.key_int(1), {text = "aaaaaaaaaaaaaaaaaaaa"})
			if r, ok2 := niello.rect(i); ok2 {
				dd_a_rect = r
			}
		} else {
			niello.show(dd_b, niello.key_int(1), {text = "bb"})
		}
	}
}

@(test)
test_instance_death_damages :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&dd_root, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(400), niello.fixed(300)},
	})
	niello.mint(&dd_a, niello.NO_UNIT, {font_size = 16})
	niello.mint(&dd_b, niello.NO_UNIT, {font_size = 16})
	dd_show_a = false
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	finish(dd_declare) // settle with B (B enters the instance map)
	dd_show_a = true // B dies, A appears
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	res := finish(dd_declare)
	testing.expect(t, res.changed, "a death + birth frame is changed")
	dd_show_a = false // A dies; B returns with its settle rect+hash
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	res = finish(dd_declare)
	testing.expect(t, res.changed, "the returning instance's frame still damages (the death)")
	covered := false
	for d in res.damage {
		if d.pos.x <= dd_a_rect.pos.x && d.pos.y <= dd_a_rect.pos.y &&
		   d.pos.x + d.size.x >= dd_a_rect.pos.x + dd_a_rect.size.x &&
		   d.pos.y + d.size.y >= dd_a_rect.pos.y + dd_a_rect.size.y {
			covered = true
		}
	}
	testing.expect(t, covered, "damage covers the dead instance's rect")
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	res = finish(dd_declare)
	testing.expect(t, !res.changed, "steady state again: no phantom damage")
}
