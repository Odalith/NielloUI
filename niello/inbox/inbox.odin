// inbox — the one-inbox pattern (Async_Inbox_Design.md) as a Niello
// satellite package, the debugui precedent: opt-in, beside the core,
// useless without it and invisible to apps that don't import it.
//
// The pattern, in one paragraph: every stimulus that didn't come
// from the OS arrives as a message in ONE app-owned queue. Worker
// threads, file watchers, audio callbacks, OS media hooks — they all
// do exactly two things: push a message, and the push wakes the
// bound context (send IS push + context_wake; the pairing cannot be
// forgotten because it cannot be separated). Once per frame, before
// declare, the app drains the queue and applies the messages to its
// model; declare then projects one settled snapshot. Messages are a
// closed union in the app's own type, handled by one exhaustive
// switch at the drain — no subscribers, no weak references, no
// reentrant handlers, nothing delivered late or lost silently.
//
// Two message classes:
//   - events (send): lossless, FIFO, every one delivered.
//   - state updates (send_latest): latest-wins per tag. A pending
//     update whose tag matches is replaced IN PLACE (its queue
//     position is kept) — a producer may flood progress reports and
//     the drain still sees only the newest, behind everything that
//     arrived before the first one. Backpressure by construction.
//
// Threading contract: send/send_latest/pending are safe from any
// thread. drain is frame-thread work (it is locked anyway). The
// Inbox owns a mutex: create it once, never copy it after first use,
// destroy it before its context dies.
package inbox

import "core:sync"

import niello ".."

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
