// public.odin — the public API of the ui package.
//
// Everything a user of the framework touches lives in this file: identity,
// styling, per-frame overrides, containers, frames, and the mutation path.
// Internals (frame nodes, layout passes, the cold store, text measurement)
// live in their own files; anything not in this file is not API.
//
// Faithful to UI_API_Design.md §2. Gaps vs §2 are listed at the bottom —
// each is a subsystem on the roadmap, not an oversight.
package niello

// ============ math ============

Vec2 :: [2]f32

Rect :: struct {
	pos:  Vec2,
	size: Vec2,
}

INF :: max(f32) // standing in for +infinity

// ============ identity ============

// NO_UNIT is the §8 cold-store sentinel (index 0). Passing it as mint's base
// means "no prototype: start from default_style()".
NO_UNIT :: Unit(0)

Unit     :: distinct u32 // cold: minted once, owns its values
Instance :: distinct u64 // hot: one on-screen occurrence = hash(parent, unit, key)
Group    :: distinct u32 // cold: broadcast list of (unit, fields)
Key      :: distinct u64 // stable per-item identity; 0 = sibling ordinal

// ============ styling ============

Field :: enum u8 {
	Color, Text_Color, Border_Color,
	Text, Font, Text_Wrap, Ellipsis,
	Padding, Gap, Corner_Radius, Opacity,
	Layout, Align, Size, Scroll, Overflow,
	Border_Width, Overlay_Color, Overlay_Border_Color, Overlay_Border_Width,
}
// Text_Wrap is layout-invalidating (controls pass-C participation);
// Align is layout-invalidating (controls child positioning);
// Ellipsis and Overflow are paint-only (resolved at draw-command emission).
Fields :: bit_set[Field]

Layout :: enum u8 {
	Left_To_Right,
	Top_To_Bottom,
	Stack, // children resolve independently, excluded from waterfill
}

Sizing_Kind :: enum u8 {
	Fit,
	Grow,
	Fixed,
	Percent,
}

Sizing :: struct {
	kind:  Sizing_Kind,
	value: f32, // Fixed: px; Percent: fraction of parent inner size
	min:   f32, // clamp floor, default 0 (waterfill never goes below max(min, min_c))
	max:   f32, // clamp ceiling, default INF
}

Size :: [2]Sizing // indexed by axis

fixed :: proc(v: f32, min: f32 = 0, max: f32 = INF) -> Sizing {
	return Sizing{kind = .Fixed, value = v, min = min, max = max}
}

percent :: proc(v: f32, min: f32 = 0, max: f32 = INF) -> Sizing {
	return Sizing{kind = .Percent, value = v, min = min, max = max}
}

fit :: proc(min: f32 = 0, max: f32 = INF) -> Sizing {
	return Sizing{kind = .Fit, min = min, max = max}
}

grow :: proc(min: f32 = 0, max: f32 = INF) -> Sizing {
	return Sizing{kind = .Grow, min = min, max = max}
}

Scroll :: enum u8 {
	None,
	Vertical,
	Horizontal,
	Both,
}

Align_Kind :: enum u8 {
	Start,
	Center,
	End,
}

// Color is RGBA bytes. The concrete representation is provisional until the
// Skia backend lands; the API contract is "four channels", not the layout.
Color :: [4]u8

Font_Handle :: distinct u32

Text_Wrap :: enum u8 {
	None, // default: no auto-wrap; explicit \n still breaks lines
	Word, // wrap at word boundaries (opts into pass C)
}

Overflow :: enum u8 {
	Spill, // default: children may draw past bounds (Clay-like); debug reports it
	Clip,   // hard clip children at the container's bounds
}
// Note: scrolling is the `scroll` field, not a third mode here.

Style :: struct {
	color, text_color, border_color: Color,
	text:          string,
	font:          Font_Handle,
	padding:       [4]u16,
	gap:           u16,
	border_width:  u16, // paint-only; drawn inset within the rect
	corner_radius: u8,
	opacity:       u8,
	layout:        Layout,
	size:          Size,
	scroll:        Scroll,
	align:         [2]Align_Kind, // indexed by axis; caller resolves main vs cross
	wrap:          Text_Wrap,     // default .None
	ellipsis:      bool,          // default true; paint-time trim when no-wrap text overflows
	overflow:      Overflow,      // default .Spill

	// Debug/focus overlay, painted on top of the instance's own rect after its
	// normal content, inside the same clip/opacity scope. Transparent color /
	// zero width = disabled. The mechanism for keyboard focus rings (via a
	// per-instance transient overlay) and debug highlighting.
	overlay_color:        Color,
	overlay_border_color: Color,
	overlay_border_width: u16, // paint-only; drawn inset within the rect
}

default_style :: proc() -> Style {
	return Style{
		layout   = .Left_To_Right,
		size     = {fit(), fit()},
		align    = {.Start, .Start},
		wrap     = .None,
		ellipsis = true,
		overflow = .Spill,
		scroll   = .None,
		opacity  = 255, // opaque; colors default to transparent black (paint TBD)
	}
}

// Declaration-time style: Maybe fields so zero stays a legitimate value.
// PORTABILITY: never use a bare {...} literal for a Maybe field — some Odin
// versions reject it ("Invalid compound literal type"). Always name the inner
// type: size = Size{...}, padding = [4]u16{...}.
Style_Decl :: struct {
	color:         Maybe(Color),
	text_color:    Maybe(Color),
	border_color:  Maybe(Color),
	text:          Maybe(string),
	font:          Maybe(Font_Handle),
	padding:       Maybe([4]u16),
	gap:           Maybe(u16),
	border_width:  Maybe(u16),
	corner_radius: Maybe(u8),
	opacity:       Maybe(u8),
	layout:        Maybe(Layout),
	size:          Maybe(Size),
	scroll:        Maybe(Scroll),
	align:         Maybe([2]Align_Kind),
	wrap:          Maybe(Text_Wrap), // default .None
	ellipsis:      Maybe(bool),      // default true; paint-time trim when no-wrap text overflows
	overflow:      Maybe(Overflow),  // default .Spill

	overlay_color:        Maybe(Color),
	overlay_border_color: Maybe(Color),
	overlay_border_width: Maybe(u16),

	hover, press, focus, disabled: Unit, // automatic state overlays, declared as data
	focusable: bool,                     // reserved seam: participates in keyboard focus traversal

	groups: []Group,
}

// ============ per-frame overrides ============
// Travel with show/begin. No hidden cursor.
With :: struct {
	text:         Maybe(string), // copied into the frame arena at declare time (default)
	text_no_copy: Maybe(string), // borrowed reference. Contract: bytes must be
	                             // immutable until frame_end. Contents are hashed at
	                             // declare time for the declaration hash; the pointer
	                             // is kept for the render backend.
	disabled: bool,
	variant:  Unit,          // persistent per-instance overlay (e.g. selected)
	anchor:   Maybe([2]f32), // overlay positioning hint

	label: Maybe(string), // reserved seam for accessibility: accessible name,
	                      // copied like text. Roles/descriptions extend With
	                      // later without breaking existing call sites.

	user: rawptr,
}

key_int :: proc(v: int) -> Key {
	return Key(u64(v))
}
key_str :: proc(s: string) -> Key {
	return Key(str_hash(s))
}
key_ptr :: proc(p: rawptr) -> Key {
	return Key(u64(uintptr(p)))
}
key :: proc{key_int, key_str, key_ptr}

// ============ containers ============

Begin_Flag :: enum u8 {
	No_Cull, // declare children even when off-screen
}
Begin_Flags :: bit_set[Begin_Flag]

// ============ frames ============

Input :: struct {
	viewport: Vec2, // window size in DIP; roots fill it unless FIXED/PERCENT.
	                // (The design doc leaves Input's fields unspecified; the
	                // mock needs the viewport from somewhere, so it rides here.)
	mouse: Vec2, // reserved: hit-testing reads last frame until input lands
	// future: buttons, keys, scroll delta, text input, ...
}

Frame_Result :: struct {
	changed:      bool,   // anything new, moved, or resized this frame
	damage:       []Rect, // damaged regions, valid until the next frame_begin
	next_wake_ms: u32,    // ∞ (max(u32)) here: no timers/animations in this build,
	                      // so the host sleeps until input or wake()
}

// ============ cold path ============

// mint creates a unit. base is a SNAPSHOT copy, never a live link: the new
// unit starts with base's current style and never follows later writes to
// base. Pass NO_UNIT (the default case for fresh units) to start from
// default_style(). decl applies on top via set_many.
mint :: proc(out: ^Unit, base: Unit, decl: Style_Decl = {},
             name := #caller_expression(out), loc := #caller_location) {
	if len(g.units) == 0 {
		append(&g.units, Unit_Rec{name = "NO_UNIT"}) // §8 sentinel at index 0
	}
	u := Unit(u32(len(g.units)))
	rec := Unit_Rec{style = default_style(), name = name, loc = loc, proto = base}
	if base != NO_UNIT {
		assert(int(base) < len(g.units), "niello.mint: base is not a minted unit")
		rec.style = g.units[int(base)].style
	}
	append(&g.units, rec)
	out^ = u
	// decl = {} is a no-op merge (set_many skips the generation bump when no
	// explicit fields were set).
	set_many(u, decl)
}

// ============ mutation (the only writes; each bumps the unit generation) ============

// must asserts the dynamic value has the field's static type. set's $T
// signature can't dispatch on the runtime Field with a plain switch (Odin
// checks every branch per instantiation), so the type check happens here,
// loudly, instead of silently corrupting a neighboring field.
@(private)
must :: proc(v: any, $T: typeid) -> T {
	x, ok := v.(T)
	assert(ok, "niello.set: value type does not match the field")
	return x
}

@(private)
set_any :: proc(u: Unit, f: Field, v: any) {
	s := &g.units[int(u)].style
	switch f {
	case .Color:         s.color         = must(v, Color)
	case .Text_Color:    s.text_color    = must(v, Color)
	case .Border_Color:  s.border_color  = must(v, Color)
	case .Text:          s.text          = must(v, string)
	case .Font:          s.font          = must(v, Font_Handle)
	case .Text_Wrap:     s.wrap          = must(v, Text_Wrap)
	case .Ellipsis:      s.ellipsis      = must(v, bool)
	case .Padding:       s.padding       = must(v, [4]u16)
	case .Gap:           s.gap           = must(v, u16)
	case .Corner_Radius: s.corner_radius = must(v, u8)
	case .Opacity:       s.opacity       = must(v, u8)
	case .Layout:        s.layout        = must(v, Layout)
	case .Align:         s.align         = must(v, [2]Align_Kind)
	case .Size:          s.size          = must(v, Size)
	case .Scroll:        s.scroll        = must(v, Scroll)
	case .Overflow:      s.overflow      = must(v, Overflow)
	case .Border_Width:  s.border_width  = must(v, u16)
	case .Overlay_Color:        s.overlay_color        = must(v, Color)
	case .Overlay_Border_Color: s.overlay_border_color = must(v, Color)
	case .Overlay_Border_Width: s.overlay_border_width = must(v, u16)
	}
	touch(u, Fields{f})
}

set :: proc(u: Unit, f: Field, v: $T) {
	set_any(u, f, v)
}

// set_many merges a decl into the unit's owned style: Maybe fields that are
// set overwrite, the rest is untouched. Also records overlay units,
// focusable, group memberships, and the explicit field set (for propagate).
set_many :: proc(u: Unit, decl: Style_Decl) {
	s := &g.units[int(u)].style
	apply_opt(&s.color, decl.color)
	apply_opt(&s.text_color, decl.text_color)
	apply_opt(&s.border_color, decl.border_color)
	apply_opt(&s.text, decl.text)
	apply_opt(&s.font, decl.font)
	apply_opt(&s.padding, decl.padding)
	apply_opt(&s.gap, decl.gap)
	apply_opt(&s.border_width, decl.border_width)
	apply_opt(&s.corner_radius, decl.corner_radius)
	apply_opt(&s.opacity, decl.opacity)
	apply_opt(&s.layout, decl.layout)
	apply_opt(&s.size, decl.size)
	apply_opt(&s.scroll, decl.scroll)
	apply_opt(&s.align, decl.align)
	apply_opt(&s.wrap, decl.wrap)
	apply_opt(&s.ellipsis, decl.ellipsis)
	apply_opt(&s.overflow, decl.overflow)
	apply_opt(&s.overlay_color, decl.overlay_color)
	apply_opt(&s.overlay_border_color, decl.overlay_border_color)
	apply_opt(&s.overlay_border_width, decl.overlay_border_width)

	rec := &g.units[int(u)]
	// Overlay handles: NO_UNIT (the zero value) means "unset", so a decl that
	// doesn't mention them leaves existing overlays alone.
	if decl.hover != NO_UNIT    { rec.hover = decl.hover }
	if decl.press != NO_UNIT    { rec.press = decl.press }
	if decl.focus != NO_UNIT    { rec.focus = decl.focus }
	if decl.disabled != NO_UNIT { rec.disabled = decl.disabled }
	rec.focusable = decl.focusable
	if decl.groups != nil       { rec.groups = decl.groups }

	fields := explicit_fields(decl)
	if fields != {} {
		touch(u, fields)
	}
}

// ============ hot path ============

show :: proc(unit: Unit, key: Key = 0, with: With = {}) -> Instance {
	inst, _ := declare(unit, key, with, false)
	return inst
}

// Containers return BOTH the handle and the cull signal.
// open == false → container was culled: skip declaring children.
// The bool is advisory: ignoring it and declaring anyway is always correct,
// just slower. Culled subtrees produce no instances this frame → rect() on
// them returns ok = false. The first frame never culls (no last-frame
// geometry to test against).
@(deferred_out = end)
begin :: proc(unit: Unit, key: Key = 0, with: With = {}, flags: Begin_Flags = {}) -> (
	i:    Instance,
	open: bool,
) {
	new_inst, idx := declare(unit, key, with, true)
	i = new_inst

	// Mock culling: a container stays open unless its parent was culled or the
	// test hook fires. (Real culling tests last-frame rects against clip rects.)
	cull := g.nodes[idx].culled
	if g.test_force_cull {
		cull = true
		g.test_force_cull = false
	}
	_ = flags // No_Cull honored by the real culler; the mock never culls by rect.
	g.nodes[idx].culled = cull
	open = !cull

	// Push even when closed: end() must pop symmetrically, and children declared
	// while ignoring `open` are still correctly parented (just culled).
	append(&g.stack, idx)
	append(&g.child_counts, 0)
	return i, open
}

// end receives begin's return values via @(deferred_out). It must pop even
// when open == false.
end :: proc(i: Instance, open: bool) {
	pop(&g.stack)
	pop(&g.child_counts)
}

frame_begin :: proc(input: Input, dt: f32) {
	clear(&g.nodes)
	clear(&g.stack)
	clear(&g.child_counts)
	clear(&g.lay)
	clear(&g.wrap_list)
	clear(&g.damage)
	clear(&g.draw_cmds)
	g.viewport = input.viewport
	g.dt = dt
	// Cold units, the instance map, and the text cache persist across frames.
}

// frame_end runs the resolve pass: diff instances, layout, compute damage.
// After it returns, queries (rect) read THIS frame's resolved data.
frame_end :: proc() -> Frame_Result {
	layout_pass(g.viewport)
	// Clearing dirty is O(touched), not O(units) — §8.
	for u in g.touched {
		g.units[int(u)].dirty = {}
	}
	clear(&g.touched)
	res := Frame_Result{
		changed      = g.frame_index == 0 || len(g.damage) > 0,
		damage       = g.damage[:],
		next_wake_ms = max(u32), // ∞: no timers/animations in this build
	}
	g.frame_index += 1
	return res
}

// rect reads the last completed layout. During declaration it sees the
// previous frame; after frame_end it sees this frame.
rect :: proc(i: Instance) -> (r: Rect, ok: bool) {
	r, ok = g.instances[i]
	return r, ok
}

// ============ not yet implemented (roadmap, in doc order) ============
// Each is a subsystem, not a stub: declaring them now would promise behavior
// the mock can't deliver.
//
//   groups:      group_new, group_add, group_merge, group_set, group_tween
//   mutation:   edit, tween, propagate, pin
//   hot path:   transient
//   input:      clicked, hovered, pressed, hover_duration
//   focus:      focused, focus            (seams reserved: focusable, With.label)
//   scheduling: wake
