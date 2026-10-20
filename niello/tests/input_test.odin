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
	mint_input_tree()

	// Frame 1 builds the tree (dispatch saw an empty one: nothing hovered).
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	// Frame 2: dispatch hit-tests frame 1's tree.
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "button hovered")
	testing.expect(t, niello.hovered(input_root_i), "hover bubbles to the root")
	testing.expect(t, !niello.hovered(input_lbl_i), "label not under the point")
	res := finish(declare_input_tree)
	testing.expect(t, res.changed, "hover change damages the frame")

	// Frame 3: same input, nothing changed — the clean fast path survives.
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_input_tree)
	testing.expect(t, !res.changed, "unchanged hover leaves the frame clean")

	// Frame 4: cursor moves off the button.
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	testing.expect(t, !niello.hovered(input_btn_i), "hover lost on move-off")
	testing.expect(t, niello.hovered(input_root_i), "root still hovered")
	finish(declare_input_tree)
}

@(test)
test_input_click :: proc(t: ^testing.T) {
	niello.test_reset()
	mint_input_tree()
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	// Press frame.
	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(press, 1.0 / 60.0)
	testing.expect(t, niello.pressed(input_btn_i), "pressed after the press edge")
	testing.expect(t, !niello.clicked(input_btn_i), "no click on press alone")
	finish(declare_input_tree)

	// Release frame: the click lands, for this one declare.
	rel := idle_input(BTN_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(rel, 1.0 / 60.0)
	testing.expect(t, niello.clicked(input_btn_i), "click completes on release")
	testing.expect(t, niello.clicked(input_root_i), "click bubbles to ancestors")
	testing.expect(t, !niello.pressed(input_btn_i), "press ends at release")
	finish(declare_input_tree)

	// Next frame: clicked is gone (one-declare lifetime).
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	testing.expect(t, !niello.clicked(input_btn_i), "clicked lasts exactly one frame")
	finish(declare_input_tree)
}

@(test)
test_input_click_bubbles_from_label :: proc(t: ^testing.T) {
	niello.test_reset()
	mint_input_tree()
	niello.frame_begin(idle_input(LBL_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	press := idle_input(LBL_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(press, 1.0 / 60.0)
	testing.expect(t, niello.pressed(input_lbl_i), "label is the press target")
	testing.expect(t, niello.pressed(input_btn_i), "press bubbles to the button")
	finish(declare_input_tree)

	rel := idle_input(LBL_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(rel, 1.0 / 60.0)
	testing.expect(t, niello.clicked(input_lbl_i), "label clicked")
	testing.expect(t, niello.clicked(input_btn_i), "button clicked via its label")
	finish(declare_input_tree)
}

@(test)
test_input_press_capture :: proc(t: ^testing.T) {
	niello.test_reset()
	mint_input_tree()
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(press, 1.0 / 60.0)
	finish(declare_input_tree)

	// Drag off while held: capture keeps pressed; hover follows the cursor.
	drag := idle_input(AWAY_PT)
	drag.buttons_down = {.Left}
	niello.frame_begin(drag, 1.0 / 60.0)
	testing.expect(t, niello.pressed(input_btn_i), "capture holds pressed off-target")
	testing.expect(t, !niello.hovered(input_btn_i), "hover follows the cursor, not the capture")
	finish(declare_input_tree)

	// Release off-target: no click.
	rel := idle_input(AWAY_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(rel, 1.0 / 60.0)
	testing.expect(t, !niello.clicked(input_btn_i), "release off-target cancels the click")
	testing.expect(t, !niello.pressed(input_btn_i), "capture ends at release")
	finish(declare_input_tree)

	// Press again, drag off, drag BACK on, release: the click completes.
	niello.frame_begin(press, 1.0 / 60.0)
	finish(declare_input_tree)
	niello.frame_begin(drag, 1.0 / 60.0)
	finish(declare_input_tree)
	back := idle_input(BTN_PT)
	back.buttons_down = {.Left}
	niello.frame_begin(back, 1.0 / 60.0)
	finish(declare_input_tree)
	rel2 := idle_input(BTN_PT)
	rel2.buttons_released = {.Left}
	niello.frame_begin(rel2, 1.0 / 60.0)
	testing.expect(t, niello.clicked(input_btn_i), "release back on target completes the click")
	finish(declare_input_tree)
}

@(test)
test_input_hover_duration :: proc(t: ^testing.T) {
	niello.test_reset()
	mint_input_tree()
	niello.frame_begin(idle_input(BTN_PT), 0.25)
	finish(declare_input_tree)

	niello.frame_begin(idle_input(BTN_PT), 0.25)
	testing.expect(t, niello.hover_duration(input_btn_i) == 0, "duration starts at 0 on entry")
	finish(declare_input_tree)

	niello.frame_begin(idle_input(BTN_PT), 0.25)
	d := niello.hover_duration(input_btn_i)
	testing.expect(t, d > 0.25 - EPS && d < 0.25 + EPS, "duration accumulates dt")
	testing.expect(t, niello.hover_duration(input_root_i) == 0, "ancestors don't share the duration")
	finish(declare_input_tree)

	niello.frame_begin(idle_input(BTN_PT), 0.25)
	d = niello.hover_duration(input_btn_i)
	testing.expect(t, d > 0.5 - EPS && d < 0.5 + EPS, "duration keeps accumulating")
	finish(declare_input_tree)

	niello.frame_begin(idle_input(AWAY_PT), 0.25)
	testing.expect(t, niello.hover_duration(input_btn_i) == 0, "duration resets on hover loss")
	finish(declare_input_tree)
}

@(test)
test_input_focus_loss_clears :: proc(t: ^testing.T) {
	niello.test_reset()
	mint_input_tree()
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	finish(declare_input_tree)

	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(press, 1.0 / 60.0)
	finish(declare_input_tree)

	// The window loses focus mid-press, with the release in the same frame:
	// everything clears and no click can complete.
	lost := idle_input(BTN_PT)
	lost.window_focused = false
	lost.buttons_released = {.Left}
	niello.frame_begin(lost, 1.0 / 60.0)
	testing.expect(t, !niello.pressed(input_btn_i), "focus loss clears pressed")
	testing.expect(t, !niello.hovered(input_btn_i), "focus loss clears hover")
	testing.expect(t, !niello.clicked(input_btn_i), "focus loss cancels the click")
	finish(declare_input_tree)

	// Focus returns: state does not resurrect.
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	testing.expect(t, niello.hovered(input_btn_i), "hover re-picks after focus returns")
	testing.expect(t, !niello.pressed(input_btn_i), "press stays cleared")
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
	niello.frame_begin(idle_input(pt), 1.0 / 60.0)
	finish(declare_abs_tree)

	niello.frame_begin(idle_input(pt), 1.0 / 60.0)
	testing.expect(t, niello.hovered(abs_dis_i), "disabled instance is the pick (absorbs)")
	testing.expect(t, !niello.hovered(abs_under_i), "the covered button gets no hover")
	finish(declare_abs_tree)

	press := idle_input(pt)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(press, 1.0 / 60.0)
	testing.expect(t, !niello.pressed(abs_dis_i), "disabled never presses")
	testing.expect(t, !niello.pressed(abs_under_i), "press does not fall through")
	finish(declare_abs_tree)

	rel := idle_input(pt)
	rel.buttons_released = {.Left}
	niello.frame_begin(rel, 1.0 / 60.0)
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
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	res := finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{10, 10, 10, 255}, "base color")
	testing.expect(t, res.cursor == .Arrow, "no hover, arrow cursor")

	// Hover: hover overlay wins over base; cursor follows the hover target.
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{20, 0, 0, 255}, "hover color")
	testing.expect(t, res.cursor == .Pointer, "hovered button's cursor reported")

	// Press: press overlay wins over hover.
	press := idle_input(BTN_PT)
	press.buttons_pressed = {.Left}
	press.buttons_down = {.Left}
	niello.frame_begin(press, 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{30, 0, 0, 255}, "press beats hover")
	rel := idle_input(BTN_PT)
	rel.buttons_released = {.Left}
	niello.frame_begin(rel, 1.0 / 60.0)
	finish(declare_ov_tree)

	// Focus alone (mouse away): focus overlay applies.
	niello.frame_begin(idle_input(AWAY_PT), 1.0 / 60.0)
	niello.focus(ov_btn_i)
	res = finish(declare_ov_tree)
	testing.expect(t, niello.focused(ov_btn_i), "programmatic focus lands")
	testing.expect(t, ov_btn_color() == [4]u8{40, 0, 0, 255}, "focus color")

	// Focus + hover: hover wins over focus.
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{20, 0, 0, 255}, "hover beats focus")

	// Disabled beats everything (and blocks the click state entirely).
	ov_btn_disabled = true
	niello.frame_begin(idle_input(BTN_PT), 1.0 / 60.0)
	res = finish(declare_ov_tree)
	testing.expect(t, ov_btn_color() == [4]u8{50, 0, 0, 255}, "disabled beats hover+focus")
	ov_btn_disabled = false
}
