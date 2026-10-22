// state.odin — cold unit store and package-global frame state.
// The real engine would thread a context; the mock keeps one global (tests reset it).
//
// The public mutation path (mint/set/set_many) lives in public.odin; this file
// holds the stores it writes to. The struct-of-structs here stands in for the
// §8 struct-of-arrays layout — a mechanical perf pass once the API settles.
package niello

import "base:runtime"

Unit_Rec :: struct {
	style: Style, // resolved, owned values

	// §8 cold-store metadata.
	explicit: Fields, // fields set directly at mint (for propagate)
	proto:    Unit,   // prototype unit, NO_UNIT if none
	pinned:   Fields, // fields protected from group writes (pin)
	dirty:    Fields, // fields written since last frame_end

	// Warm: read when resolving interaction state (overlays not yet applied —
	// the mock has no input/rendering passes yet; the data is retained).
	hover, press, focus, disabled: Unit,
	focusable: bool,
	groups:    []Group,

	// Cold: debug/inspector only.
	name: string,
	loc:  runtime.Source_Code_Location,
}

// Group_Member is one (unit, field-mask) pair: the mask scopes which
// fields a broadcast may write on this member (§3.7).
Group_Member :: struct {
	unit:   Unit,
	fields: Fields,
}

// Group_Rec is the group's whole state — an address book (§3.7). There
// is deliberately no retained patch: joining applies nothing, and a
// broadcast reaches only the members present when it is issued.
Group_Rec :: struct {
	members: [dynamic]Group_Member,
	name:    string, // debug/inspector only
}

// Store is the process-global half of the engine state (multi-window
// plan, M1): the cold store every window shares. Units are minted
// once, globally; groups are global; a style write lands here once
// and every Context picks it up on its next frame — a broadcast
// with no per-context copies and no surprises.
Store :: struct {
	// Cold store: units own their style values. Survives across frames.
	// Index 0 is the NO_UNIT sentinel (§8).
	units:  [dynamic]Unit_Rec,
	groups: [dynamic]Group_Rec,

	// Change tracking (§8): a global generation bumped by every
	// set/set_many, per-unit dirty bitsets, and the write JOURNAL:
	// every unit dirtied since the last journal GC, in order. Each
	// Context consumes the journal from its own cursor at frame_end;
	// a unit's dirty bitset clears only once EVERY live context has
	// consumed its entry (journal_gc) — so a slow window never loses
	// a change notice to a fast one. (Was `touched`, one global
	// list cleared by the only frame_end there was.)
	gen:     u64,
	journal: [dynamic]Unit,

	// Live contexts, in creation order: the journal GC reads their
	// cursors, and tween() cancels a unit's tweens across all of
	// them (animate.odin).
	contexts: [dynamic]^Context,

	// The word cache is content-addressed (font, style, text ->
	// metrics), so it is shared by every window: a word measured
	// for one window is a free hit for all the others.
	text_cache:       map[u64]Text_Entry,
	ellipsis_widths: map[u64]f32,
}

// Context is one window's frame state (multi-window plan, M1):
// everything a single tree's frames own — nodes, instances,
// interaction, scheduling, mutation — and nothing they share. The
// package handle `g` (below) points at the currently bound
// context; frame_begin binds, declare-time procs read the binding.
Context :: struct {
	// This context's position in the store's write journal: every
	// entry below the cursor has been consumed by a frame_end here.
	journal_cursor: int,

	// Frame text arena: With.text copies land here at declare time.
	// Chunked so a slice, once taken, never moves; rewound at
	// frame_begin and reused across frames (freed only at teardown).
	text_chunks:  [dynamic][]u8,
	text_chunk:   int,
	text_off:     int,
	// The same arena idea for span slices (declare.odin's
	// copy_frame_spans): chunked so slices never move, rewound at
	// frame_begin. Was one heap copy per span node per frame, freed
	// at the NEXT frame_begin — the same churn class as emit's.
	spans_chunks: [dynamic][]Text_Span,
	spans_chunk:  int,
	spans_off:    int,

	// Emit scratch (render.odin): shared by every text node and
	// every draw_list call, cleared per use. emit_text used to make
	// + delete two arrays PER TEXT NODE PER CALL — 2 allocations
	// per text node per frame, the engine's largest churn (2026-10-21
	// perf analysis, finding 1).
	emit_breaks: [dynamic][2]int,
	emit_runs:   [dynamic]Text_Run,
	emit_scopes: [dynamic]int,

	// Frame store: flat parent-before-child node array, rebuilt every frame.
	nodes:        [dynamic]Frame_Node,
	stack:        [dynamic]int, // open container node indices
	child_counts: [dynamic]int, // children declared so far, per open container

	// Frame inputs, latched at frame_begin.
	viewport: Vec2,
	dt:       f32,
	pointer_pos:   Vec2, // last dispatch's cursor position (§3.19:
	pointer_valid: bool, // mouse_position's source; At placement
	                     // needs it for context menus)

	// Layout scratch (parallel to nodes).
	lay:          [dynamic]Lay,
	first_child:  [dynamic]int,
	next_sibling: [dynamic]int,
	wrap_list:    [dynamic]int,
	subtree_end:  [dynamic]int,

	// Reusable scratch buffers (Clay-style): per-frame temporaries that must
	// never touch the allocator in steady state.
	scratch_a:    [dynamic]int, // waterfill growers
	scratch_b:    [dynamic]int, // waterfill shrinkables
	scratch_ints: [dynamic]int, // build_child_lists' last_child

	// Render command stream (render.odin): emitted by draw_list() after
	// frame_end, valid until the next frame_begin.
	draw_cmds: [dynamic]Draw_Cmd,

	// Persistent instance store: identity -> last committed record.
	// The content hash rides in the same map value: pass F used to do
	// TWO map ops per node per frame (rect map + hash map), and the
	// second op was the input pass's single biggest cost — one op now.
	instances: map[Instance]Inst_Rec,
	damage:    [dynamic]Rect,

	// Scroll offsets by identity: written by wheel dispatch at
	// frame_begin and by scroll_to, read and re-clamped by pass F every
	// frame (the stored value is the offset the last frame rendered
	// with). Only scrollable containers ever get an entry; absence = 0.
	scroll_off: map[Instance]Vec2,
	// Scroll ranges by identity: the max offset per axis, written by
	// pass F from the fresh overflow every frame. Dispatch and pass F
	// clamp against this — g.lay is zeroed by pass 0 each frame, so the
	// range needs a persistent home of its own.
	scroll_max: map[Instance]Vec2,
	// Wheel glides in flight (§3.21): from/to offsets, elapsed ms,
	// duration. Stepped at frame_end before layout; scroll_to and a
	// fresh wheel tick rewrite the entry. Absence = not gliding.
	scroll_glides: map[Instance]Scroll_Glide,

	// Interaction state (input.odin): written by dispatch at frame_begin,
	// read by the queries during declare and by overlay resolution at
	// frame_end. Chains are identity snapshots, root first: an instance is
	// "in" a chain when it is the target or one of its ancestors, which is
	// what gives clicked/hovered their bubble-up semantics.
	hover_id:      Instance, // pick target under the cursor; 0 = none
	hover_chain:   [dynamic]Instance,
	hover_clock:   f32, // total dispatch time; durations read against it
	hover_since:   map[Instance]f32, // per-member chain entry time: an
	                                  // instance's hover duration is
	                                  // hover_clock - hover_since[id], and
	                                  // the entry dies when it leaves the
	                                  // chain (input.odin maintains both)
	press_ids:     [Mouse_Button]Instance, // press capture per button; 0 = none
	press_chains:  [Mouse_Button][dynamic]Instance,
	clicked_id:    Instance, // set at a release dispatch, valid for one declare
	clicked_chain: [dynamic]Instance,
	focus_id:      Instance, // keyboard focus (§3.17): traversal, click,
	                         // or programmatic; input_keys/input_text
	                         // route to it
	key_press_id:    Instance, // Space/Enter capture on the focused
	                         // instance between key-down and key-up
	key_press_code:  u32,
	key_press_chain: [dynamic]Instance, // root-first chain snapshot,
	                         // like the pointer press chains
	frame_keys:      [16]Key_Event, // this frame's key events,
	                         // snapshotted at dispatch
	frame_key_count: int,
	key_consumed:    [16]bool, // per slot: the core ate this event
	                         // (traversal's Tab is never delivered)
	keys_target:     Instance, // routing frozen at dispatch: the
	text_target:     Instance, // queries answer for these only
	frame_text:      [dynamic]u8, // this frame's committed text (owned)
	keys_scratch:    [dynamic]Key_Event, // input_keys result assembly
	seen_ids:        map[Instance]bool, // recycle sweep's live set
	                         // (pass F); built only on frames where
	                         // something died
	dead_ids:        [dynamic]Instance, // recycle sweep scratch
	// Popups (§3.19): the frame's popup roots in begin_popup call
	// order (later = higher). Dispatch at frame_begin reads LAST
	// frame's list (cleared after dispatch); frame_end reads this
	// frame's for the modal focus bookkeeping.
	popups:          [dynamic]Popup_Rec,
	popup_ordinal:   int, // per-frame counter: the Key-0 ordinal
	                         // fallback for popup roots
	dismiss_flags:   map[Instance]bool, // popups whose dismissal was
	                         // requested at this frame's dispatch;
	                         // valid for one declare (dismiss_requested)
	modal_prev_id:   Instance, // last frame_end's topmost modal
	                         // popup root; 0 = no modal session
	modal_saved_focus: Instance, // focus held when the modal
	                         // session opened; restored when it ends
	prev_focused:  bool, // last frame's window_focused; the falling edge
	                     // drops press capture (input.odin)
	input_dirty:   bool,     // interaction state changed this frame
	// Scheduling (§3.3): engine time accumulates frame_begin's dt;
	// deadlines are engine-time stamps, the nearest one wins.
	time_ms:           u64,
	wake_deadline:     u64,
	wake_deadline_set: bool,
	// Set by context_wake() from any thread (atomic access only), consumed at
	// frame_begin.
	wake_requested: bool,

	// Mutation layer (§3.16, animate.odin): active unit tweens (stepped
	// at frame_end), per-instance transient pulses (read by
	// resolve_styles, swept at frame_end), and pending edit shadows
	// (diffed and applied at frame_end, then freed). Edit states are
	// heap-allocated: edit() hands out a pointer into the shadow, and
	// it must stay valid until frame_end however many units are edited.
	tweens:     [dynamic]Tween,
	transients: map[Instance]Transient_Rec,
	edits:      map[Unit]^Edit_State,
	affected:      [dynamic]Instance, // instances whose resolved style may have
	                                  // changed; frame_end damages their rects

	// Per-node side arrays, parallel to nodes. pick_clip is the accumulated
	// ancestor clip pass F computes; the NEXT frame's pick reads it (with
	// nodes/lay) before frame_begin clears them. eff holds resolved styles
	// for nodes with interaction state or a variant; disabled_flags carries
	// the ancestor-propagated disabled bit from the same resolution pass.
	pick_clip:      [dynamic]Rect,
	eff:            [dynamic]Style,
	disabled_flags: [dynamic]bool,

	layout_gen:  u32,
	frame_index: u64,

	// Test-only hook: force the next begin() to report open=false.
	test_force_cull: bool,
}

@(private)
store: Store

// g is the currently bound context (multi-window plan, M1). It is a
// POINTER on purpose: Odin auto-dereferences field access through
// it, so the ~700 `g.` sites in the package read exactly as they
// did when g was the one global struct — only the declaration and
// the lifecycle changed. nil until a context is bound; frame_begin
// binds, context_destroy unbinds itself.
g: ^Context

// test_ctx is the harness's context: test_reset creates and binds
// a fresh one per test, test_teardown destroys it.
test_ctx: ^Context

// test_reset clears everything, including cold units, and re-seeds
// the NO_UNIT sentinel: each test starts from a working empty engine.
// test_teardown is its exit-side pair: it frees the same containers but
// leaves NO sentinel behind, so a test ends with zero engine allocations
// live. Tests open with test_reset() and defer test_teardown(). The
// pairing is what keeps the runner's per-test tracking allocator honest:
// engine state is global by design, so without it the NEXT test's reset
// frees this test's allocations under the wrong tracker and they report
// as leaks (still live at test end) and bad frees (freed by a tracker
// that never allocated them).
test_reset :: proc() {
	if test_ctx != nil {
		context_destroy(test_ctx)
		test_ctx = nil
	}
	free_store()
	store = Store{}
	test_ctx = context_create()
	g = test_ctx
	append(&store.units, Unit_Rec{name = "NO_UNIT"}) // §8 sentinel at index 0
	append(&store.groups, Group_Rec{name = "NO_GROUP"})
}

test_teardown :: proc() {
	if test_ctx != nil {
		context_destroy(test_ctx)
		test_ctx = nil
	}
	free_store()
	store = Store{}
	g = nil
}

// free_store deletes every heap-owning container in the global store.
@(private)
free_store :: proc() {
	// Free the text cache first (each Text_Entry owns segs -> words -> frags).
	for _, entry in store.text_cache {
		for seg in entry.segs {
			for word in seg.words {
				delete(word.frags)
			}
			delete(seg.words)
		}
		delete(entry.segs)
	}
	delete(store.text_cache)
	delete(store.ellipsis_widths)
	// Unit styles own their reference-typed fields (cloned on write —
	// see store_spans in public.odin).
	for &rec in store.units {
		if rec.style.text_spans != nil {
			delete(rec.style.text_spans)
		}
		if len(rec.style.text) > 0 {
			delete(rec.style.text)
		}
	}
	delete(store.units)
	for &gr in store.groups {
		delete(gr.members)
	}
	delete(store.groups)
	delete(store.journal)
	delete(store.contexts)
}

// free_context deletes every heap-owning container in one context.
// (A context's frame nodes' span slices point into its spans arena —
// freed with the chunks, never per node.)
@(private)
free_context :: proc(ctx: ^Context) {
	for chunk in ctx.text_chunks {
		delete(chunk)
	}
	delete(ctx.text_chunks)
	for chunk in ctx.spans_chunks {
		delete(chunk)
	}
	delete(ctx.spans_chunks)
	delete(ctx.emit_breaks)
	delete(ctx.emit_runs)
	delete(ctx.emit_scopes)
	delete(ctx.nodes)
	delete(ctx.stack)
	delete(ctx.child_counts)
	delete(ctx.lay)
	delete(ctx.first_child)
	delete(ctx.next_sibling)
	delete(ctx.wrap_list)
	delete(ctx.subtree_end)
	delete(ctx.scratch_a)
	delete(ctx.scratch_b)
	delete(ctx.scratch_ints)
	delete(ctx.draw_cmds)
	delete(ctx.instances)
	delete(ctx.damage)
	delete(ctx.popups)
	delete(ctx.dismiss_flags)
	delete(ctx.scroll_off)
	delete(ctx.scroll_max)
	delete(ctx.scroll_glides)
	delete(ctx.tweens)
	delete(ctx.transients)
	for _, es in ctx.edits {
		free(es)
	}
	delete(ctx.edits)
	delete(ctx.hover_chain)
	delete(ctx.hover_since)
	for b in Mouse_Button {
		delete(ctx.press_chains[b])
	}
	delete(ctx.key_press_chain)
	delete(ctx.frame_text)
	delete(ctx.keys_scratch)
	delete(ctx.seen_ids)
	delete(ctx.dead_ids)
	delete(ctx.clicked_chain)
	delete(ctx.affected)
	delete(ctx.pick_clip)
	delete(ctx.eff)
	delete(ctx.disabled_flags)
}

// journal_gc retires the journal prefix every live context has
// consumed, clearing those units' dirty bitsets. With no contexts
// at all, nobody can ever consume the past, so everything retires.
@(private)
journal_gc :: proc() {
	m := len(store.journal)
	for c in store.contexts {
		m = min(m, c.journal_cursor)
	}
	if m <= 0 {
		return
	}
	for u in store.journal[:m] {
		store.units[int(u)].dirty = {}
	}
	if m == len(store.journal) {
		clear(&store.journal)
	} else {
		copy(store.journal[:], store.journal[m:])
		resize(&store.journal, len(store.journal) - m)
	}
	for c in store.contexts {
		c.journal_cursor -= m
	}
}

// journal_consume marks the bound context current with the journal
// (called from frame_end at the point the old touched list was
// cleared) and retires whatever that unblocks.
@(private)
journal_consume :: proc() {
	g.journal_cursor = len(store.journal)
	journal_gc()
}

// ---------------------------------------------------------------------------
// Mutation helpers (used by the public set/set_many in public.odin)

@(private)
apply_opt :: proc(dst: ^$T, src: Maybe(T)) {
	if v, ok := src.?; ok {
		dst^ = v
	}
}

// explicit_fields reports which decl fields were set (non-nil Maybe). Recorded
// at mint for propagate; also drives the dirty bitset in set_many.
@(private)
explicit_fields :: proc(d: Style_Decl) -> Fields {
	f: Fields
	if d.color         != nil { f += {.Color} }
	if d.font_color    != nil { f += {.Font_Color} }
	if d.border_color  != nil { f += {.Border_Color} }
	if d.text          != nil { f += {.Text} }
	if d.font          != nil { f += {.Font} }
	if d.font_size     != nil { f += {.Font_Size} }
	if d.font_weight   != nil { f += {.Font_Weight} }
	if d.font_slant    != nil { f += {.Font_Slant} }
	if d.text_spans    != nil { f += {.Text_Spans} }
	if d.padding       != nil { f += {.Padding} }
	if d.gap           != nil { f += {.Gap} }
	if d.border_width  != nil { f += {.Border_Width} }
	if d.corner_radius != nil { f += {.Corner_Radius} }
	if d.opacity       != nil { f += {.Opacity} }
	if d.layout        != nil { f += {.Layout} }
	if d.size          != nil { f += {.Size} }
	if d.scroll        != nil { f += {.Scroll} }
	if d.align         != nil { f += {.Align} }
	if d.wrap          != nil { f += {.Text_Wrap} }
	if d.whitespace    != nil { f += {.Whitespace} }
	if d.ellipsis      != nil { f += {.Ellipsis} }
	if d.overflow      != nil { f += {.Overflow} }
	if d.overlay_color        != nil { f += {.Overlay_Color} }
	if d.overlay_border_color  != nil { f += {.Overlay_Border_Color} }
	if d.overlay_border_width  != nil { f += {.Overlay_Border_Width} }
	if d.cursor       != nil { f += {.Cursor} }
	if d.scroll_chain != nil { f += {.Scroll_Chain} }
	if d.smooth_scroll != nil { f += {.Smooth_Scroll} }
	if d.smooth_ms != nil { f += {.Smooth_Ms} }
	if d.overscroll != nil { f += {.Overscroll} }
	if d.overscroll_px != nil { f += {.Overscroll_Px} }
	return f
}

// touch bumps the global generation and marks the unit's dirty fields,
// journaling the unit for per-context consumption at frame_end. It also records
// the fields as explicit: every write through set/set_many is a deliberate
// choice, and overlay resolution (input.odin) merges exactly the fields an
// overlay unit explicitly set.
@(private)
touch :: proc(u: Unit, f: Fields) {
	rec := &store.units[int(u)]
	if card(rec.dirty) == 0 {
		append(&store.journal, u)
	}
	rec.dirty += f
	rec.explicit += f
	store.gen += 1
}

// touch_unmarked is touch without the explicit marking: propagate's
// writes (§3.16) are received values, not the unit's own choices, and
// marking them explicit would freeze the unit out of later propagates.
@(private)
touch_unmarked :: proc(u: Unit, f: Fields) {
	rec := &store.units[int(u)]
	if card(rec.dirty) == 0 {
		append(&store.journal, u)
	}
	rec.dirty += f
	store.gen += 1
}

style_of :: proc(u: Unit) -> ^Style {
	return &store.units[int(u)].style
}

// ---------------------------------------------------------------------------
// Hashing (FNV-1a; identity = hash(parent_id, unit, key))

str_hash :: proc(s: string) -> u64 {
	h := u64(14695981039346656037)
	for b in transmute([]u8)(s) {
		h = (h ~ u64(b)) * 1099511628211
	}
	return h
}

hash_mix :: proc(h, v: u64) -> u64 {
	return (h ~ v) * 1099511628211
}

identity_of :: proc(parent_id: u64, u: Unit, key: u64) -> Instance {
	h := u64(14695981039346656037)
	h = hash_mix(h, parent_id)
	h = hash_mix(h, u64(u))
	h = hash_mix(h, key)
	return Instance(h)
}

// Popup_Rec is one open popup root (§3.19), recorded at declare
// time by begin_popup. root_idx indexes the node array of the frame
// that declared it — during the next frame_begin's dispatch, that
// is exactly the tree being hit-tested.
Popup_Rec :: struct {
	root_idx: int,
	id:       Instance,
	modal:    bool,
	stay:     bool, // no light dismiss (toasts, pinned panels)
}

// One wheel glide in flight (§3.21): the offset eases from `from` to
// `to` over `dur` ms of engine time (cubic ease-out, the house easing).
// A fresh wheel tick restarts the glide from the CURRENT offset to the
// accumulated target, so rapid ticks feel like one continuous glide.
Scroll_Glide :: struct {
	from:   Vec2,
	to:     Vec2,
	t:      f32, // ms elapsed
	dur:    f32, // ms
	delay:  f32, // ms to hold `from` before easing starts (springs:
	              // the gesture-quiet window, §3.22)
	spring: bool, // an overscroll spring (§3.22): its target is the
	              // range end it returns to. Wheel accumulation reads
	              // the rendered offset while one is in flight, not
	              // this target.
}

// One committed instance: its last rect plus the hash of its last
// committed resolved content (style values + text). Pass F damages an
// instance whose hash changed even when its rect didn't move — §5's
// "changed → new rect" covers text edits and set() restyles, not just
// motion.
Inst_Rec :: struct {
	rect: Rect,
	hash: u64,
	unit: Unit, // the unit this instance instantiates (cross-context reads, M4)
}
