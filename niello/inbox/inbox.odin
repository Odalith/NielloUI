// Package inbox carries work done off the UI thread back to it: one queue
// of the app's own messages per context. Workers (threads, file watchers,
// audio callbacks) send messages; each send wakes the context, and once per
// frame, before declaring, the app drains the queue and applies them to its
// state. Declare then sees one settled state; nothing arrives mid-frame and
// nothing is lost.
//
//	Msg :: union { Progress, Done }
//	box := inbox.create(Msg, ctx)            // once, with the window's context
//	inbox.send(&box, Done{})                  // from any thread
//	inbox.send_latest(&box, 1, Progress{50})  // only the newest per tag is kept
//	for m in inbox.drain(&box) { … }          // each frame, before declaring
//
// send delivers every message, in order. send_latest keeps only the newest
// pending message of a tag (in the first one's place), so a producer can
// report progress as fast as it likes. send, send_latest and pending are
// safe from any thread; drain belongs to the UI thread. Create an inbox
// once, do not copy it, and destroy it before its context.
package inbox

import "core:sync"

import niello ".."

// Inbox is one context's message queue of the app's message type M (see the
// package doc). Create it with create; it holds a mutex, so never copy it.
Inbox :: struct($M: typeid) {
	ctx:  ^niello.Context,
	mu:   sync.Mutex,
	q:    [dynamic]M,
	tags: [dynamic]u64, // parallel to q: 0 = event, nonzero = the
	                    // coalescing tag a send_latest replaces by
}

// create binds an empty inbox to the context its sends will wake.
create :: proc($M: typeid, ctx: ^niello.Context) -> Inbox(M) {
	return Inbox(M){ctx = ctx}
}

// destroy frees the queues. Pending messages are dropped with them;
// their payloads are the app's to free first, if they own any.
destroy :: proc(ib: ^Inbox($M)) {
	delete(ib.q)
	delete(ib.tags)
	ib^ = {}
}

// send queues an event (lossless, FIFO) and wakes the bound context.
send :: proc(ib: ^Inbox($M), m: M) {
	sync.lock(&ib.mu)
	append(&ib.q, m)
	append(&ib.tags, 0)
	sync.unlock(&ib.mu)
	niello.context_wake(ib.ctx)
}

// send_latest queues a state update under a nonzero tag: if an
// undrained update with the same tag is pending, it is replaced in
// place and no new entry is queued. Wakes the bound context either
// way — a replaced value is still news the frame hasn't seen.
send_latest :: proc(ib: ^Inbox($M), tag: u64, m: M) {
	assert(tag != 0, "inbox: send_latest needs a nonzero tag (tag 0 is the event class)")
	sync.lock(&ib.mu)
	replaced := false
	for i in 0 ..< len(ib.q) {
		if ib.tags[i] == tag {
			ib.q[i] = m
			replaced = true
			break
		}
	}
	if !replaced {
		append(&ib.q, m)
		append(&ib.tags, tag)
	}
	sync.unlock(&ib.mu)
	niello.context_wake(ib.ctx)
}

// drain moves every pending message, in queue order, into out
// (appended — pass a cleared scratch) and empties the inbox. It
// returns how many messages it moved. Frame-thread work: call it
// once per frame, before declare, and apply what it returns to the
// model — that drain point is the pattern's whole consistency
// story, so there is deliberately no per-message callback form.
drain :: proc(ib: ^Inbox($M), out: ^[dynamic]M) -> int {
	sync.lock(&ib.mu)
	n := len(ib.q)
	if n > 0 {
		append(out, ..ib.q[:])
		clear(&ib.q)
		clear(&ib.tags)
	}
	sync.unlock(&ib.mu)
	return n
}

// pending reports how many messages are waiting. A peek for tests
// and debug overlays; the drain is how frames consume.
pending :: proc(ib: ^Inbox($M)) -> int {
	sync.lock(&ib.mu)
	defer sync.unlock(&ib.mu)
	return len(ib.q)
}
