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

Globals :: struct {
	// Cold store: units own their style values. Survives across frames.
	// Index 0 is the NO_UNIT sentinel (§8).
	units: [dynamic]Unit_Rec,
	groups: [dynamic]Group_Rec,

	// Change tracking (§8): global generation bumped by every set/set_many,
	// per-unit dirty bitsets, O(touched) clearing at frame_end.
	gen:     u64,
	touched: [dynamic]Unit,

	// Frame store: flat parent-before-child node array, rebuilt every frame.
	nodes:        [dynamic]Frame_Node,
	stack:        [dynamic]int, // open container node indices
	child_counts: [dynamic]int, // children declared so far, per open container

	// Frame inputs, latched at frame_begin.
	viewport: Vec2,
	dt:       f32,

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

	// Persistent instance store: identity -> last committed rect.
	instances: map[Instance]Rect,
	// Identity -> hash of the last committed frame's resolved content
	// (style values + text). Pass F damages an instance whose content hash
	// changed even when its rect didn't move — §5's "changed → new rect"
	// covers text edits and set() restyles, not just motion.
	inst_hash: map[Instance]u64,
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
	focus_id:      Instance, // programmatic keyboard focus (traversal is later)
	prev_focused:  bool, // last frame's window_focused; the falling edge
	                     // drops press capture (input.odin)
	input_dirty:   bool,     // interaction state changed this frame
	// Scheduling (§3.3): engine time accumulates frame_begin's dt;
	// deadlines are engine-time stamps, the nearest one wins.
	time_ms:           u64,
	wake_deadline:     u64,
	wake_deadline_set: bool,
	// Set by wake() from any thread (atomic access only), consumed at
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

	layout_gen: u32,
	frame_index: u64,
	text_cache: map[u64]Text_Entry,
	ellipsis_widths: map[u64]f32,

	// Test-only hook: force the next begin() to report open=false.
	test_force_cull: bool,
}

@(private)
g: Globals

// test_reset clears everything, including cold units, and re-seeds the
// NO_UNIT sentinel: each test starts from a working empty engine.
// test_teardown is its exit-side pair: it frees the same containers but
// leaves NO sentinel behind, so a test ends with zero engine allocations
// live. Tests open with test_reset() and defer test_teardown(). The
// pairing is what keeps the runner's per-test tracking allocator honest:
// engine state is global by design, so without it the NEXT test's reset
// frees this test's allocations under the wrong tracker and they report
// as leaks (still live at test end) and bad frees (freed by a tracker
// that never allocated them).
test_reset :: proc() {
	free_globals()
	g = Globals{}
	append(&g.units, Unit_Rec{name = "NO_UNIT"}) // §8 sentinel at index 0
	append(&g.groups, Group_Rec{name = "NO_GROUP"})
}

test_teardown :: proc() {
	free_globals()
	g = Globals{}
}

// free_globals deletes every heap-owning container in g: assigning
// g = Globals{} alone would orphan all backing arrays.
@(private)
free_globals :: proc() {
	// Free the text cache first (each Text_Entry owns segs -> words -> frags).
	for _, entry in g.text_cache {
		for seg in entry.segs {
			for word in seg {
				delete(word.frags)
			}
			delete(seg)
		}
		delete(entry.segs)
	}
	delete(g.text_cache)
	delete(g.ellipsis_widths)
	// Per-declare span copies (resolve_spans) live on the frame nodes.
	for nd in g.nodes {
		delete(nd.spans)
	}
	delete(g.units)
	for &gr in g.groups {
		delete(gr.members)
	}
	delete(g.groups)
	delete(g.touched)
	delete(g.nodes)
	delete(g.stack)
	delete(g.child_counts)
	delete(g.lay)
	delete(g.first_child)
	delete(g.next_sibling)
	delete(g.wrap_list)
	delete(g.subtree_end)
	delete(g.scratch_a)
	delete(g.scratch_b)
	delete(g.scratch_ints)
	delete(g.draw_cmds)
	delete(g.instances)
	delete(g.inst_hash)
	delete(g.damage)
	delete(g.scroll_off)
	delete(g.scroll_max)
	delete(g.tweens)
	delete(g.transients)
	for _, es in g.edits {
		free(es)
	}
	delete(g.edits)
	delete(g.hover_chain)
	delete(g.hover_since)
	for b in Mouse_Button {
		delete(g.press_chains[b])
	}
	delete(g.clicked_chain)
	delete(g.affected)
	delete(g.pick_clip)
	delete(g.eff)
	delete(g.disabled_flags)
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
	if d.ellipsis      != nil { f += {.Ellipsis} }
	if d.overflow      != nil { f += {.Overflow} }
	if d.overlay_color        != nil { f += {.Overlay_Color} }
	if d.overlay_border_color  != nil { f += {.Overlay_Border_Color} }
	if d.overlay_border_width  != nil { f += {.Overlay_Border_Width} }
	if d.cursor       != nil { f += {.Cursor} }
	if d.scroll_chain != nil { f += {.Scroll_Chain} }
	return f
}

// touch bumps the global generation and marks the unit's dirty fields,
// recording the unit for O(touched) clearing at frame_end. It also records
// the fields as explicit: every write through set/set_many is a deliberate
// choice, and overlay resolution (input.odin) merges exactly the fields an
// overlay unit explicitly set.
@(private)
touch :: proc(u: Unit, f: Fields) {
	rec := &g.units[int(u)]
	if card(rec.dirty) == 0 {
		append(&g.touched, u)
	}
	rec.dirty += f
	rec.explicit += f
	g.gen += 1
}

// touch_unmarked is touch without the explicit marking: propagate's
// writes (§3.16) are received values, not the unit's own choices, and
// marking them explicit would freeze the unit out of later propagates.
@(private)
touch_unmarked :: proc(u: Unit, f: Fields) {
	rec := &g.units[int(u)]
	if card(rec.dirty) == 0 {
		append(&g.touched, u)
	}
	rec.dirty += f
	g.gen += 1
}

style_of :: proc(u: Unit) -> ^Style {
	return &g.units[int(u)].style
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
