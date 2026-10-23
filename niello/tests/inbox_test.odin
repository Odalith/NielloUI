// inbox_test.odin — the one-inbox satellite package (niello/inbox)
// and the core's public wake_in timer. The package tests pin the
// pattern's contract: sends wake the bound context, events are
// lossless FIFO, state updates coalesce by tag in place, and any
// number of producer threads may push concurrently.
package tests

import "core:sync"
import "core:thread"
import "core:testing"

import niello ".."
import inbox "../inbox"

@(test)
test_inbox_fifo_and_wake :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx := niello.test_context()
	ib := inbox.create(int, ctx)
	defer inbox.destroy(&ib)

	out: [dynamic]int
	defer delete(out)

	testing.expect(t, inbox.drain(&ib, &out) == 0, "empty inbox drains nothing")
	testing.expect(t, !niello.wake_pending(ctx), "no wake before any send")

	inbox.send(&ib, 1)
	inbox.send(&ib, 2)
	inbox.send(&ib, 3)
	testing.expect(t, inbox.pending(&ib) == 3, "three events queued")
	testing.expect(t, niello.wake_pending(ctx), "send wakes the bound context")

	n := inbox.drain(&ib, &out)
	testing.expect(t, n == 3 && len(out) == 3, "drain moves all three")
	testing.expect(t, out[0] == 1 && out[1] == 2 && out[2] == 3, "events are FIFO")
	testing.expect(t, inbox.pending(&ib) == 0, "drain empties the inbox")
	testing.expect(t, inbox.drain(&ib, &out) == 0, "a second drain finds nothing")

	// The wake the sends raised is consumed by the next frame_begin.
	niello.frame_begin(ctx, niello.Input{viewport = {100, 100}}, 0.016)
	niello.frame_end()
	testing.expect(t, !niello.wake_pending(ctx), "the frame consumed the wake")
}

@(test)
test_inbox_coalescing :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ib := inbox.create(int, niello.test_context())
	defer inbox.destroy(&ib)
	out: [dynamic]int
	defer delete(out)

	inbox.send(&ib, 10)              // event
	inbox.send_latest(&ib, 7, 50)    // progress, first
	inbox.send(&ib, 20)              // event
	inbox.send_latest(&ib, 7, 51)    // progress, newer — replaces in place
	inbox.send_latest(&ib, 9, 60)    // a different tag — appends
	testing.expect(t, inbox.pending(&ib) == 4, "the replaced update queued nothing new")

	n := inbox.drain(&ib, &out)
	testing.expect(t, n == 4, "four messages delivered")
	// In-place replacement keeps the first update's position: the
	// event that arrived after it (20) still drains after it.
	testing.expect(t, out[0] == 10 && out[1] == 51 && out[2] == 20 && out[3] == 60,
		"latest value, original position, events untouched")
}

Ib_Job :: struct {
	box:  ^inbox.Inbox(int),
	base: int,
	wg:   ^sync.Wait_Group,
}

ib_worker :: proc(data: rawptr) {
	job := cast(^Ib_Job)data
	for _ in 0 ..< 250 {
		inbox.send(job.box, job.base)
	}
	sync.wait_group_done(job.wg)
}

@(test)
test_inbox_multithread :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ib := inbox.create(int, niello.test_context())
	defer inbox.destroy(&ib)
	out: [dynamic]int
	defer delete(out)

	wg: sync.Wait_Group
	jobs: [4]Ib_Job
	sync.wait_group_add(&wg, 4)
	for i in 0 ..< 4 {
		jobs[i] = Ib_Job{box = &ib, base = i, wg = &wg}
		thread.create_and_start_with_data(&jobs[i], ib_worker)
	}
	sync.wait_group_wait(&wg)

	testing.expect(t, inbox.pending(&ib) == 1000, "no message lost across four producers")
	n := inbox.drain(&ib, &out)
	sum := 0
	for v in out {
		sum += v
	}
	testing.expect(t, n == 1000 && sum == 250 * (0 + 1 + 2 + 3),
		"every producer's messages arrived exactly once")
}

// The app shape: a closed union, applied by one exhaustive switch.
Ib_Progress :: struct {
	pct: int,
}
Ib_Done :: struct {
	count: int,
}
Ib_Msg :: union {
	Ib_Progress,
	Ib_Done,
}

@(test)
test_inbox_union_drain :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ib := inbox.create(Ib_Msg, niello.test_context())
	defer inbox.destroy(&ib)
	out: [dynamic]Ib_Msg
	defer delete(out)

	inbox.send_latest(&ib, 1, Ib_Msg(Ib_Progress{pct = 10}))
	inbox.send_latest(&ib, 1, Ib_Msg(Ib_Progress{pct = 90}))
	inbox.send(&ib, Ib_Msg(Ib_Done{count = 42}))
	inbox.drain(&ib, &out)

	progress_seen, done_seen := -1, -1
	for m in out {
		switch v in m {
		case Ib_Progress:
			progress_seen = v.pct
		case Ib_Done:
			done_seen = v.count
		}
	}
	testing.expect(t, len(out) == 2, "coalesced progress + the event")
	testing.expect(t, progress_seen == 90, "only the newest progress applies")
	testing.expect(t, done_seen == 42, "the event applies")
}

// ---- wake_in ---------------------------------------------------------------

wk_root: niello.Unit
wk_arm: bool

declare_wk_tree :: proc() {
	if wk_arm {
		niello.wake_in(200)
	}
	niello.show(wk_root)
}

wk_frame :: proc() -> niello.Frame_Result {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {200, 100}}, 0.016)
	declare_wk_tree()
	return niello.frame_end()
}

@(test)
test_wake_in_deadline :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&wk_root, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.fixed(50)}})

	wk_arm = false
	wk_frame()
	res := wk_frame()
	testing.expect(t, res.next_wake_ms == max(u32), "a static UI has no deadline")

	wk_arm = true
	res = wk_frame()
	testing.expect(t, res.next_wake_ms > 0 && res.next_wake_ms <= 200,
		"wake_in registers a deadline frame_end reports")
	res = wk_frame()
	testing.expect(t, res.next_wake_ms > 0 && res.next_wake_ms <= 200,
		"re-arming each frame keeps the deadline, never extends past the ask")

	wk_arm = false
	for _ in 0 ..< 20 { // 20 x 16 ms of engine time: the 200 ms deadline passes
		res = wk_frame()
	}
	testing.expect(t, res.next_wake_ms == max(u32),
		"an un-re-armed deadline fires once and is gone")
}
