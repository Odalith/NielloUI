// Headless tests for the drag query (§3.28, TODO #27). Same harness
// as input_test.odin: root 400x300, button 120x40 at (0,0), label
// inside it. BTN_PT = {60,20} is the grab point in most tests, so
// displacements below are exact.
package tests

import niello ".."
import "core:testing"

frame :: proc(input: niello.Input) {
	niello.frame_begin(niello.test_context(), input, 1.0 / 60.0)
	finish(declare_input_tree)
}

press_at :: proc(pt: niello.Vec2) -> niello.Input {
	inp := idle_input(pt)
	inp.buttons_pressed = {.Left}
	inp.buttons_down = {.Left}
	return inp
}

hold_at :: proc(pt: niello.Vec2) -> niello.Input {
	inp := idle_input(pt)
	inp.buttons_down = {.Left}
	return inp
}

release_at :: proc(pt: niello.Vec2) -> niello.Input {
	inp := idle_input(pt)
	inp.buttons_released = {.Left}
	return inp
}

@(test)
test_drag_below_threshold_clicks :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	// A 2+2 DIP move: under the 4 DIP threshold — no drag starts.
	frame(hold_at(BTN_PT + {2, 2}))
	testing.expect(t, !niello.dragging(input_btn_i), "sub-threshold move is not a drag")
	testing.expect(t, !niello.drag_started(input_btn_i), "no start edge below threshold")
	testing.expect(t, niello.drag_total() == niello.Vec2{}, "total gated on an active drag")
	frame(release_at(BTN_PT + {2, 2}))
	testing.expect(t, niello.clicked(input_btn_i), "sub-threshold press still clicks")
	testing.expect(t, !niello.drag_ended(input_btn_i), "no drag, no drag end")
}

@(test)
test_drag_lifecycle :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	testing.expect(t, niello.drag_pos(input_btn_i) == BTN_PT, "drag_pos is pointer relative to the rect")

	// Cross the threshold in one move: 10 DIP right.
	frame(hold_at(BTN_PT + {10, 0}))
	testing.expect(t, niello.drag_started(input_btn_i), "start edge on the crossing frame")
	testing.expect(t, niello.dragging(input_btn_i), "drag active")
	testing.expect(t, niello.drag_total() == niello.Vec2{10, 0}, "total is displacement from the grab")
	testing.expect(t, niello.drag_delta() == niello.Vec2{10, 0}, "delta is the frame's movement")

	// Next frame: started edge is gone, drag persists, delta tracks.
	frame(hold_at(BTN_PT + {16, 4}))
	testing.expect(t, !niello.drag_started(input_btn_i), "start edge lasts one declare")
	testing.expect(t, niello.dragging(input_btn_i), "still dragging")
	testing.expect(t, niello.drag_total() == niello.Vec2{16, 4}, "total accumulates from the grab")
	testing.expect(t, niello.drag_delta() == niello.Vec2{6, 4}, "delta is per-frame")

	// Release off-target: drag ends completed, no click anywhere
	// (the click rule still needs release over the target).
	frame(release_at(AWAY_PT))
	testing.expect(t, niello.drag_ended(input_btn_i), "end edge on release")
	testing.expect(t, niello.drag_completed(input_btn_i), "release completes the drag")
	testing.expect(t, !niello.clicked(input_btn_i), "release off-target clicks nothing")
	testing.expect(t, niello.drag_total() == AWAY_PT - BTN_PT, "final total survives the end frame")
	testing.expect(t, !niello.dragging(input_btn_i), "drag over")

	// End edge lasts exactly one declare.
	frame(idle_input(AWAY_PT))
	testing.expect(t, !niello.drag_ended(input_btn_i), "end edge lasts one declare")
	testing.expect(t, niello.drag_total() == niello.Vec2{}, "total clears after the end declare")
}

@(test)
test_drag_off_back_release_clicks :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	// Press, cross the threshold, drag back on target, release:
	// orthogonal (2026-10-24, supersedes F1) — the drag completes
	// AND the click fires. Both queries are true on the release
	// declare.
	frame(press_at(BTN_PT))
	frame(hold_at(BTN_PT + {10, 0}))
	testing.expect(t, niello.dragging(input_btn_i), "drag active after crossing")
	frame(hold_at(BTN_PT))
	testing.expect(t, niello.dragging(input_btn_i), "drag still active back on target")
	frame(release_at(BTN_PT))
	testing.expect(t, niello.drag_ended(input_btn_i), "release ends the drag")
	testing.expect(t, niello.drag_completed(input_btn_i), "release completes the drag")
	testing.expect(t, niello.clicked(input_btn_i), "drag off-and-back release over target clicks")
}

@(test)
test_drag_bubbles_and_subtracts :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(LBL_PT))

	// Press lands on the LABEL; the drag belongs to the label and
	// bubbles to the button and the root (F4).
	frame(press_at(LBL_PT))
	frame(hold_at(LBL_PT + {20, 0}))
	testing.expect(t, niello.dragging(input_lbl_i), "the target drags")
	testing.expect(t, niello.dragging(input_btn_i), "drag bubbles to the button")
	testing.expect(t, niello.dragging(input_root_i), "drag bubbles to the root")
	// The F4 subtraction idiom: the root claims it only when no
	// descendant does.
	claimed_by_root := niello.dragging(input_root_i) && !niello.dragging(input_btn_i)
	testing.expect(t, !claimed_by_root, "subtraction disclaims the root while the button drags")
	frame(release_at(LBL_PT + {20, 0}))
}

@(test)
test_drag_cancelled_by_focus_loss :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	frame(hold_at(BTN_PT + {10, 0}))
	testing.expect(t, niello.dragging(input_btn_i), "dragging before the loss")

	lost := hold_at(BTN_PT + {10, 0})
	lost.window_focused = false
	frame(lost)
	testing.expect(t, niello.drag_ended(input_btn_i), "focus loss ends the drag")
	testing.expect(t, !niello.drag_completed(input_btn_i), "focus loss cancels, not completes")
	testing.expect(t, !niello.dragging(input_btn_i), "no drag after the loss")

	// The matching release afterwards completes nothing.
	back := release_at(BTN_PT + {10, 0})
	frame(back)
	testing.expect(t, !niello.clicked(input_btn_i), "no click across a focus loss")
	testing.expect(t, !niello.drag_ended(input_btn_i), "no second end")
}

@(test)
test_drag_cancelled_by_cursor_departure :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	frame(hold_at(BTN_PT + {10, 0}))
	testing.expect(t, niello.dragging(input_btn_i), "dragging before departure")

	gone := niello.Input{viewport = {400, 300}, mouse_valid = false, window_focused = true}
	frame(gone)
	testing.expect(t, niello.drag_ended(input_btn_i), "cursor departure ends the drag")
	testing.expect(t, !niello.drag_completed(input_btn_i), "departure cancels")
}

@(test)
test_drag_second_press_starts_clean :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	frame(hold_at(BTN_PT + {30, 0}))
	frame(release_at(BTN_PT + {30, 0}))
	testing.expect(t, niello.drag_ended(input_btn_i), "first drag ended")

	// A fresh press grabs at the new point; totals restart from it.
	frame(press_at(AWAY_PT))
	frame(hold_at(AWAY_PT + {5, 0}))
	testing.expect(t, niello.dragging(input_root_i), "second drag active on the root")
	testing.expect(t, !niello.dragging(input_btn_i), "second drag is not the button's")
	testing.expect(t, niello.drag_total() == niello.Vec2{5, 0}, "total restarts from the new grab")
	frame(release_at(AWAY_PT + {5, 0}))
}
