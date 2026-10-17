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

Globals :: struct {
	// Cold store: units own their style values. Survives across frames.
	// Index 0 is the NO_UNIT sentinel (§8).
	units: [dynamic]Unit_Rec,

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
	damage:    [dynamic]Rect,

	layout_gen: u32,
	frame_index: u64,
	text_cache: map[u64]Text_Entry,

	// Test-only hook: force the next begin() to report open=false.
	test_force_cull: bool,
}

@(private)
g: Globals

// test_reset clears everything, including cold units. Each test starts clean.
test_reset :: proc() {
	g = Globals{}
	append(&g.units, Unit_Rec{name = "NO_UNIT"}) // §8 sentinel at index 0
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
	if d.text_color    != nil { f += {.Text_Color} }
	if d.border_color  != nil { f += {.Border_Color} }
	if d.text          != nil { f += {.Text} }
	if d.font          != nil { f += {.Font} }
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
	return f
}

// touch bumps the global generation and marks the unit's dirty fields,
// recording the unit for O(touched) clearing at frame_end.
@(private)
touch :: proc(u: Unit, f: Fields) {
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
