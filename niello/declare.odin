// declare.odin — the internal declare machinery.
//
// The public declare API (show/begin/end) lives in public.odin; this file
// holds the node append, identity hashing, key fallback, and text resolution.
// begin uses @(deferred_out=end): `if i, ok := begin(u); ok { ... }` closes the
// container when the if-scope exits, LIFO for nesting, and end() still runs when
// open == false or on early return.
package niello

Frame_Node :: struct {
	unit:            Unit,
	identity:        Instance,
	parent:          int, // -1 for roots
	with:            With,
	text:            string, // resolved at declare time (see resolve_text)
	text_hash:       u64,    // str_hash(text); the text cache keys on this
	                        // instead of re-hashing every frame
	spans:           []Text_Span, // resolved at declare time (see resolve_spans);
	                              // copied, so no borrow contract
	spans_hash:     u64,    // hash of spans; 0 when nil. The text cache keys
	                        // on this alongside the font tuple.
	has_text:        bool,
	focusable:       bool, // resolved at declare: With.focusable wins
	                       // over the unit's Style_Decl.focusable
	anchored:        bool, // With.anchored, resolved at declare (§3.20)
	is_popup:        bool, // an overlay root (§3.19): parent is the
	                       // layer (-1), positioned by placement in
	                       // pass F, never by a parent's layout
	popup_anchor:    Instance, // .At ignores it
	popup_place:     Placement,
	popup_at:        Vec2,
	popup_gap:       f32,
	is_container:    bool,
	culled:          bool,
	has_eff:         bool, // frame_end resolved an effective style into
	                       // g.eff[idx] (interaction state or variant present)
	sibling_ordinal: int,
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
// The result is copied (spans are small) so the caller keeps no borrow
// contract, and hashed once for the text cache key.
@(private)
resolve_spans :: proc(with: With, s: ^Style) -> (spans: []Text_Span, hash: u64) {
	src := s.text_spans
	if w, ok := with.text_spans.?; ok {
		src = w
	}
	if len(src) == 0 {
		return nil, 0
	}
	spans = make([]Text_Span, len(src))
	copy(spans, src)
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
	return spans, hash
}

// Popup roots hash against a fixed seed instead of a parent
// identity (§3.19): a popup's identity is stable no matter where in
// the tree it was declared from, and can never collide with a main
// root built from the same unit and key.
POPUP_PARENT_SEED :: u64(0xd1b54a32d192ed03)

// declare appends one node; parents always precede children in the array.
@(private)
declare :: proc(unit: Unit, key: Key, with: With, is_container: bool) -> (Instance, int) {
	parent := -1
	if len(g.stack) > 0 {
		parent = g.stack[len(g.stack) - 1]
	}

	ord := 0
	parent_culled := false
	if len(g.stack) > 0 {
		ord = g.child_counts[len(g.child_counts) - 1]
		g.child_counts[len(g.child_counts) - 1] += 1
		parent_culled = g.nodes[parent].culled
	}

	parent_id := u64(0)
	if parent >= 0 {
		parent_id = u64(g.nodes[parent].identity)
	}
	return declare_as(unit, key, with, is_container, parent, ord, parent_id, parent_culled)
}

// declare_as is declare with the parentage made explicit: popup
// roots (§3.19) pass parent -1 with the layer seed, wherever the
// declaring code sits in the tree.
@(private)
declare_as :: proc(
	unit: Unit,
	key: Key,
	with: With,
	is_container: bool,
	parent: int,
	ord: int,
	parent_id: u64,
	culled: bool,
) -> (
	Instance,
	int,
) {
	// Key 0 falls back to the sibling ordinal.
	k := u64(key)
	if k == 0 {
		k = u64(ord) + 0x9e3779b97f4a7c15 // domain-separate from explicit keys
	}
	id := identity_of(parent_id, unit, k)

	text := resolve_text(with, style_of(unit))
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
	has_text := len(text) > 0
	text_hash := u64(0)
	spans: []Text_Span
	spans_hash := u64(0)
	if has_text {
		// Hash once here; the text cache keys on (font, text_hash) instead
		// of re-hashing the bytes on every lookup, every frame (Clay hashes
		// contents for frame-arena-copied text — same requirement, paid once).
		text_hash = str_hash(text)
		spans, spans_hash = resolve_spans(with, style_of(unit))
	}
	append(
		&g.nodes,
		Frame_Node{
			unit = unit,
			identity = id,
			parent = parent,
			with = with,
			text = text,
			text_hash = text_hash,
			spans = spans,
			spans_hash = spans_hash,
			has_text = has_text,
			focusable = with.focusable.? or_else g.units[int(unit)].focusable,
			anchored = with.anchored,
			is_container = is_container,
			culled = culled,
			sibling_ordinal = ord,
		},
	)
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
@(private)
copy_frame_text :: proc(text: string) -> string {
	if len(text) == 0 {
		return text
	}
	need := len(text)
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
	copy(dst, text)
	g.text_off += need
	return string(dst)
}
