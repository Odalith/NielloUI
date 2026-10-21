package tests

import niello ".."
import "core:testing"

// Scheduling (TODO #6, §3.3/§8): frame_end reports the nearest engine
// deadline as next_wake_ms; wake() flags the core and pokes the host
// hook. The registry is empty until tweens/transients/hover timers
// land, so a static UI sleeps at max(u32).

// sched_frame runs an empty declare: scheduling is declare-independent.
sched_frame :: proc(dt: f32) -> niello.Frame_Result {
	niello.frame_begin(niello.Input{viewport = {400, 300}}, dt)
	return niello.frame_end()
}

@(test)
test_sched_next_wake_infinite_by_default :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	res := sched_frame(0.05)
	testing.expect(t, res.next_wake_ms == max(u32),
		"no deadlines registered: next_wake is infinite")
	res = sched_frame(0.05)
	testing.expect(t, res.next_wake_ms == max(u32),
		"still infinite on later frames")
}

@(test)
test_sched_deadline_reports_and_fires :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sched_frame(0.05) // engine time 50ms
	niello.schedule_wake_in(100) // deadline at engine time 150ms
	res := sched_frame(0.05) // engine time 100ms
	testing.expect(t, res.next_wake_ms == 50,
		"nearest deadline reported relative to engine time")
	res = sched_frame(0.06) // engine time 160ms: past the deadline
	testing.expect(t, res.next_wake_ms == max(u32),
		"a due deadline fires with that frame and clears")
}

@(test)
test_sched_deadline_earliest_wins :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sched_frame(0.01) // engine time 10ms
	niello.schedule_wake_in(500)
	niello.schedule_wake_in(50) // deadline at 60ms beats the 510ms one
	res := sched_frame(0.01) // engine time 20ms
	testing.expect(t, res.next_wake_ms == 40, "the earlier deadline wins")
}

@(test)
test_sched_hover_duration_arms_refresh :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_input_tree()

	// Not hovered: asking for the duration arms nothing.
	niello.frame_begin(idle_input(AWAY_PT), 0.05)
	_ = niello.hover_duration(input_btn_i)
	res := finish(declare_input_tree)
	testing.expect(t, res.next_wake_ms == max(u32),
		"duration of an unhovered instance schedules nothing")

	// Hovered and displayed: the query arms the 50ms refresh, and it
	// re-arms on every frame the cursor stays parked.
	niello.frame_begin(idle_input(BTN_PT), 0.05)
	_ = niello.hover_duration(input_btn_i)
	res = finish(declare_input_tree)
	testing.expect(t, res.next_wake_ms == 50,
		"displayed hover duration schedules a refresh")
	niello.frame_begin(idle_input(BTN_PT), 0.05)
	_ = niello.hover_duration(input_btn_i)
	res = finish(declare_input_tree)
	testing.expect(t, res.next_wake_ms == 50,
		"the refresh re-arms while hovered")

	// Cursor leaves: back to sleeping at infinity.
	niello.frame_begin(idle_input(AWAY_PT), 0.05)
	_ = niello.hover_duration(input_btn_i)
	res = finish(declare_input_tree)
	testing.expect(t, res.next_wake_ms == max(u32),
		"hover left: the refresh disarms")
}

wake_hook_calls: int

counting_wake_hook :: proc() {
	wake_hook_calls += 1
}

@(test)
test_wake_hook :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	wake_hook_calls = 0
	niello.wake() // no hook installed: flags the core, must not crash
	niello.wake_hook = counting_wake_hook
	niello.wake()
	testing.expect(t, wake_hook_calls == 1, "wake() runs the host hook")
	niello.wake()
	testing.expect(t, wake_hook_calls == 2, "every wake() pokes the host")
	niello.wake_hook = nil
}
