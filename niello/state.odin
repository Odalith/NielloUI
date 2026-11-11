// state.odin — cold unit store and context state.
// The engine threads explicit contexts (one per window); g is the
// currently bound context, bound by the glue for each frame.
//
// The public mutation path (mint/set/set_many) lives in public.odin; this file
// holds the stores it writes to. The struct-of-structs here stands in for the
// §8 struct-of-arrays layout — a mechanical perf pass once the API settles.
package niello

import "base:intrinsics"
import "base:runtime"

Unit_Rec :: struct {
	// Slot bookkeeping (unmint): a handle carries its slot's
	// generation, so a handle to a freed unit never reaches the unit
	// that reuses the slot.
	generation: u32,
	live:       bool,

	style: Style, // resolved, owned values
	gen:   u64,   // visual-write generation (§5 stamps): bumped by
	              // touch/touch_unmarked when a VISUAL_FIELDS field is
	              // written. Instances remember the gen they last
	              // painted with; a mismatch is damage — the exact,
	              // versioned replacement for re-hashing the style.

	// §8 cold-store metadata.
	explicit: Fields, // fields set directly at mint (for propagate)
	proto:    Unit,   // prototype unit, NO_UNIT if none
	pinned:   Fields, // fields protected from group writes (pin)

	// Warm: read when resolving interaction state (overlays not yet applied).
	hover, press, focus, disabled: Unit,
	focusable: bool,

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
	deleted: bool,   // group_delete ran; the handle is dead
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
	free_units: [dynamic]u32, // slots freed by unmint, reused by mint

	// Change tracking is the stamp system (§3.26): each unit's
	// visual generation (Unit_Rec.gen) plus the declare-time
	// digest decide all damage in pass F. There is no write
	// journal — an earlier design kept one alongside the stamps;
	// nothing read it outside tests, and a context that never
	// framed pinned it forever (audit X-1).

	// Live contexts, in creation order: tween() cancels a unit's
	// tweens across all of them (animate.odin).
	contexts: [dynamic]^Context,

	// Debug tooling state (TODO #18, debug.odin): the highlight
	// channel and the overflow-report scratch. Inert in prod
	// builds; written and read only under the NIELLO_DEBUG gate.
	debug_hl_ctx:      ^Context,
	debug_hl_inst:     Instance,
	debug_hl_color:    Color,
	debug_ovf_ctx:     ^Context,
	debug_ovf_on:      bool,
	debug_ovf_scratch: [dynamic]Overflow_Rec,

	// The word cache is content-addressed (font, style, text ->
	// metrics), so it is shared by every window: a word measured
	// for one window is a free hit for all the others.
	images:           [dynamic]Image_Rec, // the image registry (§3.25);
	                                      // index = Image id, slot 0 sentinel
	text_cache:       map[u64]Text_Entry,
	ellipsis_widths: map[u64]f32,
	font_epoch:       u64, // bumped by fonts_changed(); mixed into both
	                       // text cache keys so a (re)registered font
	                       // invalidates everything it measured (txt-5)
}

// Context is one window's frame state (multi-window plan, M1):
// everything a single tree's frames own — nodes, instances,
// interaction, scheduling, mutation — and nothing they share. The
// package handle `g` (below) points at the currently bound
// context; frame_begin binds, declare-time procs read the binding.
Context :: struct {
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
	emit_clips:  [dynamic]Rect, // accumulated clip per open emit scope (ren-1)

	// Frame store: flat parent-before-child node array, rebuilt every frame.
	nodes:        [dynamic]Frame_Node,
	withs:        [dynamic]With, // full With per node that keeps one (Frame_Node.with_idx)
	stack:        [dynamic]int, // open container node indices
	// Call-site identity (declare.odin): how often each call site has
	// declared so far, per open container. One flat array; each open
	// container owns the region from its site_base entry to the end,
	// truncated when it closes. The root level is the region from 0.
	site_counts: [dynamic]Site_Count,
	site_base:   [dynamic]int,
	popup_sites: [dynamic]Site_Count, // the same, for popup roots (the layer)
	clip_stack:   [dynamic]Rect, // declare-time accumulated clip per open container (BL-3)

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
	// Cull memory (BL-3): the last layout rect of every culled
	// node, keyed by identity. The culler tests last-frame rects,
	// but a culled node's instance is deleted (rect() must report
	// ok=false), so its rect lives here until it commits again or
	// leaves the tree. Pass F maintains it. The record carries
	// the same last_seen epoch stamp as Inst_Rec, so the recycle
	// sweep retires stale entries by stamp comparison — the job
	// the seen_ids hash-of-bools used to do (audit X-4/F1).
	cull_rects: map[Instance]Cull_Rec,
	damage:     [dynamic]Rect,

	// Debug snapshot (TODO #18, debug.odin): this context's last
	// completed frame as a flat Debug_Node array. The field is an
	// inert header in prod builds — the snapshot work and the API
	// that reads it are what the NIELLO_DEBUG gate removes.
	debug_nodes: [dynamic]Debug_Node,

	// Accessibility mirror (§3.9, TODO #23, a11y.odin): this
	// context's last completed frame as a flat A11y_Node array,
	// maintained at every frame_end, UNGATED — screen readers are
	// prod behavior, not debug tooling. Entries own their strings
	// (cloned at mirror build, freed on change/removal/teardown);
	// a11y_order borrows them and is valid until the next
	// frame_end. a11y_gen counts mirror builds (sweep marker);
	// a11y_idx is build scratch: frame-node index -> order index.
	a11y_entries: map[Instance]A11y_Entry,
	a11y_order:   [dynamic]A11y_Node,
	a11y_gen:     u64,
	a11y_idx:     [dynamic]int,

	// What the debug channel painted into this context's last
	// presented frame (debug.odin): frame_end compares the live
	// channel against these to damage exactly the transitions —
	// a highlight appearing, moving, or clearing changes the
	// pixels even when nothing in this tree changed, and the
	// glue only repaints frames that report changed.
	debug_painted_inst: Instance,
	debug_painted_ovf:  bool,

	// Scroll offsets by identity: written by wheel dispatch at
	// frame_begin and by scroll_to, read and re-clamped by pass F every
	// frame (the stored value is the offset the last frame rendered
	// with). Only scrollable containers ever get an entry; absence = 0.
	// Lifetime (audit int-2, ruled 2026-11-04): scroll state shares
	// the instance lifetime — when an instance record is recycled
	// (undeclared or culled), its scroll_off/scroll_max/scroll_glides
	// entries are purged with it. There is deliberately no separate
	// retention or tab-restore: a reappearing scroller starts at 0.
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
	hover_chain:   [dynamic]Instance, // root first; the tail is the
	                                  // pick target under the cursor
	hover_clock:   f32, // total dispatch time; durations read against it
	hover_since:   map[Instance]f32, // per-member chain entry time: an
	                                  // instance's hover duration is
	                                  // hover_clock - hover_since[id], and
	                                  // the entry dies when it leaves the
	                                  // chain (input.odin maintains both)
	press_ids:     [Mouse_Button]Instance, // press capture per button; 0 = none
	press_chains:  [Mouse_Button][dynamic]Instance,
	clicked_chain: [dynamic]Instance, // set at a release dispatch,
	                                  // valid for one declare
	// Drag state (§3.28): a left press whose displacement from the
	// grab point crosses DRAG_THRESHOLD becomes a drag on the same
	// capture. The ended snapshot, like clicked's, is valid for
	// exactly one declare.
	drag_active:          bool,
	drag_grab:            Vec2, // pointer position at the press
	drag_total_v:         Vec2, // live displacement from the grab point
	drag_delta_v:         Vec2, // pointer movement in the last dispatch
	drag_started_flag:    bool, // threshold crossed at the last dispatch
	drag_started_chain:   [dynamic]Instance, // the press chain of a drag
	                                  // that ended in the last dispatch:
	                                  // drag_started reads it so a flick
	                                  // that starts and ends in one
	                                  // dispatch still reports its start
	                                  // (audit int-14)
	drag_ended_id:        Instance,
	drag_ended_chain:     [dynamic]Instance,
	drag_ended_completed: bool, // release (true) vs capture loss (false)
	drag_ended_total:     Vec2,
	prev_pointer_pos:     Vec2,
	prev_pointer_valid:   bool,
	focus_id:      Instance, // keyboard focus (§3.17): traversal, click,
	                         // or programmatic; input_keys/input_text
	                         // route to it
	key_press_id:    Instance, // Space/Enter capture on the focused
	                         // instance between key-down and key-up
	key_press_code:  Key_Code,
	key_press_chain: [dynamic]Instance, // root-first chain snapshot,
	                         // like the pointer press chains
	frame_keys:      [16]Key_Event, // this frame's key events,
	                         // snapshotted at dispatch
	frame_key_count: int,
	key_consumed:    [16]bool, // per slot: the core ate this event
	                         // (traversal's Tab is never delivered)
	input_target:    Instance, // key/text routing frozen at dispatch:
	                           // the queries answer for it only
	frame_text:      [dynamic]u8, // this frame's committed text (owned)
	keys_scratch:    [dynamic]Key_Event, // input_keys result assembly
	dead_ids:        [dynamic]Instance, // recycle sweep scratch
	// Popups (§3.19): the frame's popup roots in begin_popup call
	// order (later = higher). Dispatch at frame_begin reads LAST
	// frame's list (cleared after dispatch); frame_end reads this
	// frame's for the modal focus bookkeeping.
	popups:          [dynamic]Popup_Rec,
	dismiss_flags:   map[Instance]bool, // popups whose dismissal was
	                         // requested at this frame's dispatch;
	                         // valid for one declare (dismiss_requested)
	modal_prev_id:   Instance, // last frame_end's topmost modal
	                         // popup root; 0 = no modal session
	modal_saved_focus: Instance, // focus held when the modal
	                         // session opened; restored when it ends
	prev_focused:  bool, // last frame's window_focused; the falling edge
	                     // drops press capture (input.odin)
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

	// Per-node side arrays, parallel to nodes. pick_clip is the accumulated
	// ancestor clip pass F computes; the NEXT frame's pick reads it (with
	// nodes/lay) before frame_begin clears them. eff holds resolved styles
	// for nodes with interaction state or a variant; disabled_flags carries
	// the ancestor-propagated disabled bit from the same resolution pass.
	pick_clip:      [dynamic]Rect,
	eff:            [dynamic]Style,
	disabled_flags: [dynamic]bool,
	state_stamp:    [dynamic]u64, // per-node interaction state stamp
	                              // (resolve_styles, input.odin):
	                              // which overlay layers are active,
	                              // folded with those units' gens

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
	shutdown() // destroys test_ctx with every other live context
	test_ctx = nil
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
	delete(store.images) // registry only; backend images die with the backend
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
	delete(store.free_units)
	for &gr in store.groups {
		delete(gr.members)
	}
	delete(store.groups)
	delete(store.contexts)
	delete(store.debug_ovf_scratch)
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
	delete(ctx.emit_clips)
	delete(ctx.nodes)
	delete(ctx.withs)
	delete(ctx.stack)
	delete(ctx.site_counts)
	delete(ctx.site_base)
	delete(ctx.popup_sites)
	delete(ctx.clip_stack)
	delete(ctx.lay)
	delete(ctx.first_child)
	delete(ctx.next_sibling)
	delete(ctx.wrap_list)
	delete(ctx.subtree_end)
	delete(ctx.scratch_a)
	delete(ctx.scratch_b)
	delete(ctx.scratch_ints)
	delete(ctx.draw_cmds)
	when NIELLO_DEBUG {
		delete(ctx.debug_nodes)
	}
	a11y_free_mirror(ctx)
	delete(ctx.instances)
	delete(ctx.cull_rects)
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
	delete(ctx.drag_ended_chain)
	delete(ctx.drag_started_chain)
	delete(ctx.frame_text)
	delete(ctx.keys_scratch)
	delete(ctx.dead_ids)
	delete(ctx.clicked_chain)
	delete(ctx.pick_clip)
	delete(ctx.eff)
	delete(ctx.disabled_flags)
	delete(ctx.state_stamp)
}


// ---------------------------------------------------------------------------
// Mutation helpers (used by the public set/set_many in public.odin)


// explicit_fields reports which decl fields were set (non-nil Maybe). Recorded
// at mint for propagate; also read by set_many's write tail.
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
	if d.image       != nil { f += {.Image} }
	if d.image_fit   != nil { f += {.Image_Fit} }
	if d.image_interp != nil { f += {.Image_Interp} }
	return f
}

// touch records a write through set/set_many: the fields become
// explicit (every such write is a deliberate choice, and overlay
// resolution in input.odin merges exactly the fields an overlay
// unit explicitly set), and a write touching a visual field bumps
// the unit's visual generation — the stamp pass F compares.
@(private)
touch :: proc(u: Unit, f: Fields) {
	rec := &store.units[unit_index(u)]
	rec.explicit += f
	if f & VISUAL_FIELDS != {} {
		rec.gen += 1
	}
}

// touch_unmarked is touch without the explicit marking: propagate's
// writes (§3.16) are received values, not the unit's own choices, and
// marking them explicit would freeze the unit out of later propagates.
@(private)
touch_unmarked :: proc(u: Unit, f: Fields) {
	rec := &store.units[unit_index(u)]
	if f & VISUAL_FIELDS != {} {
		rec.gen += 1
	}
}

style_of :: proc(u: Unit) -> ^Style {
	return &store.units[unit_index(u)].style
}

// A Unit handle is a slot index (low 32 bits) plus that slot's
// generation when the unit was minted (high 32 bits). NO_UNIT is slot 0,
// generation 0, and is never live.
unit_index :: #force_inline proc "contextless" (u: Unit) -> int {
	return int(u64(u) & 0xffff_ffff)
}

unit_handle :: #force_inline proc "contextless" (index: int, generation: u32) -> Unit {
	return Unit(u64(generation) << 32 | u64(index))
}

// unit_live reports that u names a minted unit that has not been
// unmint-ed: its slot exists, is live, and still has u's generation.
unit_live :: proc "contextless" (u: Unit) -> bool {
	i := unit_index(u)
	if i < 1 || i >= len(store.units) {
		return false
	}
	rec := &store.units[i]
	return rec.live && rec.generation == u32(u64(u) >> 32)
}

// ---------------------------------------------------------------------------
// Hashing (FNV-1a; identity = hash(parent_id, unit, key))

str_hash :: proc(s: string) -> u64 {
	h, _ := text_scan(s)
	return h
}

// text_scan hashes s eight bytes at a time (the length seeds the hash,
// so a zero-padded tail is unambiguous) and reports whether every byte
// is ASCII — all-ASCII text is valid UTF-8 without further checks.
text_scan :: proc(s: string) -> (h: u64, ascii: bool) #no_bounds_check {
	p := raw_data(s)
	n := len(s)
	h = mix64(0x9e3779b97f4a7c15 ~ u64(n))
	bits := u64(0)
	i := 0
	for ; i + 8 <= n; i += 8 {
		w := intrinsics.unaligned_load((^u64)(&p[i]))
		bits |= w
		h = mix64(h ~ w)
	}
	if i < n {
		w := u64(0)
		for k in 0 ..< n - i {
			w |= u64(p[i + k]) << (8 * u64(k))
		}
		bits |= w
		h = mix64(h ~ w)
	}
	return h, bits & 0x8080808080808080 == 0
}

hash_mix :: proc(h, v: u64) -> u64 {
	return (h ~ v) * 1099511628211
}

// mix64 is the splitmix64 finalizer: every input bit reaches every
// output bit. Identities fold through it rather than hash_mix, whose
// word-wide FNV step keeps its inputs' structure — with structured
// inputs (parent hashes, call-site addresses, small keys) two nodes
// collide whenever h1 ~ h2 == k1 ~ k2, and call-site keys move with
// ASLR, so such collisions came and went between runs.
mix64 :: proc(x: u64) -> u64 {
	x := x
	x ~= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ~= x >> 27
	x *= 0x94d049bb133111eb
	x ~= x >> 31
	return x
}

identity_of :: proc(parent_id: u64, u: Unit, key: u64) -> Instance {
	h := mix64(parent_id ~ u64(u) * 0x243f6a8885a308d3)
	h = mix64(h ~ key)
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
// Axis_Glide is one axis of a scroll glide: its own from/to and
// its own clock.
Axis_Glide :: struct {
	from:   f32,
	to:     f32,
	t:      f32, // ms elapsed
	dur:    f32, // ms
	delay:  f32, // ms to hold `from` before easing starts (springs:
	              // the gesture-quiet window, §3.22)
	spring: bool, // an overscroll spring (§3.22): its target is the
	              // range end it returns to. Wheel accumulation reads
	              // the rendered offset while one is in flight, not
	              // this target.
}

// Scroll_Glide holds a scroller's in-flight glides, one per axis
// (audit int-8): active[axis] says that axis is gliding, and the
// axes share nothing — a Y tick never re-bases or re-times an
// in-flight X glide. (The old single record coupled them: one
// from/to pair, one clock, one spring flag.)
Scroll_Glide :: struct {
	axis:   [2]Axis_Glide,
	active: [2]bool,
}

// One committed instance: its last rect plus the change stamps it
// last painted with (§5, the stamps scheme): the unit's visual
// generation, the digest of its declare-presented content, and its
// interaction state stamp. Pass F damages an instance whose stamps
// moved even when its rect didn't — "changed → new rect" covers
// text edits and set() restyles, not just motion. (Replaced the
// per-instance content hash 2026-10-23: styles are versioned by
// their write funnel, so re-mixing every resolved value every
// frame re-proved what the generations already knew.)
// Cull_Rec is a culled node's cull-memory entry (BL-3): its last
// layout rect plus the frame it was last written, in the same
// last_seen epoch as Inst_Rec.last_seen — the recycle sweep
// retires entries whose stamp went stale (audit X-4/F1).
Cull_Rec :: struct {
	rect:      Rect,
	last_seen: u64,
}

Inst_Rec :: struct {
	rect:  Rect,
	gen:   u64,
	digest: u64,
	stamp: u64,
	unit:  Unit, // the unit this instance instantiates (cross-context reads, M4)
	// The overflow committed with the rect (audit core-H7): damage
	// for a change or death must cover the OLD spill as well as the
	// new — a shrinking spill otherwise leaves its outermost pixels
	// undamaged forever.
	overfl: Vec2,
	// frame_index of the last pass-F commit (audit core-H4): the
	// recycle sweep deletes records whose last_seen is stale,
	// which catches deaths the old map-outgrew-the-tree signal
	// missed (a death balanced by a birth while other declared
	// nodes are culled inflates the node count, not the map).
	last_seen: u64,
}
