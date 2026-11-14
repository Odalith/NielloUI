#+private
package niello

// declare.odin — the internal declare machinery.
//
// The public declare API (show/begin/end) lives in public.odin; this file
// holds the node append, identity hashing, key fallback, and text resolution.
// begin uses @(deferred_out=end): `if begin(u) { ... }` closes the container
// when the if statement ends, LIFO for nesting, and end() still runs when the
// container is closed (a popup not shown) or on early return.

import "base:runtime"
import "core:unicode/utf8"

Frame_Node :: struct {
	unit:            Unit,
	identity:        Instance,
	parent:          int, // -1 for roots
	// The With fields the per-frame passes read. The full With is kept
	// only where something reads it later — g.withs[with_idx] for nodes
	// with accessibility semantics, and for every node in NIELLO_DEBUG
	// builds (the debugger shows it); -1 otherwise. Most nodes carry
	// only text, so storing all of it per node was the bulk of the
	// node's size.
	with_idx:        i32,
	size_idx:        i32, // index into g.size_overrides (With.size), -1 none
	variant:         Unit, // With.variant
	disabled:        bool, // With.disabled (this node's own flag)
	static_values:   bool, // With.static_values
	image_override:  bool, // With.image was set (image is that value)
	text:            string, // resolved at declare time (see resolve_text)
	text_hash:       u64,    // str_hash(text); the text cache keys on this
	                        // instead of re-hashing every frame
	spans:           []Text_Span, // resolved at declare time (see resolve_spans);
	                              // copied, so no borrow contract
	spans_hash:     u64,    // hash of spans; 0 when nil. The text cache keys
	                        // on this alongside the font tuple.
	digest:         u64,    // §5 stamp: hash of the per-instance
	                        // presented content as resolved here —
	                        // (text_hash, spans_hash, image). Pass F
	                        // compares it against the committed record;
	                        // everything style-side is covered by the
	                        // unit generation instead.
	has_text:        bool,
	image:           Image, // resolved at declare: With.image wins
	                        // over the unit's style image (§3.25)
	focusable:       bool, // resolved at declare: With.focusable wins
	                       // over the unit's Style_Decl.focusable
	anchored:        bool, // With.anchored, resolved at declare (§3.20)
	has_anchored:    bool, // some child is anchored: the passes that
	                       // treat overlays specially look only then
	is_popup:        bool, // an overlay root (§3.19): parent is the
	                       // layer (-1), positioned by placement in
	                       // pass F, never by a parent's layout
	popup_anchor:    Instance, // .At ignores it
	popup_place:     Placement,
	popup_at:        Vec2,
	popup_gap:       f32,
	is_container:    bool,
	culled:          bool, // not presented this frame: a popup with no
	                       // committed anchor, and its subtree (never a
	                       // rect test — culling is paint-only)
	has_eff:         bool, // frame_end resolved an effective style into
	                       // g.eff[idx] (interaction state or variant present)
	ring_mode:       Focus_Ring_Mode, // resolved at declare like focusable
	is_section:      bool, // a begin_section host: flow children arrive in its section pass
}

// resolve_text: per-frame With.text wins, then With.text_no_copy (borrowed),
// then the unit's own style text. declare_as copies the With.text result
// into the frame arena (copy_frame_text); the other two borrow on purpose.
@(private)
resolve_text :: proc(with: With, s: ^Style) -> string {
	if t, ok := with.text.?; ok {
		return t
	}
	if t, ok := with.text_no_copy.?; ok {
		return t
	}
	return s.text
}

// resolve_spans: per-frame With.text_spans wins over the unit's style spans.
// The result is copied into the frame spans arena (small slices, but one
// heap copy + a next-frame free PER NODE was the second-biggest churn in
// the 2026-10-21 perf analysis) so the caller keeps no borrow contract,
// and hashed once for the text cache key.
//
// style_hash is the unit's cached spans hash (unit_derived), used when
// the spans come from the unit; per-instance spans are hashed here.
@(private)
resolve_spans :: proc(with: With, s: ^Style, style_hash: u64) -> (spans: []Text_Span, hash: u64) {
	if w, ok := with.text_spans.?; ok {
		if len(w) == 0 {
			return nil, 0
		}
		return copy_frame_spans(w), spans_hash_of(w)
	}
	if len(s.text_spans) == 0 {
		return nil, 0
	}
	return copy_frame_spans(s.text_spans), style_hash
}

// spans_hash_of hashes a span list for the text cache key (0 for none).
spans_hash_of :: proc(spans: []Text_Span) -> (hash: u64) {
	if len(spans) == 0 {
		return 0
	}
	hash = 14695981039346656037 // FNV-1a offset basis
	for sp in spans {
		hash = hash_mix(hash, u64(sp.start))
		hash = hash_mix(hash, u64(sp.end))
		hash = hash_mix(hash, u64(sp.font.? or_else Font_Handle(0)))
		hash = hash_mix(hash, u64(transmute(u32)(sp.font_size.? or_else 0)))
		hash = hash_mix(hash, u64(sp.font_weight.? or_else .Regular))
		hash = hash_mix(hash, u64(sp.font_slant.? or_else .Upright))
		fc := sp.font_color.? or_else Color{0, 0, 0, 0}
		hash = hash_mix(hash, u64(fc[0]) | u64(fc[1]) << 8 | u64(fc[2]) << 16 | u64(fc[3]) << 24)
	}
	return
}

// Popup roots hash against a fixed seed instead of a parent
// identity (§3.19): a popup's identity is stable no matter where in
// the tree it was declared from, and can never collide with a main
// root built from the same unit and key.
POPUP_PARENT_SEED :: u64(0xd1b54a32d192ed03)

// SECTION_PARENT_SEED salts the parent hash of a section's flow
// children (begin_section): they are declared in the build, the host's
// chrome in its block, and the two must never share an identity even
// from the same call site.
SECTION_PARENT_SEED :: u64(0x8cb92ba72f3d8dd7)

// ---------------------------------------------------------------------------
// Identity
//
// An instance is hash(parent, unit, k). With an explicit key, k is the
// key: the caller names the identity, wherever it is declared from.
// Without one (key 0), k is the call site plus how many times that
// call site has already declared under the same parent this frame. So
// declarations on different lines never disturb each other — a
// conditional sibling appearing or vanishing shifts nothing — and only
// a site that repeats (a loop) counts occurrences. Lists whose items
// can move pass a key from the data instead.

Site_Count :: struct {
	site: u64,
	n:    int,
}

// site_hash names a call site. The file path is a constant string in
// the binary, so its address identifies the file without hashing the
// bytes on every declaration. It needs to be distinct, not well mixed:
// identity_key and identity_of finish with mix64.
@(private)
site_hash :: #force_inline proc(loc: runtime.Source_Code_Location) -> u64 {
	return u64(uintptr(raw_data(loc.file_path))) * 0x9e3779b97f4a7c15 ~ (u64(u32(loc.line)) << 32 | u64(u32(loc.column)))
}

// next_occurrence counts one declaration of site within counts[base:]
// and returns how many came before it.
@(private)
next_occurrence :: proc(counts: ^[dynamic]Site_Count, base: int, site: u64) -> int {
	for &c in counts[base:] {
		if c.site == site {
			n := c.n
			c.n += 1
			return n
		}
	}
	append(counts, Site_Count{site = site, n = 1})
	return 0
}

// SITE_KEY_SEED keeps derived keys out of the explicit-key domain.
@(private)
SITE_KEY_SEED :: u64(0x9e3779b97f4a7c15)

// identity_key is the k of hash(parent, unit, k): the explicit key, or
// one derived from the call site and its occurrence.
@(private)
identity_key :: proc(key: Key, counts: ^[dynamic]Site_Count, base: int, site: u64) -> u64 {
	if key != 0 {
		return u64(key)
	}
	occ := next_occurrence(counts, base, site)
	return mix64(site ~ SITE_KEY_SEED ~ u64(occ) * 0xd6e8feb86659fd93)
}

// open_site_region starts a container's site-count region; close_site_region
// drops it when the container ends.
@(private)
open_site_region :: proc() {
	append(&g.site_base, len(g.site_counts))
}

@(private)
close_site_region :: proc() {
	resize(&g.site_counts, pop(&g.site_base))
}

// declare appends one node; parents always precede children in the array.
@(private)
declare :: proc(unit: Unit, key: Key, with: With, is_container: bool, site: u64) -> (Instance, int) {
	// A dead handle would otherwise read whichever unit reuses its slot.
	assert(unit_live(unit), "niello: declared a unit that is not minted (or was unmint-ed)")
	assert(with.variant == NO_UNIT || unit_live(with.variant), "niello: With.variant is not a minted unit (or was unmint-ed)")
	parent := -1
	parent_culled := false
	parent_id := u64(0)
	if len(g.stack) > 0 {
		parent = g.stack[len(g.stack) - 1]
		parent_culled = g.nodes[parent].culled
		parent_id = u64(g.nodes[parent].identity)
		if g.nodes[parent].is_section {
			if parent == g.section_host {
				parent_id = mix64(parent_id ~ SECTION_PARENT_SEED)
			} else {
				// A section host's block declares its chrome only;
				// its flow children belong to the build, which
				// runs after the main layout (begin_section).
				assert(with.anchored, "niello: a begin_section block may declare only anchored children (chrome); flow children go in the build")
			}
		}
	}
	base := len(g.site_base) > 0 ? g.site_base[len(g.site_base) - 1] : 0
	k := identity_key(key, &g.site_counts, base, site)
	return declare_as(unit, k, with, is_container, parent, parent_id, parent_culled)
}

// declare_as is declare with the parentage made explicit: popup
// roots (§3.19) pass parent -1 with the layer seed, wherever the
// declaring code sits in the tree.
@(private)
declare_as :: proc(
	unit: Unit,
	k: u64, // the identity key (identity_key)
	with: With,
	is_container: bool,
	parent: int,
	parent_id: u64,
	culled: bool,
) -> (
	Instance,
	int,
) {
	id := identity_of(parent_id, unit, k)

	text := resolve_text(with, unit_style(unit))
	img := unit_style(unit).image
	if v, ok := with.image.?; ok {
		img = v
	}
	if _, ok := with.text.?; ok {
		// The documented contract (§2 strings): With.text is COPIED
		// into the frame arena at declare time. The caller's buffer
		// may be a scratch reused for the very next sibling — a
		// virtualized list formatting each row into one buffer is
		// the canonical case — so the node must not borrow it.
		// (This copy was designed but never implemented until a
		// demo's rows all rendered the buffer's final contents.)
		text = copy_frame_text(text)
	}
	// Accessibility strings (§3.9) get the same treatment as text:
	// copied into the frame arena at declare time, so the stored
	// With borrows arena memory, never caller scratch. The mirror
	// (a11y.odin) copies them again into owned storage at frame_end,
	// since it outlives the frame arena. Only nodes that declare
	// semantics pay these copies, made in the kept copy itself.
	size_idx := i32(-1)
	if sz, ok := with.size.?; ok {
		size_idx = i32(len(g.size_overrides))
		append(&g.size_overrides, sz)
	}
	with_idx := i32(-1)
	if NIELLO_DEBUG || a11y_declared(with) {
		with_idx = i32(len(g.withs))
		append(&g.withs, with)
		w := &g.withs[with_idx]
		if lb, ok := w.label.?; ok {
			w.label = copy_frame_text(lb)
		}
		if d, ok := w.description.?; ok {
			w.description = copy_frame_text(d)
		}
		if len(w.value.text) > 0 {
			w.value.text = copy_frame_text(w.value.text)
		}
	}
	has_text := len(text) > 0
	text_hash := u64(0)
	spans: []Text_Span
	spans_hash := u64(0)
	if has_text {
		// Hash once here; the text cache keys on (font, text_hash) instead
		// of re-hashing the bytes on every lookup, every frame (Clay hashes
		// contents for frame-arena-copied text — same requirement, paid once).
		// Text from the unit (no With text) uses the unit's cached hash
		// and validity: a label minted once is not rescanned per frame.
		rec := unit_derived(unit)
		valid: bool
		if with.text == nil && with.text_no_copy == nil {
			text_hash, valid = rec.text_hash, rec.text_valid
		} else {
			ascii: bool
			text_hash, ascii = text_scan(text)
			valid = ascii || utf8.valid_string(text)
		}
		// Invalid UTF-8 is sanitized at this one boundary: nothing
		// downstream validates display text, and the
		// native replay validator rejects the ENTIRE command stream
		// over one bad byte — one corrupt label (a file tag, a paste)
		// blanked the window with no Odin-side diagnostic. Valid
		// text passes through untouched; invalid sequences become
		// U+FFFD in a frame-arena copy, whichever source the text
		// came from (With or the unit's style). The hash pass already
		// proved all-ASCII text valid.
		if !valid {
			text = sanitize_frame_text(text)
			text_hash = str_hash(text)
		}
		spans, spans_hash = resolve_spans(with, &rec.style, rec.spans_hash)
	}
	// The presented-content digest (§5 stamps): three folds over
	// values already computed above — the text and span hashes the
	// text cache needed anyway, plus the resolved image handle.
	digest := u64(14695981039346656037)
	digest = hash_mix(digest, text_hash)
	digest = hash_mix(digest, spans_hash)
	digest = hash_mix(digest, u64(img))
	// Focus facts: With wins over the unit's (one store read for both).
	urec := &store.units[unit_index(unit)]
	focusable := with.focusable.? or_else urec.focusable
	ring_mode := with.focus_ring.? or_else urec.focus_ring
	append(
		&g.nodes,
		Frame_Node{
			unit = unit,
			identity = id,
			parent = parent,
			with_idx = with_idx,
			size_idx = size_idx,
			variant = with.variant,
			disabled = with.disabled,
			static_values = with.static_values,
			image_override = with.image != nil,
			text = text,
			text_hash = text_hash,
			digest = digest,
			spans = spans,
			spans_hash = spans_hash,
			has_text = has_text,
			image = img,
			focusable = focusable,
			ring_mode = ring_mode,
			anchored = with.anchored,
			is_container = is_container,
			culled = culled,
		},
	)
	if with.anchored && parent >= 0 {
		g.nodes[parent].has_anchored = true
	}
	return id, len(g.nodes) - 1
}

// ---------------------------------------------------------------------------
// Frame text arena

TEXT_CHUNK :: 16 * 1024

// copy_frame_text copies a string into the frame arena and returns the
// arena slice. Chunks are never reallocated once made, so slices taken
// earlier in the frame stay valid; frame_begin rewinds the cursor and
// the chunks are reused next frame. A string larger than a chunk gets
// a chunk of its own size.
// frame_text_reserve claims `need` bytes of frame arena and
// returns them (the cursor advances by the full claim; a caller
// that writes fewer bytes just leaves a gap).
@(private)
frame_text_reserve :: proc(need: int) -> []u8 {
	if len(g.text_chunks) == 0 {
		append(&g.text_chunks, make([]u8, max(TEXT_CHUNK, need)))
		g.text_chunk = 0
		g.text_off = 0
	} else if g.text_off + need > len(g.text_chunks[g.text_chunk]) {
		g.text_chunk += 1
		g.text_off = 0
		if g.text_chunk == len(g.text_chunks) {
			append(&g.text_chunks, make([]u8, max(TEXT_CHUNK, need)))
		} else if len(g.text_chunks[g.text_chunk]) < need {
			delete(g.text_chunks[g.text_chunk])
			g.text_chunks[g.text_chunk] = make([]u8, max(TEXT_CHUNK, need))
		}
	}
	chunk := g.text_chunks[g.text_chunk]
	dst := chunk[g.text_off:g.text_off + need]
	g.text_off += need
	return dst
}

@(private)
copy_frame_text :: proc(text: string) -> string {
	if len(text) == 0 {
		return text
	}
	dst := frame_text_reserve(len(text))
	copy(dst, text)
	return string(dst)
}

// sanitize_frame_text returns text unchanged when it is valid
// UTF-8 (the common case: one validation walk, no copy). Invalid
// input is rebuilt into the frame arena with U+FFFD in place of
// each bad byte: decoding drives the rebuild, so the output is
// valid by construction under the same strict rules the native
// validator applies (no overlongs, no surrogates, nothing past
// U+10FFFF). A genuine U+FFFD in the source decodes with width
// 3 and is copied verbatim — only width-1 error decodes are
// replaced. The arena claim is the worst case (every byte bad:
// 3 bytes out per byte in); the unused tail is skipped space,
// rewound next frame like every arena gap.
@(private)
sanitize_frame_text :: proc(text: string) -> string {
	out := frame_text_reserve(3 * len(text))
	n := 0
	i := 0
	for i < len(text) {
		r, w := utf8.decode_rune_in_string(text[i:])
		if r == utf8.RUNE_ERROR && w == 1 {
			copy(out[n:], "�")
			n += 3
			i += 1
		} else {
			copy(out[n:], text[i:i + w])
			n += w
			i += w
		}
	}
	return string(out[:n])
}

// copy_frame_spans copies a span slice into the frame spans arena and
// returns the arena slice — the Text_Span twin of copy_frame_text,
// same chunk discipline (chunks never move; frame_begin rewinds).
@(private)
copy_frame_spans :: proc(src: []Text_Span) -> []Text_Span {
	if len(src) == 0 {
		return nil
	}
	SPAN_CHUNK :: 256
	need := len(src)
	if len(g.spans_chunks) == 0 {
		append(&g.spans_chunks, make([]Text_Span, max(SPAN_CHUNK, need)))
		g.spans_chunk = 0
		g.spans_off = 0
	} else if g.spans_off + need > len(g.spans_chunks[g.spans_chunk]) {
		g.spans_chunk += 1
		g.spans_off = 0
		if g.spans_chunk == len(g.spans_chunks) {
			append(&g.spans_chunks, make([]Text_Span, max(SPAN_CHUNK, need)))
		} else if len(g.spans_chunks[g.spans_chunk]) < need {
			delete(g.spans_chunks[g.spans_chunk])
			g.spans_chunks[g.spans_chunk] = make([]Text_Span, max(SPAN_CHUNK, need))
		}
	}
	chunk := g.spans_chunks[g.spans_chunk]
	dst := chunk[g.spans_off:g.spans_off + need]
	copy(dst, src)
	g.spans_off += need
	return dst
}

// node_with returns the node's full With, or nil when the node kept
// none (no accessibility semantics, prod build).
@(private)
node_with :: proc(nd: ^Frame_Node) -> ^With {
	if nd.with_idx < 0 {
		return nil
	}
	return &g.withs[nd.with_idx]
}
