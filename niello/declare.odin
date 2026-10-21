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
	is_container:    bool,
	culled:          bool,
	has_eff:         bool, // frame_end resolved an effective style into
	                       // g.eff[idx] (interaction state or variant present)
	sibling_ordinal: int,
}

// resolve_text: per-frame With.text wins, then With.text_no_copy (borrowed),
// then the unit's own style text. With.text is copied into the frame arena by
// the real backend; the mock just holds the string.
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

	// Key 0 falls back to the sibling ordinal.
	k := u64(key)
	if k == 0 {
		k = u64(ord) + 0x9e3779b97f4a7c15 // domain-separate from explicit keys
	}
	parent_id := u64(0)
	if parent >= 0 {
		parent_id = u64(g.nodes[parent].identity)
	}
	id := identity_of(parent_id, unit, k)

	text := resolve_text(with, style_of(unit))
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
			is_container = is_container,
			culled = parent_culled,
			sibling_ordinal = ord,
		},
	)
	return id, len(g.nodes) - 1
}
