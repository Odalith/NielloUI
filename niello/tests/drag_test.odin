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

// ---------------------------------------------------------------------------
// Capture loss (audit int-12), duplicate press edges (int-13), and
// the same-frame flick (int-14).

// frame_with runs one frame with a caller-chosen declare proc.

@(test)
test_capture_dies_with_target :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT)) // plain press, sub-threshold
	input_btn_hidden = true // the button leaves the tree
	frame(idle_input(BTN_PT))
	frame(release_at(BTN_PT))
	testing.expect(t, !niello.clicked(input_root_i),
		"a press whose target died completes no click — not even on the surviving ancestor")
	testing.expect(t, !niello.clicked(input_btn_i), "and none on the dead target")
}

@(test)
test_capture_dies_when_target_disabled :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	frame(hold_at(BTN_PT + {10, 0})) // drag is live
	testing.expect(t, niello.dragging(input_btn_i), "drag live before the disable")
	input_btn_disabled = true
	frame(hold_at(BTN_PT + {10, 0}))
	frame(release_at(BTN_PT + {10, 0}))
	testing.expect(t, niello.drag_ended(input_btn_i), "the drag ends")
	testing.expect(t, !niello.drag_completed(input_btn_i),
		"disabled mid-drag cancels the capture (ruled 2026-11-04), it does not complete it")
	testing.expect(t, !niello.clicked(input_btn_i), "no click either")
}

@(test)
test_capture_dies_when_target_culled :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	clip: niello.Unit
	niello.mint(&clip, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}, layout = .Top_To_Bottom, overflow = .Clip})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(30)}})

	clip_i, row2_i: niello.Instance
	declare_clip :: proc(clip, row: niello.Unit, clip_i, row2_i: ^niello.Instance) {
		if niello.begin(clip, out = clip_i) {
			niello.show(row, niello.key_int(1))
			if niello.begin(row, niello.key_int(2), out = row2_i) {
			}
		}
	}
	frame_clip :: proc(clip, row: niello.Unit, clip_i, row2_i: ^niello.Instance, input: niello.Input) {
		niello.frame_begin(niello.test_context(), input, 1.0 / 60.0)
		declare_clip(clip, row, clip_i, row2_i)
		niello.frame_end()
	}

	// Press the second row (y 30..60, center 45).
	frame_clip(clip, row, &clip_i, &row2_i, idle_input({10, 45}))
	frame_clip(clip, row, &clip_i, &row2_i, press_at({10, 45}))
	// Shrink the clip to 30: the second row falls fully outside.
	// One settle frame later it is culled (the culler reads last
	// rects); the press must die with it.
	niello.set(clip, .Size, niello.Size{niello.fixed(200), niello.fixed(30)})
	frame_clip(clip, row, &clip_i, &row2_i, hold_at({10, 45}))
	frame_clip(clip, row, &clip_i, &row2_i, hold_at({10, 45}))
	frame_clip(clip, row, &clip_i, &row2_i, release_at({10, 45}))
	testing.expect(t, !niello.clicked(clip_i),
		"a press whose target was culled mid-press completes no click on the container")
	testing.expect(t, !niello.clicked(row2_i), "and none on the culled row")
}

@(test)
test_duplicate_press_edge_cancels_first :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	frame(hold_at(BTN_PT + {10, 0}))
	testing.expect(t, niello.dragging(input_btn_i), "drag live on the button")

	// A second press edge lands on the root (away from the button).
	frame(press_at(AWAY_PT))
	testing.expect(t, niello.drag_ended(input_btn_i), "the first drag ends")
	testing.expect(t, !niello.drag_completed(input_btn_i), "as a cancellation")
	testing.expect(t, !niello.dragging(input_root_i),
		"the new capture does not inherit the old drag (no threshold crossing of its own)")

	frame(hold_at(AWAY_PT + {10, 0}))
	testing.expect(t, niello.dragging(input_root_i), "the new capture drags once IT crosses the threshold")
}

@(test)
test_drag_started_reports_same_frame_flick :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()
	frame(idle_input(BTN_PT))

	frame(press_at(BTN_PT))
	// One dispatch: move past the threshold AND release.
	frame(release_at(BTN_PT + {20, 0}))
	testing.expect(t, niello.drag_ended(input_btn_i), "the flick's drag ended")
	testing.expect(t, niello.drag_completed(input_btn_i), "by release")
	testing.expect(t, niello.drag_started(input_btn_i),
		"and its start still reports in the same declare (audit int-14)")
}

@(test)
test_capture_dies_when_modal_opens :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	bg: niello.Unit
	niello.mint(&bg, niello.NO_UNIT, {size = niello.Size{niello.fixed(120), niello.fixed(40)}})
	dialog: niello.Unit
	niello.mint(&dialog, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}, color = niello.Color{40, 40, 40, 255}})

	bg_i, anchor_i: niello.Instance
	declare_modal :: proc(root, bg, dialog: niello.Unit, bg_i, anchor_i: ^niello.Instance, modal: bool) {
		if niello.begin(root) {
			anchor_i^ = niello.show(bg, niello.key_int(1))
			bg_i^ = anchor_i^
		}
		if modal {
			niello.begin_popup(dialog, anchor_i^, .At, key = niello.key_int(9), opts = {modal = true, at = niello.Vec2{150, 120}})
		}
	}
	frame_modal :: proc(root, bg, dialog: niello.Unit, bg_i, anchor_i: ^niello.Instance, modal: bool, input: niello.Input) {
		niello.frame_begin(niello.test_context(), input, 1.0 / 60.0)
		declare_modal(root, bg, dialog, bg_i, anchor_i, modal)
		niello.frame_end()
	}

	BG_PT :: niello.Vec2{60, 20}
	frame_modal(root, bg, dialog, &bg_i, &anchor_i, false, idle_input(BG_PT))
	frame_modal(root, bg, dialog, &bg_i, &anchor_i, false, press_at(BG_PT))
	frame_modal(root, bg, dialog, &bg_i, &anchor_i, false, hold_at(BG_PT + {10, 0}))
	testing.expect(t, niello.dragging(bg_i), "drag live on the background button")
	// The modal opens over the capture; next dispatch the capture
	// is outside the modal's subtree and dies (ruled 2026-11-04).
	frame_modal(root, bg, dialog, &bg_i, &anchor_i, true, hold_at(BG_PT + {10, 0}))
	frame_modal(root, bg, dialog, &bg_i, &anchor_i, true, release_at(BG_PT + {10, 0}))
	testing.expect(t, niello.drag_ended(bg_i), "the drag ends")
	testing.expect(t, !niello.drag_completed(bg_i), "as a cancellation, not a completion")
	testing.expect(t, !niello.clicked(bg_i), "and no click lands behind the modal")
}
