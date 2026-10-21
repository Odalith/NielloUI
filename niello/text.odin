// text.odin — text measurement with a fragment-aware word cache.
//
// Words are split at span boundaries into fragments; each fragment is
// measured under its effective style (base unit style + span overrides).
// The cache keys on the full style tuple plus a hash of the spans, so a hit
// is always valid and no explicit invalidation exists: change the text, the
// size, or the spans and the key changes.
//
// Fragments are maximal w.r.t. style changes, which makes them shaping
// boundaries — the same rule every major text engine uses. Measured widths
// therefore always match what the backend draws (one blob per fragment),
// by construction.
package niello

import "core:slice"

// A fragment: a maximal byte-range of a word with one effective style.
Text_Frag :: struct {
	start, end: int, // byte offsets into the node's text
	width:      f32,
	font:        Font_Handle,
	font_size:   f32,
	font_weight: Font_Weight,
	font_slant:  Font_Slant,
	// Span color override only. The BASE font_color is paint state, not
	// metrics: it is not part of the cache key, so freezing it into the
	// entry would replay the first color forever. Emission resolves the
	// base color from the node's current style; a span override is part
	// of spans_hash, so storing it here is keyed and safe.
	span_color: Maybe(Color),
}

Text_Word :: struct {
	start, end: int, // byte offsets into the node's text
	width:      f32, // sum of frag widths — this is what pack_lines sees
	frags:      []Text_Frag, // 1 frag when there are no spans
}

// Cached per (font, size, weight, slant, spans, text).
Text_Entry :: struct {
	segs:    [dynamic][]Text_Word, // per \n-segment
	space_w: f32, // space advance in the base style
	line_h:  f32, // max over fragments; layout and the emitter share it
}

// Mock metrics: proportional to size; bold is a touch wider. The real
// backend replaces these through measure_word_hook / line_height_hook,
// which fire only on cache miss.
@(private)
mock_frag_width :: proc(size: f32, weight: Font_Weight, n_bytes: int) -> f32 {
	w := f32(n_bytes) * size * 0.5
	if weight >= .Bold {
		w *= 1.12
	}
	return w
}

@(private)
measure_frag :: proc(font: Font_Handle, weight: Font_Weight, slant: Font_Slant, size: f32, text: string) -> f32 {
	if measure_word_hook != nil {
		return measure_word_hook(font, weight, slant, size, text)
	}
	return mock_frag_width(size, weight, len(text))
}

@(private)
frag_line_height :: proc(font: Font_Handle, weight: Font_Weight, slant: Font_Slant, size: f32) -> f32 {
	if line_height_hook != nil {
		return line_height_hook(font, weight, slant, size)
	}
	return size
}

// ellipsis_width is the waterfill shrink floor for ellipsis text (§3.12):
// the width of "…" in the node's own style. A pure function of the style,
// cached per style — layout consults it on hot paths (the
// measure_text fold) and the backend hooks must fire only on cache miss.
ellipsis_width :: proc(s: ^Style) -> f32 {
	key := hash_mix(u64(s.font), u64(transmute(u32)s.font_size))
	key = hash_mix(key, u64(s.font_weight))
	key = hash_mix(key, u64(s.font_slant))
	if g.ellipsis_widths == nil {
		g.ellipsis_widths = make(map[u64]f32)
	} else if w, ok := g.ellipsis_widths[key]; ok {
		return w
	}
	w := measure_frag(s.font, s.font_weight, s.font_slant, s.font_size, "…")
	g.ellipsis_widths[key] = w
	return w
}

// style_at resolves the effective style at byte offset `at`: the base unit
// style with the last span covering `at` applied (later spans win).
// color_from_span reports whether the returned color came from a span
// (and is therefore covered by spans_hash) or fell through to the base
// style (not covered by any cache key — callers must not cache it).
@(private)
style_at :: proc(s: ^Style, spans: []Text_Span, at: int) -> (font: Font_Handle, size: f32, weight: Font_Weight, slant: Font_Slant, color: Color, color_from_span: bool) {
	font, size, weight, slant, color = s.font, s.font_size, s.font_weight, s.font_slant, s.font_color
	for sp in spans {
		if at >= sp.start && at < sp.end {
			if f, ok := sp.font.?; ok {
				font = f
			}
			if v, ok := sp.font_size.?; ok {
				size = v
			}
			if v, ok := sp.font_weight.?; ok {
				weight = v
			}
			if v, ok := sp.font_slant.?; ok {
				slant = v
			}
			if v, ok := sp.font_color.?; ok {
				color = v
				color_from_span = true
			}
		}
	}
	return font, size, weight, slant, color, color_from_span
}

@(private)
get_text :: proc(s: ^Style, spans: []Text_Span, spans_hash: u64, text_hash: u64, text: string) -> Text_Entry {
	if g.text_cache == nil {
		g.text_cache = make(map[u64]Text_Entry)
	}
	key := hash_mix(u64(s.font), text_hash)
	key = hash_mix(key, u64(transmute(u32)s.font_size))
	key = hash_mix(key, u64(s.font_weight))
	key = hash_mix(key, u64(s.font_slant))
	key = hash_mix(key, spans_hash)
	if e, ok := g.text_cache[key]; ok {
		return e
	}
	e := fill_entry(s, spans, text)
	g.text_cache[key] = e
	return e
}

// fill_entry splits text into \n-segments, then words (collapsing repeated
// spaces, as before), then each word into fragments at span boundaries.
@(private)
fill_entry :: proc(s: ^Style, spans: []Text_Span, text: string) -> Text_Entry {
	e := Text_Entry{}
	e.space_w = measure_frag(s.font, s.font_weight, s.font_slant, s.font_size, " ")
	e.line_h = frag_line_height(s.font, s.font_weight, s.font_slant, s.font_size)

	frags: [dynamic]Text_Frag
	defer delete(frags)
	cuts: [dynamic]int
	defer delete(cuts)
	words: [dynamic]Text_Word
	defer delete(words)

	word_start := -1
	for j := 0; j <= len(text); j += 1 {
		at_end := j == len(text)
		c := u8(' ')
		if !at_end {
			c = text[j]
		}
		if at_end || c == '\n' || c == ' ' {
			if word_start >= 0 {
				ws, we := word_start, j
				// Cut at every overlapping span boundary.
				clear(&cuts)
				append(&cuts, ws, we)
				for sp in spans {
					s0 := max(sp.start, ws)
					s1 := min(sp.end, we)
					if s0 < s1 {
						append(&cuts, s0, s1)
					}
				}
				// Snap cuts to UTF-8 boundaries; never split a sequence.
				for i in 0 ..< len(cuts) {
					for cuts[i] > ws && cuts[i] < we && (text[cuts[i]] & 0xC0) == 0x80 {
						cuts[i] -= 1
					}
				}
				slice.sort(cuts[:])
				w := 1
				for r in 1 ..< len(cuts) {
					if cuts[r] != cuts[w-1] {
						cuts[w] = cuts[r]
						w += 1
					}
				}
				resize(&cuts, w)

				clear(&frags)
				word_w := f32(0)
				for k in 0 ..< len(cuts) - 1 {
					cs, ce := cuts[k], cuts[k+1]
					if ce <= cs {
						continue
					}
					font, size, weight, slant, color, from_span := style_at(s, spans, cs)
					fw := measure_frag(font, weight, slant, size, text[cs:ce])
					frag := Text_Frag{
						start = cs, end = ce, width = fw,
						font = font, font_size = size, font_weight = weight,
						font_slant = slant,
					}
					if from_span {
						frag.span_color = color
					}
					append(&frags, frag)
					word_w += fw
					e.line_h = max(e.line_h, frag_line_height(font, weight, slant, size))
				}
				wfrags := make([]Text_Frag, len(frags))
				copy(wfrags, frags[:])
				append(&words, Text_Word{start = ws, end = we, width = word_w, frags = wfrags})
				word_start = -1
			}
			if at_end || c == '\n' {
				seg := make([]Text_Word, len(words))
				copy(seg, words[:])
				append(&e.segs, seg)
				clear(&words)
			}
		} else if word_start < 0 {
			word_start = j
		}
	}
	return e
}

// measure_text returns the unwrapped size and the shrink floor (min_w).
// wrap==.Word -> min_w is the widest word; wrap==.None -> the full width,
// folded to the ellipsis width when ellipsis is on. The fold lives HERE, in
// the cached measurement, so min_c is the true shrink floor at every level
// of the tree (a container accumulating a text child's raw full-line floor
// would make the text untruncatable inside any container).
measure_text :: proc(s: ^Style, spans: []Text_Span, spans_hash: u64, text_hash: u64, text: string, wrap: Text_Wrap) -> (unwrapped: Vec2, min_w: f32) {
	e := get_text(s, spans, spans_hash, text_hash, text)
	unwrapped = Vec2{0, 0}
	for seg in e.segs {
		seg_w := f32(0)
		seg_min := f32(0)
		for w, k in seg {
			if k > 0 {
				seg_w += e.space_w
			}
			seg_w += w.width
			seg_min = max(seg_min, w.width)
		}
		unwrapped.x = max(unwrapped.x, seg_w)
		if wrap == .Word {
			min_w = max(min_w, seg_min)
		} else {
			min_w = max(min_w, seg_w)
		}
	}
	unwrapped.y = f32(max(len(e.segs), 1)) * e.line_h
	if wrap == .None && s.ellipsis {
		min_w = min(min_w, ellipsis_width(s))
	}
	return unwrapped, min_w
}

// pack_lines greedily packs word widths into lines of at most max_w.
pack_lines :: proc(words: []Text_Word, space_w: f32, max_w: f32) -> int {
	if len(words) == 0 {
		return 1
	}
	lines := 1
	cur := f32(0)
	for w in words {
		add := w.width
		if cur > 0 {
			add += space_w
		}
		if cur > 0 && cur + add > max_w {
			lines += 1
			cur = w.width // over-wide single words sit alone (and overflow)
		} else {
			cur += add
		}
	}
	return lines
}

// pack_line_breaks is pack_lines that also records [first, past) word-index
// ranges per line into out. The emitter uses it to position fragments.
pack_line_breaks :: proc(words: []Text_Word, space_w: f32, max_w: f32, out: ^[dynamic][2]int) -> int {
	clear(out)
	if len(words) == 0 {
		return 1
	}
	start := 0
	cur := f32(0)
	for w, i in words {
		add := w.width
		if cur > 0 {
			add += space_w
		}
		if cur > 0 && cur + add > max_w {
			append(out, [2]int{start, i})
			start = i
			cur = w.width
		} else {
			cur += add
		}
	}
	append(out, [2]int{start, len(words)})
	return len(out)
}

// wrapped_lines packs the cached words at max_w (pass C).
wrapped_lines :: proc(s: ^Style, spans: []Text_Span, spans_hash: u64, text_hash: u64, text: string, max_w: f32) -> (lines: int, line_h: f32) {
	e := get_text(s, spans, spans_hash, text_hash, text)
	for seg in e.segs {
		lines += pack_lines(seg, e.space_w, max_w)
	}
	return max(lines, 1), e.line_h
}
