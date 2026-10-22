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

import "core:strings"
import "core:sync"

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

// NO_GROUP is the group store's sentinel (index 0), mirroring NO_UNIT.
NO_GROUP :: Group(0)

Unit     :: distinct u32 // cold: minted once, owns its values
Instance :: distinct u64 // hot: one on-screen occurrence = hash(parent, unit, key)
Group    :: distinct u32 // cold: broadcast list of (unit, fields)
Key      :: distinct u64 // stable per-item identity; 0 = sibling ordinal

// ============ styling ============

Field :: enum u8 {
	Color, Font_Color, Border_Color,
	Text, Font, Font_Size, Font_Weight, Font_Slant, Text_Wrap, Whitespace, Ellipsis,
	Padding, Gap, Corner_Radius, Opacity,
	Layout, Align, Size, Scroll, Overflow,
	Border_Width, Overlay_Color, Overlay_Border_Color, Overlay_Border_Width,
	Text_Spans, Cursor, Scroll_Chain,
}
// Text_Wrap is layout-invalidating (controls pass-C participation);
// Align is layout-invalidating (controls child positioning);
// Font_Size, Font_Weight and Font_Slant are layout-invalidating (they change
// text measurement); Text_Spans is layout-invalidating (it changes word
// widths); Whitespace is layout-invalidating (it changes which space
// advances count toward line widths). Ellipsis and Overflow are paint-only (resolved at draw-command
// emission). Cursor is host-facing (never reaches a draw command; the host
// reads the hovered instance's resolved cursor from Frame_Result) and
// Scroll_Chain steers input dispatch (wheel routing); neither affects
// layout or paint.
Fields :: bit_set[Field]

// ALL_FIELDS is every Field, the default membership mask. Written out
// in full on purpose: a mask built from a bit trick could silently omit
// a field added later; the tests iterate Field and check membership.
ALL_FIELDS :: Fields{
	.Color, .Font_Color, .Border_Color,
	.Text, .Font, .Font_Size, .Font_Weight, .Font_Slant, .Text_Wrap, .Whitespace, .Ellipsis,
	.Padding, .Gap, .Corner_Radius, .Opacity,
	.Layout, .Align, .Size, .Scroll, .Overflow,
	.Border_Width, .Overlay_Color, .Overlay_Border_Color, .Overlay_Border_Width,
	.Text_Spans, .Cursor, .Scroll_Chain,
}

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

Font_Handle :: distinct u32 // identifies a font FAMILY; 0 = platform default

// Weight uses CSS 100-900 discriminants so the backend casts straight to
// SkFontStyle. The zero value is not a valid weight; default_style sets
// .Regular explicitly.
Font_Weight :: enum u16 {
	Thin     = 100,
	Light    = 300,
	Regular  = 400,
	Medium   = 500,
	SemiBold = 600,
	Bold     = 700,
	Black    = 900,
}

Font_Slant :: enum u8 {
	Upright,
	Italic,
	Oblique,
}

// A style override applied to a byte range of the unit's resolved text.
// Byte offsets ([start, end)) — Odin strings and the backend both speak
// bytes, so there is no conversion layer. Boundaries should fall on UTF-8
// boundaries (the splitter snaps defensively); out-of-range clamps, empty
// spans are ignored, and on overlap the later span in the array wins.
Text_Span :: struct {
	start, end: int,
	font:        Maybe(Font_Handle),
	font_size:   Maybe(f32),
	font_weight: Maybe(Font_Weight),
	font_slant:  Maybe(Font_Slant),
	font_color:  Maybe(Color),
}

// span_bytes converts rune-index ranges to byte offsets for Text_Span.
// Out-of-range indices clamp; reversed ranges yield an empty range.
span_bytes :: proc(s: string, rune_start, rune_end: int) -> (byte_start, byte_end: int) {
	if rune_start >= rune_end {
		return 0, 0
	}
	byte_start, byte_end = len(s), len(s)
	ri := 0
	for _, bi in s {
		if ri == rune_start {
			byte_start = bi
		}
		if ri == rune_end {
			byte_end = bi
			return byte_start, byte_end
		}
		ri += 1
	}
	// rune_end at or past the last rune: byte_end stays len(s).
	// rune_start past the end: empty range at the end.
	if ri <= rune_start {
		return len(s), len(s)
	}
	return byte_start, byte_end
}

Text_Wrap :: enum u8 {
	None, // default: no auto-wrap; explicit \n still breaks lines
	Word, // wrap at word boundaries (opts into pass C)
}

// Whitespace: how space runs count toward text geometry (§3.18).
// Space runs are always MEASURED (real advances, cut at span
// boundaries like words); the mode chooses the accounting.
Whitespace :: enum u8 {
	Collapse, // default: a run counts as one canonical gap between
	          // words; leading/trailing runs hang (count for
	          // nothing). The HTML-like model for labels and prose.
	Preserve, // every space occupies its advance — leading, trailing,
	          // and runs — so positions derived from text width
	          // (a caret, a selection) are exact. Editable text and
	          // markdown, where trailing spaces can be semantic.
}

Overflow :: enum u8 {
	Spill, // default: children may draw past bounds (Clay-like); debug reports it
	Clip,   // hard clip children at the container's bounds
}
// Note: scrolling is the `scroll` field, not a third mode here.

// The cursor the host should show while an instance with this style is the
// hover target. Mapped to the platform's system cursors by the app glue.
Cursor_Kind :: enum u8 {
	Arrow, // zero value: the platform default arrow
	Text,
	Pointer,
	Crosshair,
	Wait,
	Move,
	Resize_NS,
	Resize_EW,
	Resize_NWSE,
	Resize_NESW,
	Not_Allowed,
}

Style :: struct {
	color, font_color, border_color: Color,
	text:          string,
	font:          Font_Handle, // family; 0 = platform default
	font_size:     f32,          // px in DIP
	font_weight:   Font_Weight,
	font_slant:    Font_Slant,
	text_spans:    []Text_Span, // rich-text overrides; nil = plain
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
	whitespace:    Whitespace,    // default .Collapse (§3.18)
	ellipsis:      bool,          // default true; paint-time trim when no-wrap text overflows
	overflow:      Overflow,      // default .Spill

	// Debug/focus overlay, painted on top of the instance's own rect after its
	// normal content, inside the same clip/opacity scope. Transparent color /
	// zero width = disabled. The mechanism for keyboard focus rings (via a
	// per-instance transient overlay) and debug highlighting.
	overlay_color:        Color,
	overlay_border_color: Color,
	overlay_border_width: u16, // paint-only; drawn inset within the rect

	cursor:       Cursor_Kind, // host-facing; default .Arrow
	scroll_chain: bool,        // wheel dispatch: hand leftover delta to the next
	                           // scrollable ancestor; default true
}

default_style :: proc() -> Style {
	return Style{
		layout      = .Left_To_Right,
		size        = {fit(), fit()},
		align       = {.Start, .Start},
		wrap        = .None,
		ellipsis    = true,
		overflow    = .Spill,
		scroll      = .None,
		opacity     = 255, // opaque; colors default to transparent black (paint TBD)
		font_size   = 16,
		font_weight = .Regular,
		font_slant  = .Upright,
		cursor      = .Arrow,
		scroll_chain = true,
	}
}

// Declaration-time style: Maybe fields so zero stays a legitimate value.
// PORTABILITY: never use a bare {...} literal for a Maybe field — some Odin
// versions reject it ("Invalid compound literal type"). Always name the inner
// type: size = Size{...}, padding = [4]u16{...}.
Style_Decl :: struct {
	color:         Maybe(Color),
	font_color:    Maybe(Color),
	border_color:  Maybe(Color),
	text:          Maybe(string),
	font:          Maybe(Font_Handle),
	font_size:     Maybe(f32),
	font_weight:   Maybe(Font_Weight),
	font_slant:    Maybe(Font_Slant),
	text_spans:    Maybe([]Text_Span),
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
	whitespace:    Maybe(Whitespace), // default .Collapse (§3.18)
	ellipsis:      Maybe(bool),      // default true; paint-time trim when no-wrap text overflows
	overflow:      Maybe(Overflow),  // default .Spill

	overlay_color:        Maybe(Color),
	overlay_border_color: Maybe(Color),
	overlay_border_width: Maybe(u16),

	cursor:       Maybe(Cursor_Kind),
	scroll_chain: Maybe(bool), // default true

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
	text_spans: Maybe([]Text_Span), // per-instance rich-text overrides; wins
	                                // over Style.text_spans. Copied at declare
	                                // time (small), so no borrow contract.
	disabled: bool,
	focusable: Maybe(bool), // per-instance focus participation; wins over
	                        // the unit's Style_Decl.focusable, so one
	                        // instance of a repeated unit can be the
	                        // tabbable one (or none of them can).
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

Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
}

Buttons :: bit_set[Mouse_Button]

// One keyboard event, in the host's native code spaces. The core
// interprets only the keys its own semantics need (traversal and
// activation, below); the rest pass through to the focused instance
// via input_keys, uninterpreted.
Key_Event :: struct {
	scancode: u32, // physical key position (SDL scancode values from niello/sdl)
	keycode:  u32, // logical key (SDL keycode values from niello/sdl)
	mods:     u16, // modifier bitmask in host space, opaque to the core in v1
	down:     bool,
	repeat:   bool, // key-repeat event (down only)
}

// Scancodes the core itself consumes, in the SDL space Key_Event uses:
// traversal (Tab; Shift reverses) and activation (Space/Enter press
// the focused instance). Every other key passes through to the
// focused instance untouched.
SCANCODE_ESCAPE   :: 41
SCANCODE_TAB      :: 43
SCANCODE_RETURN   :: 40
SCANCODE_KP_ENTER :: 88
SCANCODE_SPACE    :: 44

// Modifier bits the core reads, in the host (SDL KMOD) space of
// Key_Event.mods.
MOD_SHIFT :: 0x0003 // KMOD_LSHIFT | KMOD_RSHIFT

Input :: struct {
	viewport: Vec2, // window size in DIP; roots fill it unless FIXED/PERCENT.

	mouse:       Vec2, // cursor position in DIP
	mouse_valid: bool, // false when the cursor is outside the window (or no
	                   // position has been reported yet): no pick, no hover

	// Button state is the HOST's contract: `down` is the current state,
	// `pressed`/`released` are edges LATCHED by the host since the last
	// frame. A press and release that both land inside one frame gap are a
	// real click — a host that samples only current state would eat it.
	buttons_down:     Buttons,
	buttons_pressed:  Buttons,
	buttons_released: Buttons,

	wheel: Vec2, // accumulated scroll delta since the last frame, in wheel
	             // units (fractional on smooth wheels/trackpads). Sign is
	             // the SDL convention: positive y is the scroll-UP
	             // direction (the view moves toward the top; offsets
	             // decrease), positive x the scroll-left direction. Hosts
	             // deliver it as SDL reports it — the glue passes events
	             // through, negating only FLIPPED ones, whose deltas
	             // arrive pre-inverted.

	keys:      [16]Key_Event, // events since the last frame, oldest first
	key_count: int,

	text: string, // text committed since the last frame (host text-input
	              // events, concatenated, UTF-8): typed characters,
	              // dead-key results, IME commits. The core routes it to
	              // the focused instance at dispatch; apps read it back
	              // with input_text. Inline composition (IME preedit)
	              // is not reported in v1.

	window_focused: bool, // false ends all interaction at dispatch (decision:
	                      // focus loss / mouse-leave clears pressed+hovered)
}

Frame_Result :: struct {
	changed:      bool,   // anything new, moved, or resized this frame
	damage:       []Rect, // damaged regions, valid until the next frame_begin
	next_wake_ms: u32,    // ms until the engine's nearest registered deadline
	                      // (tween/transient/hover timers, §8); max(u32) = none
	                      // pending, so the host may sleep until input or wake()
	cursor:       Cursor_Kind, // the hovered instance's resolved cursor
	                           // (.Arrow when nothing is hovered); the host
	                           // applies it when it changes
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
		// The base copy is a snapshot: clone the reference-typed
		// fields so the new unit owns its copies (see store_spans).
		rec.style.text_spans = clone_spans(rec.style.text_spans)
		if len(rec.style.text) > 0 {
			rec.style.text = strings.clone(rec.style.text)
		}
	}
	append(&g.units, rec)
	out^ = u
	// decl = {} is a no-op merge (set_many skips the generation bump when no
	// explicit fields were set).
	set_many(u, decl)
	// decl.groups registers membership in those groups: the locate-only
	// half of mint (§3.7). Nothing is applied by joining.
	for gr in decl.groups {
		group_add_member(gr, u, ALL_FIELDS)
	}
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

// style_set_any writes one field of a bare style (no unit bookkeeping):
// set_any's switch, reused where a style is assembled off-unit
// (group_set's tween targets).
@(private)
style_set_any :: proc(s: ^Style, f: Field, v: any) {
	switch f {
	case .Color:         s.color         = must(v, Color)
	case .Font_Color:    s.font_color    = must(v, Color)
	case .Border_Color:  s.border_color  = must(v, Color)
	case .Text:          s.text          = must(v, string)
	case .Font:          s.font          = must(v, Font_Handle)
	case .Font_Size:     s.font_size     = must(v, f32)
	case .Font_Weight:   s.font_weight   = must(v, Font_Weight)
	case .Font_Slant:    s.font_slant    = must(v, Font_Slant)
	case .Text_Spans:    s.text_spans    = must(v, []Text_Span)
	case .Text_Wrap:     s.wrap          = must(v, Text_Wrap)
	case .Whitespace:    s.whitespace    = must(v, Whitespace)
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
	case .Cursor:       s.cursor       = must(v, Cursor_Kind)
	case .Scroll_Chain: s.scroll_chain = must(v, bool)
	}
}

@(private)
// clone_spans copies a spans slice into engine-owned storage (nil
// stays nil).
clone_spans :: proc(src: []Text_Span) -> []Text_Span {
	if src == nil {
		return nil
	}
	out := make([]Text_Span, len(src))
	copy(out, src)
	return out
}

// store_spans / store_text write a reference-typed field into a
// unit-owned style slot, freeing the previously owned copy. A Style
// is an owned-values store, but a string or slice is a borrow of the
// caller's memory: storing the header leaves the unit pointing into
// a frame that may already be dead. (This bit in production shape:
// apps mint inside an init proc that returns, and at -o:none the
// literal temporaries are reused at once, so every span silently
// vanished; -o:speed's layout luck masked it, and the test suite
// runs -o:speed.) Every write of Text / Text_Spans into a unit's
// persistent style goes through these.
store_spans :: proc(dst: ^[]Text_Span, src: []Text_Span) {
	if dst^ != nil {
		delete(dst^)
	}
	dst^ = clone_spans(src)
}

store_text :: proc(dst: ^string, src: string) {
	if len(dst^) > 0 {
		delete(dst^)
	}
	dst^ = strings.clone(src)
}

// copy_field_owned is copy_field for unit-bound writes: the two
// reference-typed fields clone (see store_spans), everything else
// copies as usual. Frame-lived destinations (the eff merge in
// resolve_styles) keep plain copy_field — aliasing is safe there.
copy_field_owned :: proc(dst, src: ^Style, f: Field) {
	#partial switch f {
	case .Text:
		store_text(&dst.text, src.text)
	case .Text_Spans:
		store_spans(&dst.text_spans, src.text_spans)
	case:
		copy_field(dst, src, f)
	}
}

set_any :: proc(u: Unit, f: Field, v: any) {
	cancel_glide_fields(u, Fields{f}) // an explicit write supersedes a glide
	rec := &g.units[int(u)]
	#partial switch f {
	case .Text:
		store_text(&rec.style.text, must(v, string))
	case .Text_Spans:
		store_spans(&rec.style.text_spans, must(v, []Text_Span))
	case:
		style_set_any(&rec.style, f, v)
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
	apply_opt(&s.font_color, decl.font_color)
	apply_opt(&s.border_color, decl.border_color)
	if v, ok := decl.text.?; ok {
		store_text(&s.text, v)
	}
	apply_opt(&s.font, decl.font)
	apply_opt(&s.font_size, decl.font_size)
	apply_opt(&s.font_weight, decl.font_weight)
	apply_opt(&s.font_slant, decl.font_slant)
	if v, ok := decl.text_spans.?; ok {
		store_spans(&s.text_spans, v)
	}
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
	apply_opt(&s.whitespace, decl.whitespace)
	apply_opt(&s.ellipsis, decl.ellipsis)
	apply_opt(&s.overflow, decl.overflow)
	apply_opt(&s.overlay_color, decl.overlay_color)
	apply_opt(&s.overlay_border_color, decl.overlay_border_color)
	apply_opt(&s.overlay_border_width, decl.overlay_border_width)
	apply_opt(&s.cursor, decl.cursor)
	apply_opt(&s.scroll_chain, decl.scroll_chain)

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
		cancel_glide_fields(u, fields)
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

// Placement picks where a popup root sits relative to its anchor
// (§3.19). At ignores the anchor and uses Popup_Opts.at; Center
// ignores it too and centers on the viewport (dialogs).
Placement :: enum {
	Below,
	Above,
	Left,
	Right,
	At,
	Center,
}

// Popup_Opts tunes a popup root (§3.19). The zero value is a plain
// menu: non-modal, light-dismiss on, flush against the anchor.
Popup_Opts :: struct {
	modal: bool, // absorb outside presses; scope Tab traversal;
	             // focus moves in on open, restores on close
	stay:  bool, // no light dismiss: outside presses and Esc leave
	             // it open (toasts, pinned panels)
	gap:   f32,  // space between anchor and popup, on the
	             // placement axis
	at:    Vec2, // the placement point for Placement.At
}

// begin_popup declares an overlay root (§3.19): a container whose
// node is parented to the layer, not to the declaring code's
// container — a dropdown declared inside a scrolled column escapes
// its ancestors' layout and clips, and its identity (hashed against
// the layer seed) is stable wherever it is declared from. Children
// declared inside lay out normally within the popup root.
//
// The root is sized by its own style with one exception: Fit (and
// Grow, which has no parent to grow into) resolves to the content
// size. Placement is resolved in pass F against the anchor's last
// committed rect: Below/Above/Left/Right sit against the anchor's
// edge (plus opts.gap), flipping to the opposite side when the
// content would leave the viewport there and fits on the other
// side, and clamped into the viewport on the cross axis.
//
// open == false means the anchor instance has no committed rect
// (it was never shown, or left the tree): declare children anyway
// or not, exactly like begin — the subtree is culled either way.
@(deferred_out = end)
begin_popup :: proc(
	unit: Unit,
	anchor: Instance,
	placement: Placement,
	opts: Popup_Opts = {},
	key: Key = 0,
	with: With = {},
) -> (
	i:    Instance,
	open: bool,
) {
	anchor_ok := placement == .At || placement == .Center || anchor in g.instances
	// A popup declared from inside a culled subtree stays culled,
	// like any other declaration there.
	decl_culled := len(g.stack) > 0 && g.nodes[g.stack[len(g.stack) - 1]].culled
	ord := g.popup_ordinal
	g.popup_ordinal += 1
	new_inst, idx := declare_as(
		unit, key, with, true, -1, ord, POPUP_PARENT_SEED, decl_culled || !anchor_ok,
	)
	i = new_inst
	nd := &g.nodes[idx]
	nd.is_popup = true
	nd.popup_anchor = anchor
	nd.popup_place = placement
	nd.popup_at = opts.at
	nd.popup_gap = opts.gap
	append(&g.popups, Popup_Rec{root_idx = idx, id = i, modal = opts.modal, stay = opts.stay})
	open = anchor_ok && !decl_culled
	append(&g.stack, idx)
	append(&g.child_counts, 0)
	return i, open
}

// dismiss_requested reports that this frame's dispatch asked for
// the popup root's dismissal (§3.19): a left press outside it (or
// outside every popup above the pressed one), or Esc. The engine
// owns no open state — the query is the whole mechanism: stop
// declaring the popup and it is closed. Valid for the one declare
// following the dispatch, like clicked.
dismiss_requested :: proc(i: Instance) -> bool {
	_, ok := g.dismiss_flags[i]
	return ok
}

frame_begin :: proc(input: Input, dt: f32) {
	// Engine time advances by the real frame delta; scheduling
	// deadlines are stamped against it.
	g.time_ms += u64(dt * 1000 + 0.5)
	// A wake() since the last frame is consumed here — the frame it
	// asked for is this one, and pending changes are discovered by
	// the ordinary diff machinery below.
	if sync.atomic_load(&g.wake_requested) {
		sync.atomic_store(&g.wake_requested, false)
	}
	// Input dispatch runs FIRST, against last frame's committed tree
	// (nodes/lay/pick_clip still hold it). Queries during this frame's
	// declare answer from that hit test: one frame of latency (§3.8).
	dispatch_input(input, dt)
	// resolve_spans copies per declare; free them before dropping the nodes,
	// or every frame using text_spans leaks.
	for nd in g.nodes {
		delete(nd.spans)
	}
	clear(&g.nodes)
	clear(&g.popups) // last frame's list; dispatch already read it
	g.popup_ordinal = 0
	clear(&g.stack)
	clear(&g.child_counts)
	clear(&g.lay)
	clear(&g.pick_clip)
	clear(&g.wrap_list)
	clear(&g.damage)
	clear(&g.draw_cmds)
	g.viewport = input.viewport
	g.dt = dt
	// Cold units, the instance map, and the text cache persist across frames.
}

// frame_end runs the resolve pass: state overlays, layout, damage.
// After it returns, queries (rect) read THIS frame's resolved data.
frame_end :: proc() -> Frame_Result {
	// The mutation layer lands first (§3.16): glides step, edit diffs
	// apply (winning over glides on the fields they changed), expired
	// transients are swept — all before resolution reads any style.
	step_tweens()
	apply_edits()
	sweep_transients()
	resolve_styles()
	layout_pass(g.viewport)
	// Focus survival (§3.17): focus cannot outlive its instance. If
	// the focused instance left the tree this frame or became
	// disabled, focus clears (set_focus_id also cancels a pending
	// key-press on it). Focusable is NOT a condition: it gates
	// traversal participation, while programmatic focus() may
	// target any instance.
	if g.focus_id != 0 {
		alive := false
		for i in 0 ..< len(g.nodes) {
			if g.nodes[i].identity == g.focus_id {
				alive = !g.disabled_flags[i]
				break
			}
		}
		if !alive {
			set_focus_id(0)
		}
	}
	// Modal focus (§3.19): when the topmost modal popup changes,
	// focus follows the session. Opening (from no modal) snapshots
	// the current focus and moves it to the modal's first traversal
	// candidate; closing (to no modal) restores the snapshot if it
	// is still live. A modal swapped for another keeps the original
	// snapshot and just re-grabs.
	{
		top_modal: Instance = 0
		top_root := -1
		for rec in g.popups {
			if rec.modal {
				top_modal = rec.id
				top_root = rec.root_idx
			}
		}
		if top_modal != g.modal_prev_id {
			if g.modal_prev_id == 0 && top_modal != 0 {
				g.modal_saved_focus = g.focus_id
			}
			if top_modal != 0 && top_root >= 0 {
				for idx in top_root ..= g.subtree_end[top_root] {
					if focus_candidate(idx) {
						set_focus_id(g.nodes[idx].identity)
						break
					}
				}
			} else if top_modal == 0 {
				// Session over. If the snapshot is still live it
				// takes focus back; if not, the survival check
				// above has already cleared focus out of the dead
				// modal subtree, and nothing more is owed.
				saved := g.modal_saved_focus
				g.modal_saved_focus = 0
				if saved != 0 {
					for idx in 0 ..< len(g.nodes) {
						if g.nodes[idx].identity == saved && !g.disabled_flags[idx] {
							set_focus_id(saved)
							break
						}
					}
				}
			}
			g.modal_prev_id = top_modal
		}
	}
	// Interaction-driven restyles don't pass through the declaration diff:
	// the affected instances' committed rects are the damage. (A restyle
	// that changed layout already damaged old ∪ new in pass F.)
	if g.input_dirty {
		for id in g.affected {
			if r, ok := g.instances[id]; ok {
				append(&g.damage, r)
			}
		}
		g.input_dirty = false
	}
	// Clearing dirty is O(touched), not O(units) — §8.
	for u in g.touched {
		g.units[int(u)].dirty = {}
	}
	clear(&g.touched)
	update_animation_wake()
	res := Frame_Result{
		changed      = g.frame_index == 0 || len(g.damage) > 0,
		damage       = g.damage[:],
		next_wake_ms = compute_next_wake(),
		cursor       = current_cursor(),
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

// mouse_position reads the cursor position as of this frame's
// dispatch (one frame of latency, like every query). ok = false
// when the cursor is outside the window. Its popup-layer use:
// anchoring an .At popup where the user just clicked (§3.19).
mouse_position :: proc() -> (p: Vec2, ok: bool) {
	return g.pointer_pos, g.pointer_valid
}

// ============ interaction queries ============
// Answered from this frame's dispatch (the hit test of last frame's tree,
// run at frame_begin). All three bubble: an instance counts when it is the
// target or an ancestor of the target, so a button answers for clicks on
// its label. Semantics detail lives in input.odin.

// hovered reports the cursor is over the instance (or a descendant).
hovered :: proc(i: Instance) -> bool {
	return chain_contains(g.hover_chain[:], i)
}

// pressed reports a button was pressed on the instance (or a descendant)
// and is still held — capture keeps this true wherever the cursor goes.
pressed :: proc(i: Instance) -> bool {
	for b in Mouse_Button {
		if chain_contains(g.press_chains[b][:], i) {
			return true
		}
	}
	// A Space/Enter capture on a focused descendant presses its
	// ancestors too, exactly like a pointer capture.
	return chain_contains(g.key_press_chain[:], i)
}

// clicked reports a left-button press on the instance (or a descendant)
// completed with a release over it, as of this frame's dispatch. True for
// exactly one declare: the one after the release.
clicked :: proc(i: Instance) -> bool {
	return chain_contains(g.clicked_chain[:], i)
}

// hover_duration is how long the cursor has been inside i's subtree, in
// seconds: i's own entry time into the hover chain, so a button reports
// one continuous duration whether the cursor is over its body or its
// label. 0 whenever i is not in the current chain. Tooltip delays read
// this.
// HOVER_REFRESH_MS: while an app displays a live hover duration, the
// engine refreshes it at ~20 Hz. Coarse on purpose — a duration readout
// is glanceable text, not an animation.
HOVER_REFRESH_MS :: 50

hover_duration :: proc(i: Instance) -> f32 {
	if since, ok := g.hover_since[i]; ok {
		// Displaying a duration is a standing request for refresh frames
		// while the hover lasts (§8's hover thresholds): arm the next
		// one, or a sleeping host loop would freeze the readout. An app
		// that never asks never pays; an instance that is not hovered
		// arms nothing.
		schedule_wake_in(HOVER_REFRESH_MS)
		return g.hover_clock - since
	}
	return 0
}

// focused reports i holds programmatic keyboard focus (see focus).
focused :: proc(i: Instance) -> bool {
	return i != 0 && i == g.focus_id
}

// focus sets keyboard focus programmatically; pass Instance(0) to
// clear. Focus also moves by traversal (Tab) and by pointer press on
// a focusable instance (§3.17). Moving focus cancels any pending
// key-press (Space/Enter) capture.
focus :: proc(i: Instance) {
	set_focus_id(i)
}

// focus_next / focus_prev move keyboard focus one step along the tab
// order — declaration order over the focusable instances of the last
// completed tree — wrapping at the ends. The same walk Tab runs at
// dispatch; calling it during declare moves focus immediately (this
// frame's already-dispatched keys/text keep the routing they were
// given at dispatch).
focus_next :: proc() {
	traverse_focus(1)
}

focus_prev :: proc() {
	traverse_focus(-1)
}

// input_text returns the text committed to i this frame (host text
// input: typed characters, dead-key results, IME commits), or "".
// Text routes to the instance that held focus at dispatch, and only
// to it. Declare-scoped: read it during declare, like clicked.
input_text :: proc(i: Instance) -> string {
	if i == 0 || i != g.text_target || len(g.frame_text) == 0 {
		return ""
	}
	return string(g.frame_text[:])
}

// input_keys returns i's key events for this frame — downs (repeats
// included) and ups, oldest first — or an empty slice. Routing as
// input_text. The core's own keys never arrive: traversal's Tab is
// consumed at dispatch. The slice is rebuilt on each call; consume
// it before calling again.
input_keys :: proc(i: Instance) -> []Key_Event {
	clear(&g.keys_scratch)
	if i == 0 || i != g.keys_target {
		return g.keys_scratch[:]
	}
	for k in 0 ..< g.frame_key_count {
		if !g.key_consumed[k] {
			append(&g.keys_scratch, g.frame_keys[k])
		}
	}
	return g.keys_scratch[:]
}

// ============ scrolling ============

// WHEEL_UNIT_PX: one wheel unit (one notch; trackpads report fractions)
// scrolls this many DIP — roughly three lines of default text.
WHEEL_UNIT_PX :: 48

// scroll_offset reports i's scroll offset in DIP: the offset the last
// frame rendered with. {0, 0} when i is not a scrollable container or
// has never scrolled. Pass F re-clamps the stored offset to the live
// scroll range every frame, so a shrinking content pulls it back in.
scroll_offset :: proc(i: Instance) -> Vec2 {
	if i == 0 {
		return {0, 0}
	}
	return g.scroll_off[i]
}

// scroll_to sets i's scroll offset in DIP (back-to-top is
// scroll_to(i, {0, 0})). The stored value is clamped to the scrollable
// range when the next frame renders — the same range the wheel clamps
// against — so an out-of-range request lands on the nearest end.
scroll_to :: proc(i: Instance, offset: Vec2) {
	if i == 0 {
		return
	}
	if g.scroll_off == nil {
		g.scroll_off = make(map[Instance]Vec2)
	}
	g.scroll_off[i] = offset
}

// ============ text measurement backend ============
// Hooks the app sets to replace the mock metrics with real shaping.
// niello/sdl provides adapters over the nui_* FFI; the app wires them:
//
//   niello.measure_word_hook  = sdl.hook_measure_word
//   niello.line_height_hook = sdl.hook_line_height
//
// nil = mock metrics (proportional to size, see text.odin). Hooks fire only
// on word-cache miss.
measure_word_hook: proc(font: Font_Handle, weight: Font_Weight, slant: Font_Slant, size: f32, text: string) -> f32
line_height_hook: proc(font: Font_Handle, weight: Font_Weight, slant: Font_Slant, size: f32) -> f32

// ============ scheduling ============
// The idle-CPU contract (§3.3): changes are found by the next SCHEDULED
// frame. frame_end reports the nearest engine deadline as next_wake_ms
// and the host blocks on OS events until then. wake() is the escape
// hatch for work that happens off the frame thread.

// wake_hook, when set, runs at the end of wake(). Host glue uses it to
// interrupt its event wait (niello/sdl pushes an SDL user event). Set
// once at startup, like the measure hooks. nil = wake() only flags the
// core, and discovery waits for the next natural wake.
wake_hook: proc()

// wake schedules a frame from outside the loop — the one core entry
// point that is safe to call from any thread. It flags the request
// atomically and pokes the host through wake_hook; the frame it asked
// for discovers pending changes through the ordinary diff machinery.
wake :: proc() {
	sync.atomic_store(&g.wake_requested, true)
	if wake_hook != nil {
		wake_hook()
	}
}

// schedule_wake_in registers an engine deadline ms from now, in engine
// time; frame_end reports the nearest pending deadline as
// next_wake_ms. Engine subsystems register here — tweens, transients,
// hover-delay thresholds (§8). Not app-facing API: apps use wake().
// Until those subsystems land, the registry stays empty in a static
// UI and next_wake_ms is max(u32).
schedule_wake_in :: proc(ms: u32) {
	at := g.time_ms + u64(ms)
	// The earliest pending deadline wins — except a deadline that is
	// already due: it fires with this frame either way, so a same-frame
	// registration (a recurring refresh re-arming itself) supersedes
	// the corpse instead of losing to it.
	if !g.wake_deadline_set || g.wake_deadline <= g.time_ms || at < g.wake_deadline {
		g.wake_deadline = at
		g.wake_deadline_set = true
	}
}

@(private)
compute_next_wake :: proc() -> u32 {
	if !g.wake_deadline_set {
		return max(u32)
	}
	if g.wake_deadline <= g.time_ms {
		// Due: the frame that just ran IS the scheduled frame. Whatever
		// registered the deadline re-registers during declare if it is
		// still active.
		g.wake_deadline_set = false
		return max(u32)
	}
	d := g.wake_deadline - g.time_ms
	return u32(min(d, u64(max(u32))))
}

// ============ groups ============
// A group is an address book: a list of (unit, field-mask) members used
// to LOCATE units for a later broadcast (§3.7). Membership itself
// writes nothing — a unit's birth values come from its base at mint,
// never from joining a group — and there is no retained patch: a
// broadcast reaches only the members present when it is issued.
// group_set is the only group write; it copies the value into each
// member's owned style through the same path as set, skipping fields
// outside the member's mask or pinned on that unit. Among explicit
// writes the last one wins, determined entirely by call order.

// group_new creates an empty group. The name is debug metadata.
group_new :: proc(name: string = "") -> Group {
	if len(g.groups) == 0 {
		append(&g.groups, Group_Rec{name = "NO_GROUP"}) // sentinel at index 0
	}
	append(&g.groups, Group_Rec{name = name})
	return Group(len(g.groups) - 1)
}

// group_add registers units as members. The plain form masks in every
// field; the masked form scopes the membership to the given fields.
// Adding a unit that is already a member widens its mask.
group_add :: proc{group_add_all, group_add_masked}

group_add_all :: proc(grp: Group, units: ..Unit) {
	for u in units {
		group_add_member(grp, u, ALL_FIELDS)
	}
}

group_add_masked :: proc(grp: Group, fields: Fields, units: ..Unit) {
	for u in units {
		group_add_member(grp, u, fields)
	}
}

// group_merge copies sub's members into g (flattened: g gains the
// members themselves, not a reference to sub). A unit already in g
// unions the masks. sub is unchanged and stays independent.
group_merge :: proc(grp, sub: Group) {
	if grp == sub {
		return
	}
	_ = group_rec(grp)
	_ = group_rec(sub)
	n := len(g.groups[int(sub)].members)
	for i in 0 ..< n {
		m := g.groups[int(sub)].members[i]
		group_add_member(grp, m.unit, m.fields)
	}
}

// group_set broadcasts one field value to every member whose mask
// includes it and whose unit has not pinned it. ms == 0 lands the
// value immediately; ms > 0 glides each member to it over ms through
// the tween engine (§3.16), starting from wherever the member is.
group_set :: proc(grp: Group, f: Field, v: $T, ms: u32 = 0) {
	rec := group_rec(grp)
	for m in rec.members {
		if f not_in m.fields {
			continue
		}
		if f in g.units[int(m.unit)].pinned {
			continue
		}
		if ms == 0 {
			set(m.unit, f, v)
		} else {
			target := g.units[int(m.unit)].style
			style_set_any(&target, f, v)
			start_glide(m.unit, Fields{f}, &target, ms)
		}
	}
}

// pin exempts the given fields of a unit from group broadcasts; unpin
// re-admits them. Pinning changes no style value — it only gates future
// group_set calls, so it bumps no generation and damages nothing.
//
// Reach for pin only when the reason a value must not change on
// broadcast is directly obvious — the danger-red action that shares a
// group with ordinary actions. If you find yourself pinning routinely,
// the group is drawn wrong: split it instead.
pin :: proc(u: Unit, fields: Fields) {
	assert(int(u) >= 1 && int(u) < len(g.units), "niello.pin: unit is not minted")
	g.units[int(u)].pinned += fields
}

unpin :: proc(u: Unit, fields: Fields) {
	assert(int(u) >= 1 && int(u) < len(g.units), "niello.unpin: unit is not minted")
	g.units[int(u)].pinned -= fields
}

@(private)
group_rec :: proc(grp: Group) -> ^Group_Rec {
	assert(int(grp) >= 1 && int(grp) < len(g.groups), "niello: group handle is not a live group")
	return &g.groups[int(grp)]
}

@(private)
group_add_member :: proc(grp: Group, u: Unit, fields: Fields) {
	assert(int(u) >= 1 && int(u) < len(g.units), "niello.group_add: unit is not minted")
	rec := group_rec(grp)
	for &m in rec.members {
		if m.unit == u {
			m.fields += fields // already a member: widen the mask
			return
		}
	}
	append(&rec.members, Group_Member{unit = u, fields = fields})
}

// ============ mutation layer: animation, bulk writes, pulses (§3.16) ============
// The engine lives in animate.odin. Three targets, three verbs:
// set/tween/edit/propagate write UNITS (every occurrence), transient
// pulses ONE INSTANCE, and the group forms broadcast either way.

// tween glides u toward the unit `to`'s style over ms, for the masked
// fields: animatable fields interpolate (one house curve, cubic
// ease-out), the rest snap at t=0. Both endpoints snapshot at the
// call — `from` is u's live style (mid-glide values included, so
// retargeting never jumps) and `to` is the target's style as of now;
// if the target unit changes later, the glide does not chase it. A
// new tween steals its masked fields from any glide running on u, and
// an explicit write (set/set_many/edit/group_set) to a gliding field
// cancels that field's glide. ms == 0 is an immediate masked copy.
tween :: proc(u: Unit, to: Unit, ms: u32, fields: Fields = ALL_FIELDS) {
	assert(int(u) >= 1 && int(u) < len(g.units), "niello.tween: unit is not minted")
	assert(int(to) >= 1 && int(to) < len(g.units), "niello.tween: target unit is not minted")
	target := g.units[int(to)].style
	start_glide(u, fields, &target, ms)
}

// group_tween broadcasts tween: every member glides toward `to`'s
// style, gated per member by its mask (intersected with fields) and
// its pins — the same gates as group_set.
group_tween :: proc(grp: Group, to: Unit, ms: u32, fields: Fields = ALL_FIELDS) {
	assert(int(to) >= 1 && int(to) < len(g.units), "niello.group_tween: target unit is not minted")
	rec := group_rec(grp)
	target := g.units[int(to)].style
	for m in rec.members {
		eff := fields & m.fields
		for f in g.units[int(m.unit)].pinned {
			eff -= Fields{f}
		}
		start_glide(m.unit, eff, &target, ms)
	}
}

// edit is the bulk escape hatch: it returns a pointer to a shadow copy
// of u's style. Mutate it freely (any fields, any order); at frame_end
// the engine diffs the shadow against the style as it was when edit
// was called and writes only the fields that actually changed — an
// intervening set on an untouched field is never clobbered. Repeated
// edit calls in one frame return the same shadow. The pointer is
// valid until frame_end; holding it across frames is a contract
// violation.
edit :: proc(u: Unit) -> ^Style {
	assert(int(u) >= 1 && int(u) < len(g.units), "niello.edit: unit is not minted")
	if g.edits == nil {
		g.edits = make(map[Unit]^Edit_State)
	}
	if es, ok := g.edits[u]; ok {
		return &es.shadow
	}
	es := new(Edit_State)
	es.base = g.units[int(u)].style
	es.shadow = es.base
	g.edits[u] = es
	return &es.shadow
}

// propagate pushes proto's current values to the units minted from
// it, for the masked fields each derived unit has never explicitly
// set: birth values come from the base snapshot at mint, and this is
// the opt-in push that refreshes them (§3.3). Propagated writes do not
// mark fields explicit, so values keep flowing on later calls. One
// pass in mint order makes the push transitive — a derived unit's
// refreshed values flow to its own derived units in the same call.
// Pins do not gate propagate (they gate group writes), and a field
// with a glide in flight on the target unit is skipped — the glide is
// the more specific intent; call propagate again after it lands.
propagate :: proc(proto: Unit, fields: Fields) {
	assert(int(proto) >= 1 && int(proto) < len(g.units), "niello.propagate: unit is not minted")
	if fields == {} {
		return
	}
	updated: [dynamic]Unit
	defer delete(updated)
	for idx in 1 ..< len(g.units) {
		rec := &g.units[idx]
		if rec.proto == NO_UNIT {
			continue
		}
		src_unit := rec.proto
		if src_unit != proto {
			flowed := false
			for x in updated {
				if x == src_unit {
					flowed = true
					break
				}
			}
			if !flowed {
				continue
			}
		}
		u := Unit(idx)
		src := &g.units[int(src_unit)].style
		wrote := Fields{}
		for f in fields {
			if f in rec.explicit {
				continue
			}
			if field_gliding(u, f) {
				continue
			}
			if field_equal(&rec.style, src, f) {
				continue
			}
			copy_field_owned(&rec.style, src, f)
			wrote += Fields{f}
		}
		if wrote != {} {
			touch_unmarked(u, wrote)
			append(&updated, u)
		}
	}
}

// transient fires a one-shot pulse on ONE instance: the style unit's
// explicitly-set paint fields blend over the instance's resolved style
// — in over in_ms, back out over out_ms, then gone. Only paint fields
// participate (TRANSIENT_FIELDS): a pulse never relayouts the tree.
// Re-firing the IDENTICAL pulse (same style unit and durations) while
// it is still in flight is a no-op, so the natural pattern
// `if hovered(i) { transient(i, ...) }` — which calls this every frame
// for the whole hover — plays the pulse instead of pinning its
// envelope at zero by restarting it each frame. A fire with different
// parameters, or after the pulse has ended, starts a new one.
// Instance 0 is ignored.
transient :: proc(i: Instance, style: Unit, in_ms, out_ms: u16) {
	if i == 0 {
		return
	}
	assert(int(style) >= 1 && int(style) < len(g.units), "niello.transient: style unit is not minted")
	if prev, ok := g.transients[i]; ok {
		if prev.src == style && prev.in_ms == in_ms && prev.out_ms == out_ms {
			if _, active := transient_k(&prev); active {
				return
			}
		}
	}
	src := &g.units[int(style)]
	fields := src.explicit & TRANSIENT_FIELDS
	if fields == {} {
		return
	}
	if g.transients == nil {
		g.transients = make(map[Instance]Transient_Rec)
	}
	g.transients[i] = Transient_Rec{
		fields   = fields,
		style    = src.style,
		src      = style,
		start_ms = g.time_ms,
		in_ms    = in_ms,
		out_ms   = out_ms,
	}
}

// ============ not yet implemented (roadmap, in doc order) ============
// Each is a subsystem, not a stub: declaring them now would promise behavior
// the mock can't deliver.
//
//   focus:      traversal + text input (focused/focus work; seams reserved)
