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

import "base:runtime"
import "core:strings"
import "core:sync"

// ============ math ============

Vec2 :: [2]f32

Rect :: struct {
	pos:  Vec2,
	size: Vec2,
}

INF :: max(f32) // standing in for +infinity

// ============ debug builds ============

// NIELLO_DEBUG is the build gate for all debug tooling (TODO #18:
// the frame snapshot, the overflow report, the debugger window).
// Build with -define:NIELLO_DEBUG=true to get it; without the
// define, the tooling compiles out entirely — no API, no
// per-frame work, no state. (ODIN_DEBUG was rejected as the gate:
// it is false under a plain `odin run`, the everyday dev loop.)
NIELLO_DEBUG :: #config(NIELLO_DEBUG, false)

// ============ identity ============

// NO_UNIT is the §8 cold-store sentinel (index 0). Passing it as mint's base
// means "no prototype: start from default_style()".
NO_UNIT :: Unit(0)

// NO_GROUP is the group store's sentinel (index 0), mirroring NO_UNIT.
NO_GROUP :: Group(0)

Unit     :: distinct u64 // cold: minted once, owns its values (slot index + generation; see unit_live)
Instance :: distinct u64 // hot: one on-screen occurrence = hash(parent, unit, key)
Group    :: distinct u32 // cold: broadcast list of (unit, fields)
Key      :: distinct u64 // explicit identity (list items); 0 = the call site

// ============ styling ============

Field :: enum u8 {
	Color, Font_Color, Border_Color,
	Text, Font, Font_Size, Font_Weight, Font_Slant, Text_Wrap, Whitespace, Ellipsis, Justify,
	Padding, Gap, Corner_Radius, Opacity,
	Layout, Align, Size, Scroll, Overflow,
	Border_Width, Overlay_Color, Overlay_Border_Color, Overlay_Border_Width,
	Text_Spans, Cursor, Scroll_Chain, Smooth_Scroll, Smooth_Ms,
	Overscroll, Overscroll_Px,
	Image, Image_Fit, Image_Interp,
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
	.Text, .Font, .Font_Size, .Font_Weight, .Font_Slant, .Text_Wrap, .Whitespace, .Ellipsis, .Justify,
	.Padding, .Gap, .Corner_Radius, .Opacity,
	.Layout, .Align, .Size, .Scroll, .Overflow,
	.Border_Width, .Overlay_Color, .Overlay_Border_Color, .Overlay_Border_Width,
	.Text_Spans, .Cursor, .Scroll_Chain, .Smooth_Scroll, .Smooth_Ms,
	.Overscroll, .Overscroll_Px,
	.Image, .Image_Fit, .Image_Interp,
}

// VISUAL_FIELDS is ALL_FIELDS minus the fields that steer behavior
// without reaching the draw list — the exclusion the old content
// hash documented: Cursor is host state; Scroll_Chain, the Smooth
// pair and the Overscroll pair steer dispatch and glides. A write
// touching only these must not repaint, so the per-unit visual
// generation (the §5 stamps, state.odin) advances only on
// VISUAL_FIELDS writes. Written out in full, like ALL_FIELDS.
VISUAL_FIELDS :: Fields{
	.Color, .Font_Color, .Border_Color,
	.Text, .Font, .Font_Size, .Font_Weight, .Font_Slant, .Text_Wrap, .Whitespace, .Ellipsis, .Justify,
	.Padding, .Gap, .Corner_Radius, .Opacity,
	.Layout, .Align, .Size, .Scroll, .Overflow,
	.Border_Width, .Overlay_Color, .Overlay_Border_Color, .Overlay_Border_Width,
	.Text_Spans,
	.Image, .Image_Fit, .Image_Interp,
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
	kind:   Sizing_Kind,
	value:  f32, // Fixed: px; Percent: fraction of parent inner size
	min:    f32, // clamp floor, default 0 (waterfill never goes below max(min, min_c))
	max:    f32, // clamp ceiling, default INF
	weight: f32, // Grow: share of the leftover relative to sibling growers
	             // (grow() sets 1; 0 takes no share)
	priority: i8, // Fit / Grow: when the parent runs short on this axis,
	              // lower priorities give way first; higher hold their
	              // size longer. Default 0 (all equal: shared fairly).
}

Size :: [2]Sizing // indexed by axis

fixed :: proc(v: f32, min: f32 = 0, max: f32 = INF) -> Sizing {
	assert(v == v && min == min && max == max, "niello.fixed: sizing values must not be NaN")
	assert(min <= max, "niello.fixed: min must not exceed max")
	return Sizing{kind = .Fixed, value = v, min = min, max = max}
}

percent :: proc(v: f32, min: f32 = 0, max: f32 = INF) -> Sizing {
	assert(v == v && min == min && max == max, "niello.percent: sizing values must not be NaN")
	assert(min <= max, "niello.percent: min must not exceed max")
	return Sizing{kind = .Percent, value = v, min = min, max = max}
}

// fit sizes to the content, bounded by min and max. priority decides
// who gives way when the parent runs short of space (see Sizing).
fit :: proc(min: f32 = 0, max: f32 = INF, priority: i8 = 0) -> Sizing {
	assert(min == min && max == max, "niello.fit: sizing values must not be NaN")
	assert(min <= max, "niello.fit: min must not exceed max")
	return Sizing{kind = .Fit, min = min, max = max, priority = priority}
}

// grow takes a share of the space its parent has left over on the main
// axis, in proportion to weight: two children grow(2) and grow() split
// it 2:1. The share comes on top of the child's content size, and stops
// at max. Shrinking is not weighted: a deficit is taken fairly from every
// shrinkable child of the same priority (see Sizing.priority). On the
// cross axis a grow child fills the parent's inner box.
grow :: proc(weight: f32 = 1, min: f32 = 0, max: f32 = INF, priority: i8 = 0) -> Sizing {
	assert(weight == weight && min == min && max == max, "niello.grow: sizing values must not be NaN")
	assert(weight >= 0, "niello.grow: weight must not be negative")
	assert(min <= max, "niello.grow: min must not exceed max")
	return Sizing{kind = .Grow, min = min, max = max, weight = weight, priority = priority}
}

// ============ style shorthands ============

// The shorthands are contextless, so they also work in global variable
// initializers. Odin evaluates no procedure at compile time, though: a
// constant (`BG :: …`) still spells its color as a Color{r, g, b, a}
// literal.

// size pairs a width and a height: size(grow(), fixed(40)).
size :: proc "contextless" (w, h: Sizing) -> Size {
	return Size{w, h}
}

// rgb builds a Color from a 0xRRGGBB literal: rgb(0x1e2028), or
// rgb(0x000000, 120) for a translucent black.
rgb :: proc "contextless" (hex: u32, alpha: u8 = 255) -> Color {
	return Color{u8(hex >> 16), u8(hex >> 8), u8(hex), alpha}
}

// Padding is [left, top, right, bottom]. pad gives all four sides the
// same value, pad_xy one value horizontally and one vertically, and
// pad_each names every side.
pad :: proc "contextless" (all: u16) -> [4]u16 {
	return [4]u16{all, all, all, all}
}

pad_xy :: proc "contextless" (x, y: u16) -> [4]u16 {
	return [4]u16{x, y, x, y}
}

pad_each :: proc "contextless" (left, top, right, bottom: u16) -> [4]u16 {
	return [4]u16{left, top, right, bottom}
}

// align is Style.align, [x, y]: align(.Start, .Center) puts children at
// the left, vertically centered.
align :: proc "contextless" (x, y: Align_Kind) -> [2]Align_Kind {
	return [2]Align_Kind{x, y}
}

CENTER :: [2]Align_Kind{.Center, .Center}

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
	padding:       [4]u16, // [left, top, right, bottom]; see pad / pad_xy
	gap:           u16,
	border_width:  u16, // paint-only; drawn inset within the rect
	corner_radius: u8,
	opacity:       u8,
	layout:        Layout,
	size:          Size,
	scroll:        Scroll,
	align:         [2]Align_Kind, // [x, y], for flow and anchored children alike
	wrap:          Text_Wrap,     // default .None
	whitespace:    Whitespace,    // default .Collapse (§3.18)
	ellipsis:      bool,          // default true; paint-time trim when no-wrap text overflows
	justify:       bool,          // wrapped text: spread each line but a paragraph's last to the full width
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
	smooth_scroll: bool,       // wheel glides to its target over smooth_ms
	                           // instead of landing instantly (§3.21)
	smooth_ms:    u16,         // glide duration when smooth_scroll is on;
	                           // also the overscroll spring's duration
	overscroll:   bool,        // wheel may pull past the range ends with
	                           // resistance, then springs back (§3.22)
	overscroll_px: u16,        // the band's max distance past an end
	                           // scrollable ancestor; default true

	// Image content (§3.25): the node paints this image in its
	// rect (behind its text and children — a leaf is an image
	// control, a container gets a background image). NO_IMAGE =
	// no image. Fit/interp steer the paint only.
	image:       Image,      // default NO_IMAGE
	image_fit:   Image_Fit,  // default .Uniform
	image_interp: Image_Interp, // default .High
}

@(private)
default_style :: proc() -> Style {
	return Style{
		layout      = .Left_To_Right,
		size        = {fit(), fit()},
		align       = {.Start, .Start},
		wrap        = .None,
		ellipsis    = true,
		overflow    = .Spill,
		scroll      = .None,
		opacity     = 255, // opaque; fill/border colors default to
		                   // transparent black, but text defaults to
		                   // opaque black ink — text that renders
		                   // invisible unless colored is a footgun,
		                   // and nothing can be relying on it
		font_color  = Color{0, 0, 0, 255},
		font_size   = 16,
		font_weight = .Regular,
		font_slant  = .Upright,
		cursor      = .Arrow,
		scroll_chain = true,
		smooth_ms    = 150,
		overscroll_px = 64,
		image_fit    = .Uniform,
		image_interp = .High,
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
	justify:       Maybe(bool),      // default false; spread wrapped lines to the full width
	overflow:      Maybe(Overflow),  // default .Spill

	overlay_color:        Maybe(Color),
	overlay_border_color: Maybe(Color),
	overlay_border_width: Maybe(u16),

	cursor:       Maybe(Cursor_Kind),
	scroll_chain: Maybe(bool), // default true
	smooth_scroll: Maybe(bool),
	smooth_ms:    Maybe(u16), // default 150
	overscroll:   Maybe(bool),
	overscroll_px: Maybe(u16), // default 64

	image:       Maybe(Image),
	image_fit:   Maybe(Image_Fit),
	image_interp: Maybe(Image_Interp),

	hover, press, focus, disabled: Unit, // automatic state overlays, declared as data
	focusable: Maybe(bool),              // participates in keyboard focus traversal;
	                                     // Maybe so set_many can tell "unset" from
	                                     // an explicit false (audit core-H5)
	focus_ring: Maybe(Focus_Ring_Mode),  // when the engine focus ring shows here
	                                     // (default .Keyboard; see set_focus_ring)
	text_input: Maybe(bool),             // a text-input instance: while it holds focus,
	                                     // Space and Enter reach input_keys as keys
	                                     // instead of activating it (a text box reads
	                                     // Enter itself; Space types through input_text)

	groups: []Group,          // join these groups for every field (mint only)
	group_masks: []Group_Mask, // join these groups for the given fields only (mint only)
}

// Group_Mask scopes a membership: the unit joins group, and broadcasts
// through it reach only these fields (§3.7).
Group_Mask :: struct {
	group:  Group,
	fields: Fields,
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
	image: Maybe(Image), // per-instance image swap; wins over
	                     // Style.image, and Maybe(NO_IMAGE) clears
	                     // the base image for this instance (§3.25)
	size: Maybe(Size), // per-instance size; wins over the unit's size
	                   // and over state overlays. Lets one unit serve
	                   // every instance of a part whose geometry varies
	                   // (a slider's fill, a scrollbar's thumb).
	static_values: bool, // the presented values above (text, spans,
	                     // image) never change for this instance's
	                     // lifetime; the engine skips their change
	                     // detection (§5 stamps). Debug builds still
	                     // compute and assert. Style writes, state
	                     // and geometry detection are unaffected —
	                     // the promise covers presented values only.
	disabled: bool,
	anchored: bool, // an overlay child (§3.20): removed from flow
	                // in any container — no flow slot, no waterfill,
	                // no content extent, no scroll offset — sized
	                // and positioned against the parent's full rect
	                // by its align (padding never insets overlays).
	                // Scrollbar chrome, sticky headers.
	focusable: Maybe(bool), // per-instance focus participation; wins over
	                        // the unit's Style_Decl.focusable, so one
	                        // instance of a repeated unit can be the
	                        // tabbable one (or none of them can).
	focus_ring: Maybe(Focus_Ring_Mode), // per-instance ring mode; wins over
	                        // the unit's Style_Decl.focus_ring
	variant:  Unit,          // persistent per-instance overlay (e.g. selected)
	anchor:   Maybe([2]f32), // overlay positioning hint

	label: Maybe(string), // accessibility: accessible name, copied
	                      // like text (§3.9). When unset, the mirror
	                      // falls back to the node's text.

	// Accessibility semantics (§3.9, TODO #23): role, description,
	// value, and state flags, declared per instance like the rest
	// of With. A node with none of these set (role .None, no
	// label/description/value/flags) has no semantics and does
	// not appear in the mirror.
	role:        A11y_Role, // .None = unset
	description: Maybe(string), // accessible description, copied like text
	value:       A11y_Value, // value for value-bearing roles; text copied like text
	a11y_flags: A11y_Flags, // Checked/Selected/Expanded/ReadOnly/Required/Multiline

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

// ============ frames ============

Mouse_Button :: enum u8 {
	Left,
	Middle,
	Right,
}

Buttons :: bit_set[Mouse_Button]

// Key_Code names a keyboard key. It is the core's own vocabulary:
// hosts translate their native codes into it, so neither app code nor
// the core ever handles a platform's numbers. Unknown covers any key
// without a name here.
Key_Code :: enum u16 {
	Unknown,

	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,

	Digit_0, Digit_1, Digit_2, Digit_3, Digit_4,
	Digit_5, Digit_6, Digit_7, Digit_8, Digit_9,

	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	F13, F14, F15, F16, F17, F18, F19, F20, F21, F22, F23, F24,

	Escape, Enter, Tab, Backspace, Space,
	Insert, Delete, Home, End, Page_Up, Page_Down,
	Left, Right, Up, Down,

	Minus, Equals, Left_Bracket, Right_Bracket, Backslash,
	Semicolon, Apostrophe, Grave, Comma, Period, Slash,

	Caps_Lock, Scroll_Lock, Num_Lock, Print_Screen, Pause, Menu,

	Kp_0, Kp_1, Kp_2, Kp_3, Kp_4, Kp_5, Kp_6, Kp_7, Kp_8, Kp_9,
	Kp_Divide, Kp_Multiply, Kp_Minus, Kp_Plus, Kp_Enter, Kp_Period, Kp_Equals,

	Left_Shift, Right_Shift, Left_Ctrl, Right_Ctrl,
	Left_Alt, Right_Alt, Left_Super, Right_Super,
}

// Modifier is a held modifier, either side. Super is the Windows /
// Command / Meta key.
Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Super,
}
Modifiers :: bit_set[Modifier; u8]

// One keyboard event. A key has two names:
//
//   key       what the active keyboard layout produces: the key to
//             match for shortcuts and editing (Ctrl+Z is .Z on QWERTY
//             and AZERTY alike). Not affected by the modifiers —
//             Shift+1 is .Digit_1, not '!' (read typed characters
//             with input_text).
//   physical  the key at that position on a US QWERTY board, whatever
//             the layout: for position-based bindings (WASD).
//
// The core consumes only the keys its own semantics need — Tab
// (traversal; Shift reverses), Escape (popup dismiss) and
// Space/Enter/Kp_Enter (activation), all matched on `key` — and
// passes the rest to the focused instance via input_keys.
Key_Event :: struct {
	key:      Key_Code,
	physical: Key_Code,
	mods:     Modifiers, // modifiers held when the event fired
	down:     bool,
	repeat:   bool, // key-repeat event (down only)
}

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
	clicks:           u8, // the click count of the last left press this
	                      // frame, as the platform reports it (1 single,
	                      // 2 double, 3 triple…); 0 when unknown (counted
	                      // as 1). Read it back with press_clicks.

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

	window_focused: bool, // false = the window lacks OS focus: on the falling
	                      // edge, press/drag captures drop (no click completes
	                      // across the loss) and a held key-press cannot
	                      // complete; hover is not focus-gated and keeps
	                      // tracking the pointer over unfocused windows.
}

Frame_Result :: struct {
	changed:      bool,   // anything new, moved, or resized this frame
	damage:       []Rect, // damaged regions, valid until the next frame_begin
	next_wake_ms: u32,    // ms until the engine's nearest registered deadline
	                      // (tween/transient/hover timers, §8); max(u32) = none
	                      // pending, so the host may sleep until input or a context_wake
	cursor:       Cursor_Kind, // the hovered instance's resolved cursor
	                           // (.Arrow when nothing is hovered); the host
	                           // applies it when it changes
}

// ============ cold path ============

// mint creates a unit. base is a SNAPSHOT copy, never a live link: the new
// unit starts with base's current style, state overlays (hover, press,
// focus, disabled) and focusability, and never follows later writes to
// base. A variant is therefore one line: mint(&primary, btn, {color = accent}).
// Group memberships are not copied — joining stays explicit. Pass NO_UNIT
// to start from default_style(). decl applies on top via set_many.
mint :: proc(out: ^Unit, base: Unit, decl: Style_Decl = {},
             name := #caller_expression(out), loc := #caller_location) {
	if len(store.units) == 0 {
		append(&store.units, Unit_Rec{name = "NO_UNIT"}) // §8 sentinel at index 0
	}
	// The name is debug metadata (§3.13): the caller expression
	// for an out-param is "&foo" — strip the & so tree displays
	// and the overflow report read "foo".
	nm := name
	if strings.has_prefix(nm, "&") {
		nm = nm[1:]
	}
	rec := Unit_Rec{style = default_style(), name = nm, loc = loc, proto = base, live = true}
	if base != NO_UNIT {
		assert(unit_live(base), "niello.mint: base is not a minted unit")
		src := &store.units[unit_index(base)]
		rec.style = src.style
		// A variant is the base's whole look, so it shares the base's
		// state overlays and focusability too (the decl below may
		// replace any of them). Group memberships are not inherited:
		// joining a group stays explicit.
		rec.hover, rec.press, rec.focus, rec.disabled = src.hover, src.press, src.focus, src.disabled
		rec.focusable = src.focusable
		rec.focus_ring = src.focus_ring
		rec.text_input = src.text_input
		// The base copy is a snapshot: clone the reference-typed
		// fields so the new unit owns its copies (see store_spans).
		rec.style.text_spans = clone_spans(rec.style.text_spans)
		if len(rec.style.text) > 0 {
			rec.style.text = strings.clone(rec.style.text)
		}
	}
	// A slot freed by unmint is reused under its next generation, so
	// handles to the unit that held it before stay dead.
	u: Unit
	if n := len(store.free_units); n > 0 {
		idx := int(pop(&store.free_units))
		rec.generation = store.units[idx].generation + 1
		store.units[idx] = rec
		u = unit_handle(idx, rec.generation)
	} else {
		append(&store.units, rec)
		u = unit_handle(len(store.units) - 1, 0)
	}
	out^ = u
	// decl = {} is a no-op merge (set_many skips the generation bump when no
	// explicit fields were set).
	set_many(u, decl)
	// decl.groups registers membership in those groups: the locate-only
	// half of mint (§3.7). Nothing is applied by joining.
	for gr in decl.groups {
		group_add_member(gr, u, ALL_FIELDS)
	}
	for gm in decl.group_masks {
		group_add_member(gm.group, u, gm.fields)
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
	case .Justify:       s.justify       = must(v, bool)
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
	case .Smooth_Scroll: s.smooth_scroll = must(v, bool)
	case .Smooth_Ms: s.smooth_ms = must(v, u16)
	case .Overscroll: s.overscroll = must(v, bool)
	case .Overscroll_Px: s.overscroll_px = must(v, u16)
	case .Image:       s.image       = must(v, Image)
	case .Image_Fit:   s.image_fit   = must(v, Image_Fit)
	case .Image_Interp: s.image_interp = must(v, Image_Interp)
	}
}

// clone_spans copies a spans slice into engine-owned storage (nil
// stays nil).
@(private)
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
@(private)
store_spans :: proc(dst: ^[]Text_Span, src: []Text_Span) {
	if dst^ != nil {
		delete(dst^)
	}
	dst^ = clone_spans(src)
}

@(private)
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
@(private)
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

// set is a no-op on an equal value, like propagate (skips equal fields)
// and edit (diffs before writing): a blind write used to bump the
// generation and damage every frame, which is how a per-frame write of
// an unchanged value kept an app framing at vsync forever — a footgun
// no app author can see from their side. The comparison runs BEFORE
// any clone, so Text / Text_Spans never delete + re-clone on a no-op.
// One exception, kept deliberate: a field with a glide in flight is
// NOT a no-op even when the value equals the live (mid-glide) value —
// the explicit write's job there is to cancel the glide, and skipping
// it would let the glide carry the value away afterwards.
// write_style_field is the one compare-then-write path for a style field
// (audit core-H5): set calls it for a single field, set_many for
// every field its decl sets — the two routes can no longer drift
// apart on no-op discipline. Returns true when the stored value
// changed (or a glide had to be cancelled, which is also a write).
// An equal write is skipped BEFORE any clone, so Text / Text_Spans
// never delete + re-clone on a no-op.
@(private)
write_style_field :: proc(u: Unit, f: Field, v: any) -> bool {
	rec := &store.units[unit_index(u)]
	if !field_gliding(u, f) {
		tmp: Style
		style_set_any(&tmp, f, v)
		if field_equal(&rec.style, &tmp, f) {
			return false
		}
	}
	cancel_glide_fields(u, Fields{f}) // an explicit write supersedes a glide
	#partial switch f {
	case .Text:
		store_text(&rec.style.text, must(v, string))
	case .Text_Spans:
		store_spans(&rec.style.text_spans, must(v, []Text_Span))
	case:
		style_set_any(&rec.style, f, v)
	}
	return true
}

set_any :: proc(u: Unit, f: Field, v: any) {
	// One failure policy for cold handles (audit api-A4): an
	// invalid unit asserts loudly, exactly like pin — the silent
	// alternative was writing into the NO_UNIT sentinel record.
	assert(unit_live(u), "niello.set: unit is not minted")
	if write_style_field(u, f, v) {
		touch(u, Fields{f})
	}
}

set :: proc(u: Unit, f: Field, v: $T) {
	set_any(u, f, v)
}

// apply_decl_field routes one decl field through write_style_field,
// folding a real change into the caller's changed set.
@(private)
apply_decl_field :: proc(u: Unit, f: Field, m: Maybe($T), changed: ^Fields) {
	if v, ok := m.?; ok {
		if write_style_field(u, f, v) {
			changed^ += Fields{f}
		}
	}
}

// set_many merges a decl into the unit's owned style: Maybe fields that are
// set overwrite, the rest is untouched. Also records overlay units,
// focusable, and the explicit field set (for propagate). Every style
// field goes through write_style_field (audit core-H5), so an unchanged
// value is a no-op here exactly as it is through set: no clone, no
// generation bump. Explicitness is recorded for every field the decl
// sets — changed or not — because a deliberate restatement is still
// the author's choice, and propagate must not override it.
set_many :: proc(u: Unit, decl: Style_Decl) {
	assert(unit_live(u), "niello.set_many: unit is not minted")
	changed: Fields
	apply_decl_field(u, .Color, decl.color, &changed)
	apply_decl_field(u, .Font_Color, decl.font_color, &changed)
	apply_decl_field(u, .Border_Color, decl.border_color, &changed)
	apply_decl_field(u, .Text, decl.text, &changed)
	apply_decl_field(u, .Font, decl.font, &changed)
	apply_decl_field(u, .Font_Size, decl.font_size, &changed)
	apply_decl_field(u, .Font_Weight, decl.font_weight, &changed)
	apply_decl_field(u, .Font_Slant, decl.font_slant, &changed)
	apply_decl_field(u, .Text_Spans, decl.text_spans, &changed)
	apply_decl_field(u, .Padding, decl.padding, &changed)
	apply_decl_field(u, .Gap, decl.gap, &changed)
	apply_decl_field(u, .Border_Width, decl.border_width, &changed)
	apply_decl_field(u, .Corner_Radius, decl.corner_radius, &changed)
	apply_decl_field(u, .Opacity, decl.opacity, &changed)
	apply_decl_field(u, .Layout, decl.layout, &changed)
	apply_decl_field(u, .Size, decl.size, &changed)
	apply_decl_field(u, .Scroll, decl.scroll, &changed)
	apply_decl_field(u, .Align, decl.align, &changed)
	apply_decl_field(u, .Text_Wrap, decl.wrap, &changed)
	apply_decl_field(u, .Whitespace, decl.whitespace, &changed)
	apply_decl_field(u, .Ellipsis, decl.ellipsis, &changed)
	apply_decl_field(u, .Justify, decl.justify, &changed)
	apply_decl_field(u, .Overflow, decl.overflow, &changed)
	apply_decl_field(u, .Overlay_Color, decl.overlay_color, &changed)
	apply_decl_field(u, .Overlay_Border_Color, decl.overlay_border_color, &changed)
	apply_decl_field(u, .Overlay_Border_Width, decl.overlay_border_width, &changed)
	apply_decl_field(u, .Cursor, decl.cursor, &changed)
	apply_decl_field(u, .Scroll_Chain, decl.scroll_chain, &changed)
	apply_decl_field(u, .Smooth_Scroll, decl.smooth_scroll, &changed)
	apply_decl_field(u, .Smooth_Ms, decl.smooth_ms, &changed)
	apply_decl_field(u, .Overscroll, decl.overscroll, &changed)
	apply_decl_field(u, .Overscroll_Px, decl.overscroll_px, &changed)
	apply_decl_field(u, .Image, decl.image, &changed)
	apply_decl_field(u, .Image_Fit, decl.image_fit, &changed)
	apply_decl_field(u, .Image_Interp, decl.image_interp, &changed)

	rec := &store.units[unit_index(u)]
	// Overlay handles: NO_UNIT (the zero value) means "unset", so a decl that
	// doesn't mention them leaves existing overlays alone; clearing one is
	// clear_overlay's job (audit core-H5).
	if decl.hover != NO_UNIT    { rec.hover = decl.hover }
	if decl.press != NO_UNIT    { rec.press = decl.press }
	if decl.focus != NO_UNIT    { rec.focus = decl.focus }
	if decl.disabled != NO_UNIT { rec.disabled = decl.disabled }
	// focusable is presence-tracked (Maybe): a decl that doesn't
	// mention it no longer resets it to false.
	if v, ok := decl.focusable.?; ok {
		rec.focusable = v
	}
	if v, ok := decl.focus_ring.?; ok {
		rec.focus_ring = v
	}
	if v, ok := decl.text_input.?; ok {
		rec.text_input = v
	}

	fields := explicit_fields(decl)
	if fields != {} {
		cancel_glide_fields(u, fields)
		// touch(), split: explicitness for every set field, the
		// visual generation only for the ones that actually changed.
		rec.explicit += fields
		if changed & VISUAL_FIELDS != {} {
			rec.gen += 1
		}
	}
}

// Overlay_Kind names one of a unit's automatic state-overlay slots
// (the hover / press / focus / disabled units of Style_Decl).
Overlay_Kind :: enum {
	Hover,
	Press,
	Focus,
	Disabled,
}

// clear_overlay removes a unit's state overlay for one slot. It is
// the only way to clear one: in a decl, NO_UNIT means "unset" and
// leaves the slot alone (audit core-H5).
clear_overlay :: proc(u: Unit, kind: Overlay_Kind) {
	assert(unit_live(u), "niello.clear_overlay: unit is not minted")
	rec := &store.units[unit_index(u)]
	switch kind {
	case .Hover:    rec.hover = NO_UNIT
	case .Press:    rec.press = NO_UNIT
	case .Focus:    rec.focus = NO_UNIT
	case .Disabled: rec.disabled = NO_UNIT
	}
}

// ============ hot path ============

// show declares a leaf:
//
//	niello.show(title_u, {text = "Settings"})
//
// Identity: with no key, an instance is named by its call site (plus
// how many times that site has run under the same parent this frame,
// for loops), so static code needs no keys at all. Pass a key only for
// items of a list that can change order, and the key alone then names
// the instance:
//
//	for r in rows {
//		niello.show(row_u, {text = r.name}, niello.key_int(r.id))
//	}
//
// Component procs forward their caller's location, so each place a
// component is used is its own call site:
//
//	button :: proc(text: string, loc := #caller_location) -> (i: niello.Instance) {
//		if niello.begin(btn_u, out = &i, loc = loc) { ... }
//		return
//	}
//
// show, begin and begin_popup are inlined at the call site so the
// location folds there and only its hash reaches the engine.
show :: #force_inline proc(unit: Unit, with: With = {}, key: Key = 0, loc := #caller_location) -> Instance {
	return show_at(unit, with, key, site_hash(loc))
}

@(private)
show_at :: proc(unit: Unit, with: With, key: Key, site: u64) -> Instance {
	inst, _ := declare(unit, key, with, false, site)
	return inst
}

// begin declares a container: every show/begin until its block closes
// declares a child of it. Write it as an if-initializer — the matching
// end runs when the if statement's scope closes:
//
//	if niello.begin(panel_u) {
//		niello.show(label_u, 0, {text = "inside"})
//	}
//
// The result is true for every container that is laid out this frame —
// off-screen ones included: culling is a paint and hit-test
// optimization (draw_list skips what lies outside the clips), never a
// layout one, so an off-screen subtree keeps its size, its instances,
// its focus targets and its accessibility nodes. It is false only
// inside a popup that is not shown (begin_popup: no committed anchor);
// its children may be skipped then, and produce no instances if
// declared anyway. Long lists that should not be declared in full want
// virtualization (TODO), not culling.
//
// out, when given, receives the container's instance — written on
// every call, culled or not, so a handle kept for later queries
// (clicked, scroll_to) never goes stale:
//
//	if niello.begin(list_u, out = &app.list_i) { ... }
//	if niello.clicked(top_btn) { niello.scroll_to(app.list_i, {0, 0}) }
//
// Inside the block, current() returns the same instance. Identity and
// loc work as for show.
@(deferred_out = end)
begin :: #force_inline proc(
	unit: Unit,
	with: With = {},
	key: Key = 0,
	out: ^Instance = nil,
	loc := #caller_location,
) -> (open: bool) {
	return begin_at(unit, with, key, out, site_hash(loc))
}

@(private)
begin_at :: proc(unit: Unit, with: With, key: Key, out: ^Instance, site: u64) -> (open: bool) {
	i, idx := declare(unit, key, with, true, site)
	if out != nil {
		out^ = i
	}
	// No rect culling (decided 2026-11-13): a container is closed only
	// when its subtree is not presented at all — inside a popup that
	// is not shown (declare inherits the flag) — or by the test hook.
	cull := g.nodes[idx].culled
	if g.test_force_cull {
		cull = true
		g.test_force_cull = false
		g.nodes[idx].culled = true
	}

	// Push even when closed: end() must pop symmetrically, and children declared
	// while ignoring `open` are still correctly parented (just culled).
	append(&g.stack, idx)
	open_site_region()
	return !cull
}

// end closes the innermost container. begin and begin_popup call it
// through @(deferred_out); it pops even when open == false.
end :: proc(open: bool) {
	pop(&g.stack)
	close_site_region()
}

// current returns the innermost open container's instance (0 outside
// any container) — the instance begin wrote to out, for code inside the
// block that did not keep it.
current :: proc() -> Instance {
	if len(g.stack) == 0 {
		return 0
	}
	return g.nodes[g.stack[len(g.stack) - 1]].identity
}

// ============ deferred sections ============
// A section is a container whose flow children are declared after the
// main layout, once its own bounds are known: content that depends on
// its real size (a virtual list declaring only the rows in view, a grid
// choosing its column count). begin_section declares the host now and
// queues build; frame_end runs build after laying out the rest of the
// tree, with the host's exact rect and this frame's scroll offset, then
// lays out what build declared inside the host. niello/virtual builds
// fixed and estimated virtual lists on this.
//
//	build_rows :: proc(app: ^App, s: niello.Section) {
//		first := int(s.offset.y / ROW_H)
//		... declare the rows in view with show/begin as usual ...
//	}
//	if niello.begin_section(list_u, niello.builder(build_rows, &app), out = &app.list_i) {
//		scrollbar(&app.bar, app.list_i) // chrome: anchored children only
//	}
//
// The contract:
//   - The host's size must not depend on its children: no Fit on
//     either axis (its children do not exist when it is laid out).
//   - Its block declares anchored children only (chrome: scrollbars,
//     headers); its flow children are build's. Build's children come
//     first in tree order — they paint, hit-test, Tab and appear in
//     the accessibility tree before the chrome, which paints above.
//   - Build runs inside frame_end. Interaction queries (clicked,
//     hovered, input_keys…) answer as they do during declare; data
//     must stay valid until frame_end returns.
//   - The section's content does not change the host's ancestors'
//     layout or overflow; it does set the host's scroll range.
//   - Sections nest: a begin_section inside a build is built after
//     the current one. A section in a popup that is not shown is
//     never built.
Section :: struct {
	host:    Instance,
	unit:    Unit, // the host's unit (its layout direction and gap
	               // are what a list helper needs)
	rect:    Rect, // the host's rect this frame
	content: Rect, // rect less padding: where the flow starts
	visible: Rect, // the host's rect clipped by its ancestors (and the
	               // window): what can be on screen this frame
	offset:  Vec2, // the host's scroll offset this frame
}

// Builder pairs a section's build proc with the data it reads; make one
// with builder, which checks the two against each other.
Builder :: struct {
	build: Section_Build,
	data:  rawptr,
}

// builder pairs build with data for begin_section. data must stay valid
// until frame_end returns.
builder :: proc(build: proc(data: ^$T, s: Section), data: ^T) -> Builder {
	return Builder{build = transmute(Section_Build)build, data = rawptr(data)}
}

// begin_section declares a section host and queues its build (see
// above). The result and out work as for begin.
@(deferred_out = end)
begin_section :: proc(
	unit: Unit,
	b: Builder,
	with: With = {},
	key: Key = 0,
	out: ^Instance = nil,
	loc := #caller_location,
) -> (open: bool) {
	return begin_section_at(unit, b, with, key, out, site_hash(loc))
}

@(private)
begin_section_at :: proc(unit: Unit, b: Builder, with: With, key: Key, out: ^Instance, site: u64) -> (open: bool) {
	when NIELLO_DEBUG {
		sz := unit_style(unit).size
		if ws, ok := with.size.?; ok {
			sz = ws
		}
		assert(sz[X_AXIS].kind != .Fit && sz[Y_AXIS].kind != .Fit,
			"niello: a begin_section host cannot be Fit-sized: its children are declared after it is laid out")
	}
	open = begin_at(unit, with, key, out, site)
	idx := g.stack[len(g.stack) - 1]
	g.nodes[idx].is_section = true
	if open {
		assert(b.build != nil, "niello: begin_section needs a builder (niello.builder(build, data))")
		append(&g.sections, Section_Rec{host = idx, build = b.build, data = b.data})
	}
	return open
}

// measure lays out i — a top-level child the running section build has
// just declared, its block closed — and returns its size: the cross
// axis as the host lays it out (Grow fills the content box), the main
// axis intrinsic (Fit and Grow take the content, Percent is of the
// content box). The section lays i out again with the rest of the
// build by the same rules, so a list can declare items until the
// viewport is full, knowing their real sizes (niello/virtual's
// estimated list). Inside a section build only.
measure :: proc(i: Instance) -> Vec2 {
	assert(g.section_host >= 0, "niello.measure: only inside a section build")
	assert(g.stack[len(g.stack) - 1] == g.section_host,
		"niello.measure: close the item's block before measuring it")
	for idx := len(g.nodes) - 1; idx >= g.section_lo; idx -= 1 {
		if g.nodes[idx].identity == i {
			assert(g.nodes[idx].parent == g.section_host,
				"niello.measure: i is not a top-level child of the running build")
			return measure_item(idx, g.viewport)
		}
	}
	assert(false, "niello.measure: i was not declared by the running build")
	return {}
}

// scroll_shift moves i's scroll offset by delta at once, together with
// any glide in flight, so a scroll in progress keeps going from the
// shifted place. It is the correction for content that changed size
// above the viewport (a virtual list learning the real height of rows
// it had estimated): the shift and the content change cancel, and what
// is on screen stays put. Inside a section build on its host it applies
// to this frame's layout.
scroll_shift :: proc(i: Instance, delta: Vec2) {
	if i == 0 || delta == {0, 0} {
		return
	}
	g.scroll_off[i] = (g.scroll_off[i] or_else Vec2{0, 0}) + delta
	if gl, ok := &g.scroll_glides[i]; ok {
		for axis in 0 ..< 2 {
			if gl.active[axis] {
				gl.axis[axis].from += delta[axis]
				if !gl.axis[axis].spring {
					gl.axis[axis].to += delta[axis]
				}
			}
		}
	}
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
// The result and out work exactly as for begin. The result is false
// when the anchor instance has no committed rect (it was never shown,
// or left the tree): the popup is not presented, so declare children
// anyway or not — the subtree produces no instances either way.
//
//	if niello.begin_popup(menu_u, file_btn, .Below, opts = {gap = 4}, out = &app.menu_i) { ... }
@(deferred_out = end)
begin_popup :: #force_inline proc(
	unit: Unit,
	anchor: Instance,
	placement: Placement,
	with: With = {},
	key: Key = 0,
	opts: Popup_Opts = {},
	out: ^Instance = nil,
	loc := #caller_location,
) -> (open: bool) {
	return begin_popup_at(unit, anchor, placement, with, key, opts, out, site_hash(loc))
}

@(private)
begin_popup_at :: proc(
	unit: Unit,
	anchor: Instance,
	placement: Placement,
	with: With,
	key: Key,
	opts: Popup_Opts,
	out: ^Instance,
	site: u64,
) -> (open: bool) {
	anchor_ok := placement == .At || placement == .Center || anchor in g.instances
	// A popup declared from inside a popup that is not shown is not
	// shown either.
	decl_culled := len(g.stack) > 0 && g.nodes[g.stack[len(g.stack) - 1]].culled
	// Popup roots belong to the layer, not the declaring container:
	// their call-site occurrences count across the whole frame.
	k := identity_key(key, &g.popup_sites, 0, site)
	i, idx := declare_as(
		unit, k, with, true, -1, POPUP_PARENT_SEED, decl_culled || !anchor_ok,
	)
	if out != nil {
		out^ = i
	}
	nd := &g.nodes[idx]
	nd.is_popup = true
	nd.popup_anchor = anchor
	nd.popup_place = placement
	nd.popup_at = opts.at
	nd.popup_gap = opts.gap
	append(&g.popups, Popup_Rec{root_idx = idx, id = i, modal = opts.modal, stay = opts.stay})
	append(&g.stack, idx)
	open_site_region()
	return anchor_ok && !decl_culled
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

// ============ contexts ============
// A Context is one window's frame state (multi-window plan, M1).
// The cold store — units, groups — is global and context-free:
// mint and set anywhere, any time. A context owns only what a
// single tree's frames produce: nodes, instances, interaction,
// damage. Apps create one context per window and hand it to the
// glue (sdl.run(ctx, …)); there is no default context.

// context_create makes a context with no tree yet.
context_create :: proc() -> ^Context {
	ctx := new(Context)
	ctx.ring_idx = -1
	ctx.section_host = -1
	// Every map the engine owns is created here, once (audit X-4):
	// no lazy makes scattered through hot paths — four of them sat
	// inside pass F — and no read site needs a nil-map guard for
	// a live context ever again.
	ctx.instances = make(map[Instance]Inst_Rec)
	ctx.a11y_entries = make(map[Instance]A11y_Entry)
	ctx.scroll_off = make(map[Instance]Vec2)
	ctx.scroll_max = make(map[Instance]Vec2)
	ctx.scroll_glides = make(map[Instance]Scroll_Glide)
	ctx.hover_since = make(map[Instance]f32)
	ctx.dismiss_flags = make(map[Instance]bool)
	ctx.transients = make(map[Instance]Transient_Rec)
	ctx.edits = make(map[Unit]^Edit_State)
	// The store's two caches are shared by all contexts: the
	// first context created after a store reset makes them.
	if store.text_cache == nil {
		store.text_cache = make(map[u64]Text_Entry)
	}
	if store.ellipsis_widths == nil {
		store.ellipsis_widths = make(map[u64]Ellipsis_Width)
	}
	append(&store.contexts, ctx)
	return ctx
}

// context_destroy frees a context and everything its frames owned.
// The global store (units, groups) is untouched. If the context
// was bound, the binding is cleared.
context_destroy :: proc(ctx: ^Context) {
	if ctx == nil {
		return
	}
	for c, i in store.contexts {
		if c == ctx {
			ordered_remove(&store.contexts, i)
			break
		}
	}
	if g == ctx {
		g = nil
	}
	free_context(ctx)
	free(ctx)
}

// set_current binds the context that declare-time procs operate
// on. frame_begin binds its context itself; hosts and embedders
// use this for work outside frames.
set_current :: proc(ctx: ^Context) {
	g = ctx
}

// current_context returns the bound context (nil if none).
current_context :: proc() -> ^Context {
	return g
}

frame_begin :: proc(ctx: ^Context, input: Input, dt: f32) {
	assert(ctx != nil, "frame_begin needs a context (context_create)")
	g = ctx // bind: this frame's declare operates on ctx
	input := input // params are immutable; the sanitized copies are the frame's
	dt := dt
	// Host-supplied numbers are sanitized at this boundary, not
	// trusted (audit core-H8 class): dt and the viewport are
	// runtime data from the host's clock and window system, and
	// a NaN in either poisons silently — the u64 conversion
	// below turns NaN dt into arbitrary garbage time, and a
	// NaN viewport makes every layout comparison false. A
	// non-finite or negative dt is a clock hiccup: no time
	// passes. An absurd dt clamps an hour past any real frame
	// so the conversion stays exact. Viewport dims clamp into
	// [0, 65536]: a minimized window is a legitimate zero, and
	// 65536 DIP is beyond any real display.
	if !(dt >= 0) { dt = 0 }
	if dt > 3600 { dt = 3600 }
	if !(input.viewport.x >= 0) { input.viewport.x = 0 }
	if !(input.viewport.y >= 0) { input.viewport.y = 0 }
	if input.viewport.x > 65536 { input.viewport.x = 65536 }
	if input.viewport.y > 65536 { input.viewport.y = 65536 }
	// Engine time advances by the real frame delta; scheduling
	// deadlines are stamped against it.
	g.time_ms += u64(dt * 1000 + 0.5)
	// A context_wake() since the last frame is consumed here — the frame it
	// asked for is this one, and pending changes are discovered by
	// the ordinary diff machinery below.
	if sync.atomic_load(&g.wake_requested) {
		sync.atomic_store(&g.wake_requested, false)
	}
	// Input dispatch runs FIRST, against last frame's committed tree
	// (nodes/lay/pick_clip still hold it). Queries during this frame's
	// declare answer from that hit test: one frame of latency (§3.8).
	dispatch_input(input, dt)
	// Nodes' span slices live in the frame spans arena (declare.odin);
	// the cursor rewind below retires them all at once.
	clear(&g.nodes)
	g.ring_idx = -1 // re-resolved by frame_end over the new tree
	clear(&g.withs)
	clear(&g.size_overrides)
	g.text_chunk = 0 // rewind the frame text arena; chunks are kept
	g.text_off = 0
	g.spans_chunk = 0 // and the spans arena beside it
	g.spans_off = 0
	clear(&g.popups) // last frame's list; dispatch already read it
	clear(&g.sections)
	g.section_host = -1
	clear(&g.stack)
	clear(&g.site_counts)
	clear(&g.site_base)
	clear(&g.popup_sites)
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
	step_scroll_glides()
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
			set_focus_id(0, g.focus_visible)
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
				found := false
				for idx in top_root ..= g.subtree_end[top_root] {
					if focus_candidate(idx) {
						set_focus_id(g.nodes[idx].identity, g.focus_visible)
						found = true
						break
					}
				}
				if !found {
					// No candidate inside the modal (audit
					// int-1): focus must not stay parked on
					// whatever sits behind it.
					set_focus_id(0, g.focus_visible)
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
							set_focus_id(saved, g.focus_visible)
							break
						}
					}
				}
			}
			g.modal_prev_id = top_modal
		}
		// Steady-state containment (audit int-1): while a modal is
		// up, focus may not sit outside its subtree — a declare-time
		// focus() behind the modal, or the focused node leaving the
		// subtree, is corrected here, beside the grab that handles
		// the transitions. (Popups above the modal count as inside.)
		if top_modal != 0 && top_root >= 0 && g.focus_id != 0 {
			mk := -1
			for rec, k in g.popups {
				if rec.id == top_modal {
					mk = k
				}
			}
			focus_idx := -1
			for idx in 0 ..< len(g.nodes) {
				if g.nodes[idx].identity == g.focus_id {
					focus_idx = idx
					break
				}
			}
			if focus_idx < 0 || popup_containing(focus_idx) < mk {
				set_focus_id(0, g.focus_visible)
			}
		}
	}
	// Interaction-driven restyles need no damage route of their
	// own: dispatch runs at frame_begin, so an overlay-driven
	// restyle resolves in the same frame's declare and pass F's
	// stamp comparison damages it (verified across the interaction
	// suite, audit int-15 — the old affected/input_dirty route
	// only ever duplicated that damage or added spurious rects).
	// The focus ring and reveal (render.odin, layout.odin): after
	// every focus move of the frame, the modal ones above included.
	focus_reveal()
	focus_ring_resolve()
	// Debug snapshot (TODO #18): after the commit — a no-op
	// unless built with NIELLO_DEBUG.
	text_cache_sweep()
	debug_snapshot_build()
	// Accessibility mirror (§3.9, TODO #23): same position, but
	// UNGATED — screen readers are prod behavior.
	a11y_mirror_build()
	update_animation_wake()
	// Debug channel transitions (TODO #18): a highlight or tint
	// aimed at this context changes the presented pixels without
	// touching this tree's change model — left out, the glue
	// would frame on the debugger's wake, report unchanged, and
	// never repaint. Damage exactly the transitions (paint,
	// move, erase), so a steady highlight costs nothing and the
	// context still idles with it on screen.
	when NIELLO_DEBUG {
		cur_hl: Instance = store.debug_hl_ctx == g ? store.debug_hl_inst : 0
		if cur_hl != g.debug_painted_inst {
			if rec, ok := g.instances[g.debug_painted_inst]; ok {
				append(&g.damage, rec.rect)
			}
			if rec, ok := g.instances[cur_hl]; ok {
				append(&g.damage, rec.rect)
			}
			g.debug_painted_inst = cur_hl
		}
		cur_ovf := store.debug_ovf_on && store.debug_ovf_ctx == g
		if cur_ovf != g.debug_painted_ovf {
			append(&g.damage, Rect{{0, 0}, g.viewport})
			g.debug_painted_ovf = cur_ovf
		}
	}
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
	rec: Inst_Rec
	rec, ok = g.instances[i]
	return rec.rect, ok
}

// ============ cross-context reads ============
// A context's committed state is readable WITHOUT binding it (M4):
// while one window declares, every other window sits at a frame
// boundary, so its instances map is stable to read. This is the
// inspector-window story — a debug window renders a peer window's
// committed tree (rects today; names and the overflow report join
// when TODO #18 builds them).

// rect_in reads instance i's committed rect in ctx (the peer form
// of rect()). False when ctx has no such instance.
rect_in :: proc(ctx: ^Context, i: Instance) -> (r: Rect, ok: bool) {
	if ctx == nil {
		return {}, false
	}
	rec: Inst_Rec
	rec, ok = ctx.instances[i]
	return rec.rect, ok
}

// unit_in reads which unit instance i instantiates in ctx.
unit_in :: proc(ctx: ^Context, i: Instance) -> (u: Unit, ok: bool) {
	if ctx == nil {
		return NO_UNIT, false
	}
	rec: Inst_Rec
	rec, ok = ctx.instances[i]
	return rec.unit, ok
}

// instance_count is how many instances ctx committed last frame.
instance_count :: proc(ctx: ^Context) -> int {
	if ctx == nil {
		return 0
	}
	return len(ctx.instances)
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
// Space/Enter key activation on a focused instance presses it too (see
// pointer_pressed for the pointer alone).
pressed :: proc(i: Instance) -> bool {
	if pointer_pressed(i) {
		return true
	}
	// A Space/Enter capture on a focused descendant presses its
	// ancestors too, exactly like a pointer capture.
	return chain_contains(g.key_press_chain[:], i)
}

// pointer_pressed is pressed for pointer captures only: a mouse button
// pressed on the instance (or a descendant) and still held. Key
// activation is not included. A control that reads the pointer while
// pressed — a slider seeking to drag_pos — wants this, so Space/Enter
// does not seek it to wherever the pointer happens to be.
pointer_pressed :: proc(i: Instance) -> bool {
	for b in Mouse_Button {
		if chain_contains(g.press_chains[b][:], i) {
			return true
		}
	}
	return false
}

// clicked reports a left-button press on the instance (or a descendant)
// completed with a release over it, as of this frame's dispatch. True for
// exactly one declare: the one after the release.
clicked :: proc(i: Instance) -> bool {
	return chain_contains(g.clicked_chain[:], i)
}

// ============ drag queries (§3.28) ============
// A left press whose displacement from the grab point crosses
// DRAG_THRESHOLD (4 DIP) becomes a drag on the same press capture.
// The drag belongs to the press target and bubbles like the other
// queries; an ancestor claims or disclaims a descendant's drag by
// subtraction (dragging(header) && !dragging(close_btn)). Drag and
// click are orthogonal: a drag's release completes the drag, and the
// click is evaluated independently — press, drag off, drag back,
// release over the target clicks. Capture loss — focus loss,
// cursor departure, the target leaving the tree — cancels it.

// dragging reports a drag is active on the instance (or a descendant).
dragging :: proc(i: Instance) -> bool {
	return g.drag_active && chain_contains(g.press_chains[.Left][:], i)
}

// drag_started reports the drag crossed the threshold in this frame's
// dispatch. True for exactly one declare.
drag_started :: proc(i: Instance) -> bool {
	// The snapshot half covers a drag that started AND ended in
	// the last dispatch (audit int-14): drag_active is already
	// false by declare time, but the start still reports, beside
	// the end, for exactly one declare.
	return (g.drag_started_flag && dragging(i)) ||
		chain_contains(g.drag_started_chain[:], i)
}

// drag_ended reports the drag on the instance (or a descendant) ended
// in this frame's dispatch. True for exactly one declare.
drag_ended :: proc(i: Instance) -> bool {
	return chain_contains(g.drag_ended_chain[:], i)
}

// drag_completed distinguishes how the drag ended: released (true)
// vs cancelled by capture loss (false). Meaningful only with
// drag_ended.
drag_completed :: proc(i: Instance) -> bool {
	return g.drag_ended_completed && drag_ended(i)
}

// drag_delta is the pointer's movement in the last dispatch, window
// DIP — zero unless a drag is active or just ended.
drag_delta :: proc() -> Vec2 {
	if g.drag_active || g.drag_ended_id != 0 {
		return g.drag_delta_v
	}
	return Vec2{}
}

// drag_total is the pointer's displacement from the grab point —
// live while dragging; on the drag_ended declare, the final total.
drag_total :: proc() -> Vec2 {
	if g.drag_active {
		return g.drag_total_v
	}
	if g.drag_ended_id != 0 {
		return g.drag_ended_total
	}
	return Vec2{}
}

// drag_pos is the pointer position relative to the instance's
// committed rect origin — the slider's raw material. {0,0} when the
// instance has no committed rect.
drag_pos :: proc(i: Instance) -> Vec2 {
	if r, ok := rect(i); ok {
		return g.pointer_pos - r.pos
	}
	return Vec2{}
}

// hover_duration is how long the cursor has been inside i's subtree, in
// seconds: i's own entry time into the hover chain, so a button reports
// one continuous duration whether the cursor is over its body or its
// label. 0 whenever i is not in the current chain. Tooltip delays read
// this.
// HOVER_REFRESH_MS: while an app displays a live hover duration, the
// engine refreshes it at ~20 Hz. Coarse on purpose — a duration readout
// is glanceable text, not an animation.
@(private)
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

// press_clicks is the click count of the left press that began this
// frame's dispatch — 1 for a single click, 2 for a double click, 3 for a
// triple — or 0 when no left press began. Read with pressed/clicked
// during declare: a text box selects a word on press_clicks() == 2.
press_clicks :: proc() -> int {
	return g.press_clicks
}

// focused reports i holds programmatic keyboard focus (see focus).
focused :: proc(i: Instance) -> bool {
	return i != 0 && i == g.focus_id
}

// focus sets keyboard focus programmatically; pass Instance(0) to
// clear. Focus also moves by traversal (Tab) and by pointer press on
// a focusable instance (§3.17). Moving focus cancels any pending
// key-press (Space/Enter) capture. Programmatic focus is keyboard
// focus: it shows the focus ring and scrolls the instance into view.
focus :: proc(i: Instance) {
	set_focus_id(i, true)
}

// ============ focus ring ============
// The engine draws one standard focus indicator around the focused
// instance: a ring outside its rect that follows its corner radius,
// painted above its children. It shows for keyboard focus — Tab,
// focus(), or a key pressed while focus is held — and not when a
// pointer press moved focus (the clicked control is already where the
// user is looking), unless the unit asks for it with focus_ring =
// .Always. A unit's `focus` overlay is a different thing: state
// styling (a field's background or border) that applies on any focus.

// Focus_Ring is the app-wide ring look.
Focus_Ring :: struct {
	color:  Color,
	width:  u16, // stroke width in DIP; 0 = no ring anywhere
	offset: i16, // gap between the instance's edge and the ring;
	             // negative draws it inset
}

DEFAULT_FOCUS_RING :: Focus_Ring{color = Color{0x4c, 0x8d, 0xff, 255}, width = 2, offset = 2}

// Focus_Ring_Mode is when the ring shows on a unit (Style_Decl.focus_ring,
// With.focus_ring).
Focus_Ring_Mode :: enum u8 {
	Keyboard, // keyboard focus only (the default)
	Always,   // pointer focus too: text fields, where a caret alone is easy to miss
	Never,    // the unit shows focus itself (focus_visible says when)
}

// set_focus_ring sets the ring for every window. Call it again to
// re-theme; width 0 turns the ring off.
set_focus_ring :: proc(r: Focus_Ring) {
	store.focus_ring = r
}

// focus_visible reports i holds focus and should show it: the focus
// came from the keyboard, or i's ring mode is .Always. It ignores
// .Never, so a component that draws its own indicator can show it at
// the moments the engine ring would.
focus_visible :: proc(i: Instance) -> bool {
	if i == 0 || i != g.focus_id {
		return false
	}
	if g.focus_visible {
		return true
	}
	for idx in 0 ..< len(g.nodes) {
		if g.nodes[idx].identity == i {
			return g.nodes[idx].ring_mode == .Always
		}
	}
	return false
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
	if i == 0 || i != g.input_target || len(g.frame_text) == 0 {
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
	if i == 0 || i != g.input_target {
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

// scroll_range reports i's scrollable range in DIP per axis — how
// far the content extends beyond the viewport (0 on an axis that
// does not scroll or does not overflow). It is the range half of
// scroll_offset, read from the same committed state; scrollbar
// chrome (§3.20) sizes and positions its thumb from the pair.
scroll_range :: proc(i: Instance) -> Vec2 {
	return g.scroll_max[i] or_else Vec2{0, 0}
}

// scroll_to sets i's scroll offset in DIP (back-to-top is
// scroll_to(i, {0, 0})). The stored value is clamped to the scrollable
// range when the next frame renders — the same range the wheel clamps
// against — so an out-of-range request lands on the nearest end.
scroll_to :: proc(i: Instance, offset: Vec2) {
	if i == 0 {
		return
	}
	// A programmatic jump is instant by definition: it cancels any
	// wheel glide in flight on this scroller (§3.21).
	delete_key(&g.scroll_glides, i)
	// And it lands on a legal position: clamped to the known range.
	// (Overscroll is a gesture state owned by its spring, §3.22 —
	// never a parked programmatic position.)
	if mx, ok := g.scroll_max[i]; ok {
		offset := offset
		offset.x = clamp(offset.x, 0, mx.x)
		offset.y = clamp(offset.y, 0, mx.y)
		g.scroll_off[i] = offset
		return
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

// text_width is the width of text set in u's font, size, weight and
// slant, in DIP: one measurement through the backend (the mock metrics
// headless), never cached — an editor measures caret prefixes, and the
// text cache keeps everything it is given. Spans are not applied.
text_width :: proc(u: Unit, text: string) -> f32 {
	if len(text) == 0 {
		return 0
	}
	s := unit_style(u)
	w, _ := measure_frag(s.font, s.font_weight, s.font_slant, s.font_size, text)
	return w
}

// text_line_height is the height of one line of text in u's font, size,
// weight and slant, in DIP: what a caret or a selection highlight is
// sized from, so it follows the text when its size changes.
text_line_height :: proc(u: Unit) -> f32 {
	s := unit_style(u)
	h, _ := frag_line_height(s.font, s.font_weight, s.font_slant, s.font_size)
	return h
}

// style_of returns a copy of unit u's current style: its own values, with
// any glide in flight at its current point. Read it; change a unit with
// set, set_many, a group broadcast, a tween or an edit.
style_of :: proc(u: Unit) -> Style {
	return unit_style(u)^
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

// ============ clipboard ============
// The system clipboard, text only. The core has no OS code: the glue
// sets the hooks (niello/sdl does at startup). Without them — headless,
// in tests — an in-memory clipboard stands in, owned by the store.

// clipboard_get_hook returns the clipboard's text, allocated with the
// given allocator ("" when empty or not text). clipboard_set_hook
// replaces it.
clipboard_get_hook: proc(allocator: runtime.Allocator) -> string
clipboard_set_hook: proc(text: string)

// clipboard_text returns the clipboard's text ("" when it holds none),
// allocated with allocator (by default the temp allocator).
clipboard_text :: proc(allocator := context.temp_allocator) -> string {
	if clipboard_get_hook != nil {
		return clipboard_get_hook(allocator)
	}
	return strings.clone(store.clipboard, allocator)
}

// set_clipboard_text puts text on the clipboard.
set_clipboard_text :: proc(text: string) {
	if clipboard_set_hook != nil {
		clipboard_set_hook(text)
		return
	}
	delete(store.clipboard)
	store.clipboard = strings.clone(text)
}

// fonts_changed invalidates every cached text measurement. The
// backend clears its own font cache when a family is (re)registered;
// the core's word cache keys on the family handle, which does not
// change — so without this bump, measurements taken under the old
// binding (or before the font existed) would be served forever.
// The glue calls it from its register_font / register_font_family;
// apps wiring custom hooks call it after (re)binding a family.
fonts_changed :: proc() {
	store.font_epoch += 1
}

// ============ scheduling ============
// The idle-CPU contract (§3.3): changes are found by the next SCHEDULED
// frame. frame_end reports the nearest engine deadline as next_wake_ms
// and the host blocks on OS events until then. context_wake() is the
// escape hatch for work that happens off the frame thread.

// wake_hook, when set, runs at the end of context_wake(). Host glue
// uses it to interrupt its event wait (niello/sdl pushes an SDL user
// event). Set once at startup, like the measure hooks. nil =
// context_wake() only flags the context, and discovery waits for the
// next natural wake.
wake_hook: proc()

// context_wake schedules a frame of ctx from outside the loop — the
// one core entry point that is safe to call from any thread. It flags
// the request atomically and pokes the host through wake_hook; the
// frame it asked for discovers pending changes through the ordinary
// diff machinery. There is deliberately no context-free wake(): a
// wake always names the window whose work is ready.
context_wake :: proc(ctx: ^Context) {
	if ctx == nil {
		return
	}
	sync.atomic_store(&ctx.wake_requested, true)
	if wake_hook != nil {
		wake_hook()
	}
}

// wake_pending reports whether a context_wake is still unconsumed.
// Hosts use it to decide which window is due a frame; frame_begin
// does the consuming.
wake_pending :: proc(ctx: ^Context) -> bool {
	if ctx == nil {
		return false
	}
	return sync.atomic_load(&ctx.wake_requested)
}

// wake_in is the app-facing timer: it asks for another frame of the
// bound context roughly ms from now, in engine time, by registering
// a deadline frame_end folds into next_wake_ms (the earliest pending
// deadline wins). Call it during declare; re-arm it every frame
// while the condition holds — a seek refresh while playing, a
// debounce quiet window — and stop calling it when the condition
// ends: a due deadline fires with the frame that runs and is gone,
// so an idle app registers nothing and the host blocks on OS
// events. Relative-only by design: there is no public clock, and a
// timer that needs to know WHICH expiry fired carries that as an
// app-level message (the one-inbox pattern, Async_Inbox_Design.md).
wake_in :: proc(ms: u32) {
	schedule_wake_in(ms)
}

// schedule_wake_in registers an engine deadline ms from now, in engine
// time; frame_end reports the nearest pending deadline as
// next_wake_ms. Engine subsystems register here — tweens, transients,
// hover-delay thresholds (§8). wake_in above is the same registry,
// app-facing.
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
	if len(store.groups) == 0 {
		append(&store.groups, Group_Rec{name = "NO_GROUP"}) // sentinel at index 0
	}
	append(&store.groups, Group_Rec{name = name})
	return Group(len(store.groups) - 1)
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
	n := len(store.groups[int(sub)].members)
	for i in 0 ..< n {
		m := store.groups[int(sub)].members[i]
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
		if f in store.units[unit_index(m.unit)].pinned {
			continue
		}
		if ms == 0 {
			set(m.unit, f, v)
		} else {
			target := store.units[unit_index(m.unit)].style
			style_set_any(&target, f, v)
			start_glide(m.unit, Fields{f}, &target, ms)
		}
	}
}

// group_apply broadcasts a whole Style_Decl: every field the decl sets
// is written to every member whose mask includes it and whose unit has
// not pinned it — the many-field form of group_set (a theme switch in
// one call per role). ms == 0 lands the values at once (an equal value
// is a no-op, as with set); ms > 0 glides each member there. The decl's
// overlays, focusable and group fields are ignored: only style values
// broadcast.
group_apply :: proc(grp: Group, decl: Style_Decl, ms: u32 = 0) {
	fields := explicit_fields(decl)
	if fields == {} {
		return
	}
	// Resolve the decl once into a scratch unit's style: its owned text
	// and spans are cloned by the member writes, then freed with it.
	d := decl
	d.groups, d.group_masks = nil, nil
	d.hover, d.press, d.focus, d.disabled = NO_UNIT, NO_UNIT, NO_UNIT, NO_UNIT
	tmp: Unit
	mint(&tmp, NO_UNIT, d)
	defer unmint(tmp)
	src := &store.units[unit_index(tmp)].style
	rec := group_rec(grp)
	for m in rec.members {
		mrec := &store.units[unit_index(m.unit)]
		eff := fields & m.fields - mrec.pinned
		if ms > 0 {
			start_glide(m.unit, eff, src, ms)
			continue
		}
		for f in eff {
			if field_gliding(m.unit, f) || !field_equal(&mrec.style, src, f) {
				cancel_glide_fields(m.unit, Fields{f})
				write_field(m.unit, f, src)
			}
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
	assert(unit_live(u), "niello.pin: unit is not minted")
	store.units[unit_index(u)].pinned += fields
}

unpin :: proc(u: Unit, fields: Fields) {
	assert(unit_live(u), "niello.unpin: unit is not minted")
	store.units[unit_index(u)].pinned -= fields
}

@(private)
group_rec :: proc(grp: Group) -> ^Group_Rec {
	assert(int(grp) >= 1 && int(grp) < len(store.groups) && !store.groups[int(grp)].deleted,
		"niello: group handle is not a live group")
	return &store.groups[int(grp)]
}

// group_delete frees a group's member list. The units themselves are
// untouched (a group only locates them); the handle is dead afterwards.
// Group ids are not reused.
group_delete :: proc(grp: Group) {
	rec := group_rec(grp)
	delete(rec.members)
	rec.members = nil
	rec.deleted = true
}

// ============ freeing units ============

// unmint frees a unit: its owned text and spans, its slot (which a later
// mint reuses under a new generation), and every reference the engine
// holds to it — group memberships, other units' state overlays and
// prototype links, in-flight tweens and pending edits. Afterwards the
// handle is dead: declaring it, or passing it anywhere a Unit is
// expected, asserts. Units minted from it keep the values they have;
// they simply stop receiving propagate.
//
// Stop declaring the unit before unmint-ing it: an instance of a dead
// unit cannot be laid out.
unmint :: proc(u: Unit) {
	assert(unit_live(u), "niello.unmint: unit is not minted (or was unmint-ed already)")
	idx := unit_index(u)
	rec := &store.units[idx]
	if rec.style.text_spans != nil {
		delete(rec.style.text_spans)
	}
	if len(rec.style.text) > 0 {
		delete(rec.style.text)
	}
	for &other in store.units {
		if !other.live {
			continue
		}
		if other.proto == u { other.proto = NO_UNIT }
		if other.hover == u { other.hover = NO_UNIT }
		if other.press == u { other.press = NO_UNIT }
		if other.focus == u { other.focus = NO_UNIT }
		if other.disabled == u { other.disabled = NO_UNIT }
	}
	for &gr in store.groups {
		for k := len(gr.members) - 1; k >= 0; k -= 1 {
			if gr.members[k].unit == u {
				ordered_remove(&gr.members, k)
			}
		}
	}
	cancel_glide_fields(u, ALL_FIELDS)
	for ctx in store.contexts {
		if es, ok := ctx.edits[u]; ok {
			free(es)
			delete_key(&ctx.edits, u)
		}
	}
	store.units[idx] = Unit_Rec{generation = rec.generation, live = false}
	append(&store.free_units, u32(idx))
}

// shutdown releases everything the engine holds: every context still
// alive (their ^Context pointers are dead afterwards), every unit and
// group, the image registry and the text caches. Call it once, after
// the last frame — typically right after niello_sdl.run returns. A new
// mint afterwards starts a fresh store.
shutdown :: proc() {
	for len(store.contexts) > 0 {
		context_destroy(store.contexts[len(store.contexts) - 1])
	}
	free_store()
	store = Store{}
	g = nil
}

@(private)
group_add_member :: proc(grp: Group, u: Unit, fields: Fields) {
	assert(unit_live(u), "niello.group_add: unit is not minted")
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
	assert(unit_live(u), "niello.tween: unit is not minted")
	assert(unit_live(to), "niello.tween: target unit is not minted")
	target := store.units[unit_index(to)].style
	start_glide(u, fields, &target, ms)
}

// group_tween broadcasts tween: every member glides toward `to`'s
// style, gated per member by its mask (intersected with fields) and
// its pins — the same gates as group_set.
group_tween :: proc(grp: Group, to: Unit, ms: u32, fields: Fields = ALL_FIELDS) {
	assert(unit_live(to), "niello.group_tween: target unit is not minted")
	rec := group_rec(grp)
	target := store.units[unit_index(to)].style
	for m in rec.members {
		eff := fields & m.fields
		for f in store.units[unit_index(m.unit)].pinned {
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
	assert(unit_live(u), "niello.edit: unit is not minted")
	if es, ok := g.edits[u]; ok {
		return &es.shadow
	}
	es := new(Edit_State)
	es.base = store.units[unit_index(u)].style
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
	assert(unit_live(proto), "niello.propagate: unit is not minted")
	if fields == {} {
		return
	}
	updated: [dynamic]Unit
	defer delete(updated)
	for idx in 1 ..< len(store.units) {
		rec := &store.units[idx]
		if !rec.live || rec.proto == NO_UNIT {
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
		u := unit_handle(idx, rec.generation)
		src := &store.units[unit_index(src_unit)].style
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
	assert(unit_live(style), "niello.transient: style unit is not minted")
	if prev, ok := g.transients[i]; ok {
		if prev.src == style && prev.in_ms == in_ms && prev.out_ms == out_ms {
			if _, active := transient_k(&prev); active {
				return
			}
		}
	}
	src := &store.units[unit_index(style)]
	fields := src.explicit & TRANSIENT_FIELDS
	if fields == {} {
		return
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

