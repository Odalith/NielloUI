// Headless tests for input dispatch and state-overlay resolution
// (niello/input.odin). The harness feeds synthetic Input frames and asserts
// on the polled queries, exactly as app code would read them during
// declare. Remember the model: dispatch at frame_begin hit-tests LAST
// frame's tree, so interaction assertions belong to the frame AFTER the
// tree first exists.
package tests

import niello ".."
import "core:testing"

// ---- shared tree: root column 400x300, button 120x40 at (0,0), its label
// "OK" (16x16 at (0,0) under mock metrics) inside it.

input_root, input_btn, input_lbl: niello.Unit
input_root_i, input_btn_i, input_lbl_i: niello.Instance
in_btn_radius: u8 // corner radius for the shared button; 0 unless a test sets it

BTN_PT :: niello.Vec2{60, 20} // inside the button, outside the label
LBL_PT :: niello.Vec2{8, 8} // inside the label
AWAY_PT :: niello.Vec2{300, 200} // inside the root only

mint_input_tree :: proc() {
	niello.mint(
		&input_root,
		niello.NO_UNIT,
		{
			layout = niello.Layout.Top_To_Bottom,
			size = niello.Size{niello.fixed(400), niello.fixed(300)},
			color = [4]u8{30, 30, 30, 255},
		},
	)
	niello.mint(
		&input_btn,
		niello.NO_UNIT,
		{
			size = niello.Size{niello.fixed(120), niello.fixed(40)},
			color = [4]u8{200, 0, 0, 255},
			cursor = niello.Cursor_Kind.Pointer,
			corner_radius = in_btn_radius,
		},
	)
	niello.mint(
		&input_lbl,
		niello.NO_UNIT,
		{size = niello.Size{niello.fit(), niello.fit()}},
	)
}

declare_input_tree :: proc() {
	if ri, ok := niello.begin(input_root); ok {
		input_root_i = ri
		if bi, ok2 := niello.begin(input_btn); ok2 {
			input_btn_i = bi
			input_lbl_i = niello.show(input_lbl, 0, niello.With{text = "OK"})
		}
	}
}

idle_input :: proc(mouse: niello.Vec2) -> niello.Input {
	return niello.Input{
		viewport = {400, 300},
		mouse = mouse,
		mouse_valid = true,
		window_focused = true,
	}
}

// finish completes a frame whose frame_begin already ran: declare + end.
finish :: proc(declare: proc()) -> niello.Frame_Result {
	declare()
	return niello.frame_end()
}

@(test)
test_input_hover :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()

	// Frame 1 builds the tree (dispatch saw an empty one: nothing hovered).
	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	// Frame 2: dispatch hit-tests frame 1's tree.
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "button hovered")
	testing.expect(t, niello.hovered(input_root_i), "hover bubbles to the root")
	testing.expect(t, !niello.hovered(input_lbl_i), "label not under the point")
	res := finish(declare_input_tree)
	testing.expect(t, res.changed, "hover change damages the frame")

	// Frame 3: same input, nothing changed — the clean fast path survives.
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_input_tree)
	testing.expect(t, !res.changed, "unchanged hover leaves the frame clean")

	// Frame 4: cursor moves off the button.
	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 1.0 / 60.0)
	testing.expect(t, !niello.hovered(input_btn_i), "hover lost on move-off")
	testing.expect(t, niello.hovered(input_root_i), "root still hovered")
	finish(declare_input_tree)
}

@(test)
test_input_click :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	// Press frame.
	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	testing.expect(t, niello.pressed(input_btn_i), "pressed after the press edge")
	testing.expect(t, !niello.clicked(input_btn_i), "no click on press alone")
	finish(declare_input_tree)

	// Release frame: the click lands, for this one declare.
	rel := idle_input(BTN_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel, 1.0 / 60.0)
	testing.expect(t, niello.clicked(input_btn_i), "click completes on release")
	testing.expect(t, niello.clicked(input_root_i), "click bubbles to ancestors")
	testing.expect(t, !niello.pressed(input_btn_i), "press ends at release")
	finish(declare_input_tree)

	// Next frame: clicked is gone (one-declare lifetime).
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	testing.expect(t, !niello.clicked(input_btn_i), "clicked lasts exactly one frame")
	finish(declare_input_tree)
}

@(test)
test_input_click_bubbles_from_label :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	niello.frame_begin(niello.test_context(), idle_input(LBL_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	press := idle_input(LBL_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	testing.expect(t, niello.pressed(input_lbl_i), "label is the press target")
	testing.expect(t, niello.pressed(input_btn_i), "press bubbles to the button")
	finish(declare_input_tree)

	rel := idle_input(LBL_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel, 1.0 / 60.0)
	testing.expect(t, niello.clicked(input_lbl_i), "label clicked")
	testing.expect(t, niello.clicked(input_btn_i), "button clicked via its label")
	finish(declare_input_tree)
}

@(test)
test_input_press_capture :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	finish(declare_input_tree)

	// Drag off while held: capture keeps pressed; hover follows the cursor.
	drag := idle_input(AWAY_PT)
	drag.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), drag, 1.0 / 60.0)
	testing.expect(t, niello.pressed(input_btn_i), "capture holds pressed off-target")
	testing.expect(t, !niello.hovered(input_btn_i), "hover follows the cursor, not the capture")
	finish(declare_input_tree)

	// Release off-target: no click.
	rel := idle_input(AWAY_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel, 1.0 / 60.0)
	testing.expect(t, !niello.clicked(input_btn_i), "release off-target cancels the click")
	testing.expect(t, !niello.pressed(input_btn_i), "capture ends at release")
	finish(declare_input_tree)

	// Press again, drag off, drag BACK on, release: since §3.28
	// (TODO #27, F1 ruled 2026-10-23) the excursion crossed the drag
	// threshold, so the release completes the DRAG, not a click —
	// this supersedes the pre-drag rule this test originally pinned
	// (a drag off-and-back used to click).
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	finish(declare_input_tree)
	niello.frame_begin(niello.test_context(), drag, 1.0 / 60.0)
	finish(declare_input_tree)
	back := idle_input(BTN_PT)
	back.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), back, 1.0 / 60.0)
	finish(declare_input_tree)
	rel2 := idle_input(BTN_PT)
	rel2.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel2, 1.0 / 60.0)
	testing.expect(t, !niello.clicked(input_btn_i), "a drag's release back on target does not click (§3.28 F1)")
	testing.expect(t, niello.drag_ended(input_btn_i), "the release ends the drag")
	testing.expect(t, niello.drag_completed(input_btn_i), "a release ends the drag completed")
	finish(declare_input_tree)
}

@(test)
test_input_hover_duration :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 0.25)
	finish(declare_input_tree)

	// Entry: every chain member starts its own timer at 0.
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 0.25)
	testing.expect(t, niello.hover_duration(input_btn_i) == 0, "duration starts at 0 on entry")
	testing.expect(t, niello.hover_duration(input_root_i) == 0, "root entered the same frame")
	finish(declare_input_tree)

	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 0.25)
	d := niello.hover_duration(input_btn_i)
	testing.expect(t, d > 0.25 - EPS && d < 0.25 + EPS, "duration accumulates dt")
	d = niello.hover_duration(input_root_i)
	testing.expect(t, d > 0.25 - EPS && d < 0.25 + EPS, "chain members share the session")
	finish(declare_input_tree)

	// Crossing onto the label: the button's timer runs on (one session),
	// the label's starts now.
	niello.frame_begin(niello.test_context(), idle_input(LBL_PT), 0.25)
	d = niello.hover_duration(input_btn_i)
	testing.expect(t, d > 0.5 - EPS && d < 0.5 + EPS, "button timer survives the label crossing")
	testing.expect(t, niello.hover_duration(input_lbl_i) == 0, "label timer starts at the crossing")
	finish(declare_input_tree)

	niello.frame_begin(niello.test_context(), idle_input(LBL_PT), 0.25)
	d = niello.hover_duration(input_btn_i)
	testing.expect(t, d > 0.75 - EPS && d < 0.75 + EPS, "button keeps accumulating over its label")
	d = niello.hover_duration(input_lbl_i)
	testing.expect(t, d > 0.25 - EPS && d < 0.25 + EPS, "label accumulates from its own entry")
	finish(declare_input_tree)

	// Leaving to root-only ground: button and label timers die with
	// their chain membership; the root's session never broke.
	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 0.25)
	testing.expect(t, niello.hover_duration(input_btn_i) == 0, "duration ends when the chain leaves")
	testing.expect(t, niello.hover_duration(input_lbl_i) == 0, "label duration ends too")
	d = niello.hover_duration(input_root_i)
	testing.expect(t, d > 1.0 - EPS && d < 1.0 + EPS, "root kept its own continuous timer")
	finish(declare_input_tree)
}

@(test)
test_input_focus_loss_drops_press :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	finish(declare_input_tree)

	// The window loses focus mid-press, with the release in the same frame:
	// the capture drops on the falling edge, so no click can complete —
	// but hover is not focus-gated and stays.
	lost := idle_input(BTN_PT)
	lost.window_focused = false
	lost.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), lost, 1.0 / 60.0)
	testing.expect(t, !niello.pressed(input_btn_i), "focus loss drops the press capture")
	testing.expect(t, !niello.clicked(input_btn_i), "no click completes across focus loss")
	testing.expect(t, niello.hovered(input_btn_i), "hover survives focus loss")
	finish(declare_input_tree)

	// Still unfocused: hover keeps tracking.
	niello.frame_begin(niello.test_context(), lost, 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "hover tracks while unfocused")
	finish(declare_input_tree)

	// Focus returns: the dropped press does not resurrect.
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "hover still on the button")
	testing.expect(t, !niello.pressed(input_btn_i), "press stays dropped")
	finish(declare_input_tree)
}

@(test)
test_input_unfocused_hover_and_click :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()

	// The window never has focus in this test: hover works, and the
	// press that would focus the window dispatches like any other
	// (click-to-activate instead of click-to-focus-then-click-again).
	unfocused := idle_input(BTN_PT)
	unfocused.window_focused = false
	niello.frame_begin(niello.test_context(), unfocused, 1.0 / 60.0)
	finish(declare_input_tree)

	niello.frame_begin(niello.test_context(), unfocused, 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "hover works on an unfocused window")
	finish(declare_input_tree)

	press := unfocused
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	testing.expect(t, niello.pressed(input_btn_i), "press registers while unfocused")
	finish(declare_input_tree)

	rel := unfocused
	rel.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel, 1.0 / 60.0)
	testing.expect(t, niello.clicked(input_btn_i), "the focusing click activates")
	finish(declare_input_tree)
}

@(test)
test_input_cursor_through_label :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	// Over the label (which sets no cursor): the button's Pointer speaks
	// for the chain — the cursor must not drop to Arrow over the text.
	niello.frame_begin(niello.test_context(), idle_input(LBL_PT), 1.0 / 60.0)
	res := finish(declare_input_tree)
	testing.expect(t, res.cursor == .Pointer, "button cursor shows through its label")

	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_input_tree)
	testing.expect(t, res.cursor == .Pointer, "button cursor over the button body")

	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 1.0 / 60.0)
	res = finish(declare_input_tree)
	testing.expect(t, res.cursor == .Arrow, "arrow off the button")
}

@(test)
test_input_rounded_corners :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	in_btn_radius = 20
	mint_input_tree()
	defer in_btn_radius = 0

	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	// (2,30) is inside the button's rect but outside the bottom-left
	// corner arc (center (20,20), r 20: dist^2 = 18^2 + 10^2 = 424 > 400).
	miss := niello.Vec2{2, 30}
	niello.frame_begin(niello.test_context(), idle_input(miss), 1.0 / 60.0)
	testing.expect(t, !niello.hovered(input_btn_i), "rounded corner does not hit")
	testing.expect(t, niello.hovered(input_root_i), "the pick falls through to the root")
	finish(declare_input_tree)

	press := idle_input(miss)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	finish(declare_input_tree)
	rel := idle_input(miss)
	rel.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel, 1.0 / 60.0)
	testing.expect(t, !niello.clicked(input_btn_i), "no click from the corner cutout")
	finish(declare_input_tree)

	// (10,30) is inside the same corner's arc (dist^2 = 200 <= 400).
	hit := niello.Vec2{10, 30}
	niello.frame_begin(niello.test_context(), idle_input(hit), 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "inside the arc hits")
	finish(declare_input_tree)

	// Top edge midpoint: outside every corner square.
	niello.frame_begin(niello.test_context(), idle_input(niello.Vec2{60, 2}), 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "edge between corners hits")
	finish(declare_input_tree)
}

// ---- disabled absorbs: a disabled leaf stacked over a live button.

abs_root, abs_under, abs_dis: niello.Unit
abs_under_i, abs_dis_i: niello.Instance

declare_abs_tree :: proc() {
	if _, ok := niello.begin(abs_root); ok {
		abs_under_i = niello.show(abs_under)
		abs_dis_i = niello.show(abs_dis, 0, niello.With{disabled = true})
	}
}

@(test)
test_input_disabled_absorbs :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(
		&abs_root,
		niello.NO_UNIT,
		{
			layout = niello.Layout.Stack,
			size = niello.Size{niello.fixed(400), niello.fixed(300)},
		},
	)
	niello.mint(
		&abs_under,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(200), niello.fixed(60)}, color = [4]u8{0, 200, 0, 255}},
	)
	niello.mint(
		&abs_dis,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(200), niello.fixed(60)}, color = [4]u8{100, 100, 100, 255}},
	)

	pt := niello.Vec2{100, 30} // covered by both stacked leaves
	niello.frame_begin(niello.test_context(), idle_input(pt), 1.0 / 60.0)
	finish(declare_abs_tree)

	niello.frame_begin(niello.test_context(), idle_input(pt), 1.0 / 60.0)
	testing.expect(t, niello.hovered(abs_dis_i), "disabled instance is the pick (absorbs)")
	testing.expect(t, !niello.hovered(abs_under_i), "the covered button gets no hover")
	finish(declare_abs_tree)

	press := idle_input(pt)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	testing.expect(t, !niello.pressed(abs_dis_i), "disabled never presses")
	testing.expect(t, !niello.pressed(abs_under_i), "press does not fall through")
	finish(declare_abs_tree)

	rel := idle_input(pt)
	rel.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel, 1.0 / 60.0)
	testing.expect(t, !niello.clicked(abs_dis_i), "disabled never clicks")
	testing.expect(t, !niello.clicked(abs_under_i), "click does not fall through")
	finish(declare_abs_tree)
}

// ---- overlay precedence, observed through the emitted fill color.

ov_root, ov_btn, ov_hover, ov_press, ov_focus, ov_dis: niello.Unit
ov_btn_i: niello.Instance
ov_btn_disabled: bool

declare_ov_tree :: proc() {
	if _, ok := niello.begin(ov_root); ok {
		ov_btn_i = niello.show(ov_btn, 0, niello.With{disabled = ov_btn_disabled})
	}
}

rect_color :: proc(cmds: []niello.Draw_Cmd, want: niello.Rect) -> (niello.Color, bool) {
	for c in cmds {
		if c.tag == .Rect && c.bounds == want {
			return c.color, true
		}
	}
	return niello.Color{}, false
}

OV_BTN_RECT :: niello.Rect{{0, 0}, {120, 40}}

// ov_btn_color reads the button's emitted fill from the current draw list.
ov_btn_color :: proc() -> niello.Color {
	c, ok := rect_color(niello.draw_list(), OV_BTN_RECT)
	if !ok {
		return niello.Color{255, 0, 255, 255} // impossible: fails loudly
	}
	return c
}

@(test)
test_input_overlay_precedence :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(
		&ov_root,
		niello.NO_UNIT,
		{
			layout = niello.Layout.Top_To_Bottom,
			size = niello.Size{niello.fixed(400), niello.fixed(300)},
		},
	)
	niello.mint(&ov_hover, niello.NO_UNIT, {color = [4]u8{20, 0, 0, 255}})
	niello.mint(&ov_press, niello.NO_UNIT, {color = [4]u8{30, 0, 0, 255}})
	niello.mint(&ov_focus, niello.NO_UNIT, {color = [4]u8{40, 0, 0, 255}})
	niello.mint(&ov_dis, niello.NO_UNIT, {color = [4]u8{50, 0, 0, 255}})
	niello.mint(
		&ov_btn,
		niello.NO_UNIT,
		{
			size = niello.Size{niello.fixed(120), niello.fixed(40)},
			color = [4]u8{10, 10, 10, 255},
			cursor = niello.Cursor_Kind.Pointer,
			hover = ov_hover,
			press = ov_press,
			focus = ov_focus,
			disabled = ov_dis,
		},
	)
	ov_btn_disabled = false

	// Base: mouse away.
	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 1.0 / 60.0)
	res := finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{10, 10, 10, 255}, "base color")
	testing.expect(t, res.cursor == .Arrow, "no hover, arrow cursor")

	// Hover: hover overlay wins over base; cursor follows the hover target.
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{20, 0, 0, 255}, "hover color")
	testing.expect(t, res.cursor == .Pointer, "hovered button's cursor reported")

	// Press: press overlay wins over hover.
	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(niello.test_context(), press, 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{30, 0, 0, 255}, "press beats hover")
	rel := idle_input(BTN_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(niello.test_context(), rel, 1.0 / 60.0)
	finish(declare_ov_tree)

	// Focus alone (mouse away): focus overlay applies.
	niello.frame_begin(niello.test_context(), idle_input(AWAY_PT), 1.0 / 60.0)
	niello.focus(ov_btn_i)
	res = finish(declare_ov_tree)
	testing.expect(t, niello.focused(ov_btn_i), "programmatic focus lands")
	testing.expect(t, ov_btn_color() == [4]u8{40, 0, 0, 255}, "focus color")

	// Focus + hover: hover wins over focus.
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{20, 0, 0, 255}, "hover beats focus")

	// Disabled beats everything (and blocks the click state entirely).
	// Its Pointer base cursor is suppressed: the disabled overlay sets
	// no cursor, so the frame reports Arrow, not an invitation to click.
	ov_btn_disabled = true
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{50, 0, 0, 255}, "disabled beats hover+focus")
	testing.expect(t, res.cursor == .Arrow, "disabled target's base cursor is suppressed")
	ov_btn_disabled = false
}

// ---- a disabled overlay MAY name a cursor (e.g. Not_Allowed); only then
// does a disabled target report one.

dc_root, dc_btn, dc_dis: niello.Unit
dc_btn_i: niello.Instance

declare_dc_tree :: proc() {
	if _, ok := niello.begin(dc_root); ok {
		dc_btn_i = niello.show(dc_btn, 0, niello.With{disabled = true})
	}
}

@(test)
test_input_cursor_disabled_overlay :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(
		&dc_root,
		niello.NO_UNIT,
		{
			layout = niello.Layout.Top_To_Bottom,
			size = niello.Size{niello.fixed(400), niello.fixed(300)},
		},
	)
	niello.mint(
		&dc_dis,
		niello.NO_UNIT,
		{color = [4]u8{50, 0, 0, 255}, cursor = niello.Cursor_Kind.Not_Allowed},
	)
	niello.mint(
		&dc_btn,
		niello.NO_UNIT,
		{
			size = niello.Size{niello.fixed(120), niello.fixed(40)},
			color = [4]u8{10, 10, 10, 255},
			cursor = niello.Cursor_Kind.Pointer,
			disabled = dc_dis,
		},
	)

	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	finish(declare_dc_tree)
	niello.frame_begin(niello.test_context(), idle_input(BTN_PT), 1.0 / 60.0)
	res := finish(declare_dc_tree)
	testing.expect(
		t,
		res.cursor == .Not_Allowed,
		"disabled overlay's explicit cursor wins over the suppressed base",
	)
}
