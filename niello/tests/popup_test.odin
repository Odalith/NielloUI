// popup_test.odin — tests for the popup layer (§3.19): placement,
// pick priority, light dismiss (+ consumption), Esc, modal absorb,
// modal focus scope/grab/restore.
//
// Geometry (viewport 400x300, root = fixed column):
//   anchor button  (0,0,80,30)
//   under button   (0,30,400,72)  — full-width, the menu covers its left part
//   menu (Below)   (0,30,120,72)  — three 120x24 items
package tests

import niello ".."

import "core:testing"

pp_root_u, pp_anchor_u, pp_under_u, pp_menu_u, pp_item_u: niello.Unit
pp_dialog_u, pp_ok_u, pp_cancel_u: niello.Unit
pp_anchor_i, pp_under_i, pp_popup_i: niello.Instance
pp_item_i: [3]niello.Instance
pp_ok_i, pp_cancel_i: niello.Instance
pp_open, pp_modal: bool
pp_modal_stay: bool
pp_dismiss_seen: bool

pp_mint :: proc() {
	niello.mint(&pp_root_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(400), niello.fixed(300)},
	})
	niello.mint(&pp_anchor_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(80), niello.fixed(30)},
		focusable = true,
	})
	niello.mint(&pp_under_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(400), niello.fixed(72)},
	})
	niello.mint(&pp_menu_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(120), niello.fit()},
	})
	niello.mint(&pp_item_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(120), niello.fixed(24)},
	})
	niello.mint(&pp_dialog_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(160), niello.fixed(100)},
		padding = [4]u16{10, 10, 10, 10},
		gap = 6,
	})
	niello.mint(&pp_ok_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(140), niello.fixed(28)},
		focusable = true,
	})
	niello.mint(&pp_cancel_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(140), niello.fixed(28)},
		focusable = true,
	})
}

pp_declare :: proc() {
	// The dismiss query is the app's close mechanism (§3.19).
	if pp_popup_i != 0 && niello.dismiss_requested(pp_popup_i) {
		pp_dismiss_seen = true
		pp_open = false
		pp_modal = false
	}
	if _, ok := niello.begin(pp_root_u); ok {
		pp_anchor_i = niello.show(pp_anchor_u, niello.key_int(1))
		pp_under_i = niello.show(pp_under_u, niello.key_int(2))
	}
	if pp_open {
		if pi, ok := niello.begin_popup(pp_menu_u, pp_anchor_i, .Below, key = niello.key_int(7)); ok {
			pp_popup_i = pi
			for k in 0 ..< 3 {
				pp_item_i[k] = niello.show(pp_item_u, niello.key_int(k + 1))
			}
		}
	}
	if pp_modal {
		if pi, ok := niello.begin_popup(pp_dialog_u, pp_anchor_i, .At,
			{modal = true, stay = pp_modal_stay, at = niello.Vec2{100, 80}}, key = niello.key_int(9)); ok {
			pp_popup_i = pi
			pp_ok_i = niello.show(pp_ok_u, niello.key_int(1))
			pp_cancel_i = niello.show(pp_cancel_u, niello.key_int(2))
		}
	}
}

pp_frame :: proc(inp: niello.Input) {
	niello.frame_begin(niello.test_context(), inp, 0.016)
	pp_declare()
	niello.frame_end()
}

pp_idle :: proc() -> niello.Input {
	return niello.Input{
		viewport = {400, 300},
		mouse = {660, 500},
		mouse_valid = false,
		window_focused = true,
	}
}

pp_at :: proc(p: niello.Vec2, pressed, released: bool) -> niello.Input {
	v := pp_idle()
	v.mouse = p
	v.mouse_valid = true
	if pressed {
		v.buttons_pressed = {.Left}
		v.buttons_down = {.Left}
	}
	if released {
		v.buttons_released = {.Left}
	}
	return v
}

pp_setup :: proc() {
	niello.test_reset()
	pp_mint()
	pp_open = false
	pp_modal = false
	pp_modal_stay = false
	pp_dismiss_seen = false
	pp_popup_i = 0
	pp_frame(pp_idle()) // settle: anchor + under committed
}

@(test)
test_popup_placement_below :: proc(t: ^testing.T) {
	pp_setup()
	defer niello.test_teardown()
	pp_open = true
	pp_frame(pp_idle())
	r, ok := niello.rect(pp_popup_i)
	testing.expect(t, ok, "popup committed")
	testing.expect(t, abs(r.pos.x - 0) < EPS && abs(r.pos.y - 30) < EPS &&
		abs(r.size.x - 120) < EPS && abs(r.size.y - 72) < EPS,
		"menu sits below the anchor, content height")
	expect_rect(t, pp_item_i[1], niello.Rect{{0, 54}, {120, 24}})
}

@(test)
test_popup_pick_beats_main_tree :: proc(t: ^testing.T) {
	pp_setup()
	defer niello.test_teardown()
	pp_open = true
	pp_frame(pp_idle())
	// (60,60) is inside menu item 1 AND inside the under button.
	pp_frame(pp_at({60, 60}, true, false))
	testing.expect(t, niello.pressed(pp_item_i[1]), "the popup item takes the press")
	testing.expect(t, !niello.pressed(pp_under_i), "the covered main-tree button does not")
	pp_frame(pp_at({60, 60}, false, true))
	testing.expect(t, niello.clicked(pp_item_i[1]), "the item clicks")
	testing.expect(t, !niello.clicked(pp_under_i), "the under button never clicks")
	testing.expect(t, pp_open, "a press inside the popup does not dismiss it")
}

@(test)
test_popup_light_dismiss_consumes_the_press :: proc(t: ^testing.T) {
	pp_setup()
	defer niello.test_teardown()
	pp_open = true
	pp_frame(pp_idle())
	// Press on the under button, right of the menu: outside the popup.
	pp_frame(pp_at({200, 60}, true, false))
	testing.expect(t, pp_dismiss_seen, "dismissal was requested")
	testing.expect(t, !pp_open, "the app closed the popup")
	testing.expect(t, !niello.pressed(pp_under_i), "the dismissing press is consumed")
	pp_frame(pp_at({200, 60}, false, true))
	testing.expect(t, !niello.clicked(pp_under_i), "and never completes as a click")
	// The same press with no popup open clicks normally.
	pp_dismiss_seen = false
	pp_frame(pp_at({200, 60}, true, false))
	pp_frame(pp_at({200, 60}, false, true))
	testing.expect(t, niello.clicked(pp_under_i), "no popup: the button clicks")
}

@(test)
test_popup_esc_dismisses_and_is_consumed :: proc(t: ^testing.T) {
	pp_setup()
	defer niello.test_teardown()
	pp_open = true
	pp_frame(pp_idle())
	niello.focus(pp_anchor_i)
	pp_frame(pp_idle())
	testing.expect(t, niello.focused(pp_anchor_i), "anchor focused")
	inp := pp_idle()
	inp.keys[0] = niello.Key_Event{scancode = niello.SCANCODE_ESCAPE, down = true}
	inp.key_count = 1
	pp_frame(inp)
	testing.expect(t, pp_dismiss_seen, "Esc requested dismissal")
	testing.expect(t, !pp_open, "the app closed the popup")
	testing.expect(t, len(niello.input_keys(pp_anchor_i)) == 0, "Esc was consumed, not routed")
}

@(test)
test_popup_anchor_gone_does_not_open :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	pp_mint()
	pp_open = true
	pp_modal = false
	pp_popup_i = 0
	// Never declare the main tree: the anchor has no committed rect.
	niello.frame_begin(niello.test_context(), pp_idle(), 0.016)
	opened := true
	if _, ok := niello.begin(pp_root_u); ok {
		// (anchor deliberately not shown)
	}
	if _, ok := niello.begin_popup(pp_menu_u, 424242, .Below); ok {
		opened = true
	} else {
		opened = false
	}
	niello.frame_end()
	testing.expect(t, !opened, "no anchor rect -> no popup")
}

@(test)
test_popup_modal_outside_press_absorbs_and_dismisses :: proc(t: ^testing.T) {
	pp_setup()
	defer niello.test_teardown()
	pp_modal = true
	pp_frame(pp_idle())
	r, ok := niello.rect(pp_popup_i)
	testing.expect(t, ok, "dialog committed")
	testing.expect(t, abs(r.pos.x - 100) < EPS && abs(r.pos.y - 80) < EPS &&
		abs(r.size.x - 160) < EPS && abs(r.size.y - 100) < EPS,
		"dialog placed At the point")
	// Press the under button, far outside the dialog: the press is
	// absorbed (nothing underneath ever sees it) AND the modal is
	// light-dismissed — the backdrop-click-cancels rule. A press
	// inside the dialog still lands normally (checked pre-dismiss:
	// reopen for the inside half).
	pp_frame(pp_at({150, 100}, true, false))
	testing.expect(t, niello.pressed(pp_ok_i), "inside the modal, presses land")
	pp_frame(pp_at({150, 100}, false, true))
	testing.expect(t, niello.clicked(pp_ok_i), "and click")
	pp_frame(pp_at({200, 60}, true, false))
	testing.expect(t, !niello.pressed(pp_under_i), "absorbed: no press under a modal")
	testing.expect(t, pp_dismiss_seen, "and the modal is dismissed")
	testing.expect(t, !pp_modal, "the app closed it")
	pp_frame(pp_at({200, 60}, false, true))
	testing.expect(t, !niello.clicked(pp_under_i), "no click completes either")
}

@(test)
test_popup_stay_modal_absorbs_without_dismissing :: proc(t: ^testing.T) {
	pp_setup()
	defer niello.test_teardown()
	pp_modal = true
	pp_modal_stay = true
	pp_frame(pp_idle())
	pp_frame(pp_at({200, 60}, true, false))
	testing.expect(t, !niello.pressed(pp_under_i), "absorbed, as any modal")
	testing.expect(t, !pp_dismiss_seen, "but a stay modal is never light-dismissed")
	pp_frame(pp_at({200, 60}, false, true))
	testing.expect(t, pp_modal, "the stay modal survives outside presses")
	testing.expect(t, !niello.clicked(pp_under_i), "and nothing underneath clicks")
}

@(test)
test_popup_placement_center :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	pp_mint()
	pp_popup_i = 0
	frame_c :: proc() {
		niello.frame_begin(niello.test_context(), pp_idle(), 0.016)
		if pi, ok := niello.begin_popup(pp_menu_u, 0, .Center, key = niello.key_int(7)); ok {
			pp_popup_i = pi
			for k in 0 ..< 3 {
				niello.show(pp_item_u, niello.key_int(k + 1))
			}
		}
		niello.frame_end()
	}
	frame_c()
	r, ok := niello.rect(pp_popup_i)
	testing.expect(t, ok, "popup committed")
	// (400-120)/2, (300-72)/2.
	testing.expect(t, abs(r.pos.x - 140) < EPS && abs(r.pos.y - 114) < EPS,
		"Center places the popup on the viewport center")
}

@(test)
test_popup_modal_focus_scope_grab_restore :: proc(t: ^testing.T) {
	pp_setup()
	defer niello.test_teardown()
	niello.focus(pp_anchor_i)
	pp_frame(pp_idle())
	testing.expect(t, niello.focused(pp_anchor_i), "anchor focused before the modal")
	pp_modal = true
	pp_frame(pp_idle())
	testing.expect(t, niello.focused(pp_ok_i), "opening the modal grabs its first focusable")
	tab := pp_idle()
	tab.keys[0] = niello.Key_Event{scancode = niello.SCANCODE_TAB, down = true}
	tab.key_count = 1
	pp_frame(tab)
	testing.expect(t, niello.focused(pp_cancel_i), "Tab moves within the dialog")
	pp_frame(tab)
	testing.expect(t, niello.focused(pp_ok_i), "Tab wraps inside the dialog, never reaching the anchor")
	pp_modal = false
	pp_frame(pp_idle())
	testing.expect(t, niello.focused(pp_anchor_i), "closing the modal restores the snapshot")
}

@(test)
test_popup_stay_ignores_outside_press :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	pp_mint()
	pp_open = false
	pp_modal = false
	pp_modal_stay = false
	pp_dismiss_seen = false
	pp_popup_i = 0
	pp_frame(pp_idle())
	// A toast: stay = true. Declared via a local pattern — reuse the
	// menu but keep it open manually.
	niello.frame_begin(niello.test_context(), pp_idle(), 0.016)
	if _, ok := niello.begin(pp_root_u); ok {
		niello.show(pp_anchor_u, niello.key_int(1))
		niello.show(pp_under_u, niello.key_int(2))
	}
	if pi, ok := niello.begin_popup(pp_menu_u, pp_anchor_i, .Below, {stay = true}, key = niello.key_int(7)); ok {
		pp_popup_i = pi
		niello.show(pp_item_u, niello.key_int(1))
	}
	niello.frame_end()
	inp := pp_at({200, 60}, true, false)
	niello.frame_begin(niello.test_context(), inp, 0.016)
	if pp_popup_i != 0 && niello.dismiss_requested(pp_popup_i) {
		pp_dismiss_seen = true
	}
	if _, ok := niello.begin(pp_root_u); ok {
		niello.show(pp_anchor_u, niello.key_int(1))
		niello.show(pp_under_u, niello.key_int(2))
	}
	if pi, ok := niello.begin_popup(pp_menu_u, pp_anchor_i, .Below, {stay = true}, key = niello.key_int(7)); ok {
		pp_popup_i = pi
		niello.show(pp_item_u, niello.key_int(1))
	}
	niello.frame_end()
	testing.expect(t, !pp_dismiss_seen, "stay popups are never light-dismissed")
	testing.expect(t, niello.pressed(pp_under_i), "and the press is not consumed either")
}

// ---------------------------------------------------------------------------
// Placement edges: anchored flip on overflow, At clamp.

pp_spacer_u: niello.Unit
pp_flip_mode: int // 0 = Below a bottom anchor, 1 = At a corner point

pp_flip_declare :: proc() {
	if _, ok := niello.begin(pp_root_u); ok {
		if pp_flip_mode == 0 {
			niello.show(pp_spacer_u, niello.key_int(1))
		}
		pp_anchor_i = niello.show(pp_anchor_u, niello.key_int(2))
	}
	if pp_flip_mode == 0 {
		if pi, ok := niello.begin_popup(pp_menu_u, pp_anchor_i, .Below, key = niello.key_int(7)); ok {
			pp_popup_i = pi
			for k in 0 ..< 3 {
				niello.show(pp_item_u, niello.key_int(k + 1))
			}
		}
	} else {
		if pi, ok := niello.begin_popup(pp_menu_u, pp_anchor_i, .At,
			{at = niello.Vec2{390, 290}}, key = niello.key_int(7)); ok {
			pp_popup_i = pi
			for k in 0 ..< 3 {
				niello.show(pp_item_u, niello.key_int(k + 1))
			}
		}
	}
}

pp_flip_frame :: proc() {
	niello.frame_begin(niello.test_context(), pp_idle(), 0.016)
	pp_flip_declare()
	niello.frame_end()
}

@(test)
test_popup_placement_flips_and_clamps :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	pp_mint()
	niello.mint(&pp_spacer_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(80), niello.fixed(270)},
	})
	pp_popup_i = 0
	// Anchor at y 270..300 (bottom edge): Below would leave the
	// viewport (300 + 72 > 300), Above fits -> flip.
	pp_flip_mode = 0
	pp_flip_frame() // settle the anchor
	pp_flip_frame()
	r, ok := niello.rect(pp_popup_i)
	testing.expect(t, ok, "popup committed")
	testing.expect(t, abs(r.pos.y - 198) < EPS, "flipped above the bottom anchor")
	testing.expect(t, abs(r.pos.x - 0) < EPS, "cross axis unchanged")
	// At {390,290} with a 120x72 popup: clamps into the 400x300
	// viewport (280, 228) rather than reflecting around the point
	// (270, 218) or leaving the viewport.
	pp_flip_mode = 1
	pp_flip_frame()
	r, ok = niello.rect(pp_popup_i)
	testing.expect(t, ok, "popup committed (At)")
	testing.expect(t, abs(r.pos.x - 280) < EPS && abs(r.pos.y - 228) < EPS,
		"At clamps into the viewport at the corner")
}

// At clamp, threshold-crossing: the point is app-owned state, so
// the popup must pin at the edge as the point moves past it, not
// jump by its full size — the dragged-dialog bug. A 120x72 popup
// in a 400x300 viewport crosses the far edges at x 280, y 228.
pp_at_pt: niello.Vec2

pp_at_declare :: proc() {
	if _, ok := niello.begin(pp_root_u); ok {
		pp_anchor_i = niello.show(pp_anchor_u, niello.key_int(2))
	}
	if pi, ok := niello.begin_popup(pp_menu_u, pp_anchor_i, .At,
		{at = pp_at_pt}, key = niello.key_int(7)); ok {
		pp_popup_i = pi
		for k in 0 ..< 3 {
			niello.show(pp_item_u, niello.key_int(k + 1))
		}
	}
}

@(test)
test_popup_at_clamps_without_jump :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	pp_mint()
	pp_popup_i = 0
	pp_at_pt = niello.Vec2{280, 228}
	niello.frame_begin(niello.test_context(), pp_idle(), 0.016)
	pp_at_declare()
	niello.frame_end()
	r, ok := niello.rect(pp_popup_i)
	testing.expect(t, ok, "popup committed at the threshold")
	testing.expect(t, abs(r.pos.x-280) < EPS && abs(r.pos.y-228) < EPS,
		"flush at the threshold")
	// One DIP past the threshold on both axes: still pinned at
	// the edge. Under the old reflect this jumped to (180, 178),
	// opposite the edge touched.
	pp_at_pt = niello.Vec2{300, 250}
	niello.frame_begin(niello.test_context(), pp_idle(), 0.016)
	pp_at_declare()
	niello.frame_end()
	r, ok = niello.rect(pp_popup_i)
	testing.expect(t, ok, "popup committed past the threshold")
	testing.expect(t, abs(r.pos.x-280) < EPS && abs(r.pos.y-228) < EPS,
		"pinned at the edge, no jump")
}
