// text.odin — mock text measurement.
//
// The real backend asks Skia to shape glyphs. Here every character is 8px wide
// and lines are 16px tall, which keeps every test traceable by hand. The cache
// shape is faithful to the design: words are shaped once per (font, text) and
// line-packing at any width is pure arithmetic.
package niello

CHAR_W :: 8.0
LINE_H :: 16.0
ELLIPSIS_W :: 8.0 // mock width of "…"

// Cached per (font, text): word widths grouped by \n-segment.
Text_Entry :: struct {
	segs: [dynamic][]f32, // segs[i] = word widths of the i-th \n-separated line
}

@(private)
get_text :: proc(font: Font_Handle, text_hash: u64, text: string) -> Text_Entry {
	if g.text_cache == nil {
		g.text_cache = make(map[u64]Text_Entry)
	}
	key := hash_mix(u64(font), text_hash)
	if e, ok := g.text_cache[key]; ok {
		return e
	}
	// Split into \n-segments, then into words (collapsing repeated spaces).
	e := Text_Entry{}
	words: [dynamic]f32
	defer delete(words)
	emit_segment :: proc(e: ^Text_Entry, words: ^[dynamic]f32) {
		seg := make([]f32, len(words))
		copy(seg, words[:])
		append(&e.segs, seg)
		clear(words)
	}
	word_start := -1
	for j := 0; j <= len(text); j += 1 {
		at_end := j == len(text)
		c := u8(' ')
		if !at_end {
			c = text[j]
		}
		if at_end || c == '\n' || c == ' ' {
			if word_start >= 0 {
				append(&words, f32(j-word_start) * CHAR_W)
				word_start = -1
			}
			if at_end || c == '\n' {
				emit_segment(&e, &words)
			}
		} else if word_start < 0 {
			word_start = j
		}
	}
	g.text_cache[key] = e
	return e
}

// pack_lines greedily packs word widths into lines of at most max_w.
pack_lines :: proc(words: []f32, max_w: f32) -> int {
	if len(words) == 0 {
		return 1
	}
	lines := 1
	cur := f32(0)
	for w in words {
		add := w
		if cur > 0 {
			add += CHAR_W // space
		}
		if cur > 0 && cur + add > max_w {
			lines += 1
			cur = w // over-wide single words sit alone (and overflow)
		} else {
			cur += add
		}
	}
	return lines
}

// measure_text returns the unwrapped size and the shrink floor (min_w).
// wrap==.Word -> min_w is the widest word; wrap==.None -> the full width.
measure_text :: proc(font: Font_Handle, text_hash: u64, text: string, wrap: Text_Wrap) -> (unwrapped: Vec2, min_w: f32) {
	e := get_text(font, text_hash, text)
	unwrapped = Vec2{0, 0}
	for seg in e.segs {
		seg_w := f32(0)
		seg_min := f32(0)
		for w, k in seg {
			if k > 0 {
				seg_w += CHAR_W
			}
			seg_w += w
			seg_min = max(seg_min, w)
		}
		unwrapped.x = max(unwrapped.x, seg_w)
		if wrap == .Word {
			min_w = max(min_w, seg_min)
		} else {
			min_w = max(min_w, seg_w)
		}
	}
	unwrapped.y = f32(max(len(e.segs), 1)) * LINE_H
	return unwrapped, min_w
}

// wrapped_lines packs the cached words at max_w (pass C).
wrapped_lines :: proc(font: Font_Handle, text_hash: u64, text: string, max_w: f32) -> int {
	e := get_text(font, text_hash, text)
	lines := 0
	for seg in e.segs {
		lines += pack_lines(seg, max_w)
	}
	return max(lines, 1)
}
