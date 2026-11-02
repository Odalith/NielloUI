// text_test.odin — tests for the font/text system: font fields, spans,
// fragment-aware measurement, per-fragment emission, and backend hooks.
// Mock metrics: char width = size*0.5 (8px at the default 16px), bold x1.12,
// line height = size.
package tests

import niello ".."

import "core:fmt"
import "core:testing"

hook_calls: int
hook_line_calls: int

text_run :: struct {
	text:   string,
	weight: u16,
	color:  [4]u8,
	x:      f32,
}

// text_colors collects the colors of the current draw list's Text
// commands, in emission order.
text_colors :: proc() -> [dynamic]niello.Color {
	colors: [dynamic]niello.Color
	for c in niello.draw_list() {
		if c.tag == .Text {
			append(&colors, c.color)
		}
	}
	return colors
}

// fixed_root mints a 400x300 root; FIT labels inside it measure their text
// instead of filling the viewport (a FIT root fills the viewport).
fixed_root :: proc() -> niello.Unit {
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	return root
}

@(test)
test_font_defaults :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT)
	i: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		i = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()

	// 2 chars x 8px at the default 16px size.
	r, ok := niello.rect(i)
	testing.expect(t, ok)
	testing.expect(t, abs(r.size.x - 16) < EPS, "default font_size 16 -> 16px wide")
	testing.expect(t, abs(r.size.y - 16) < EPS, "default line height 16")
}

@(test)
test_font_size_changes_measurement :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {font_size = f32(32)})
	i: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		i = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()

	// Cache key includes size: 2 chars x 16px at 32px size.
	r, _ := niello.rect(i)
	testing.expect(t, abs(r.size.x - 32) < EPS, "32px font -> 32px wide")
	testing.expect(t, abs(r.size.y - 32) < EPS, "32px line height")
}

@(test)
test_font_setters :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT)
	niello.set(u, .Font_Size, f32(24))
	niello.set(u, .Font_Weight, niello.Font_Weight.Bold)
	niello.set(u, .Font_Slant, niello.Font_Slant.Italic)
	niello.set(u, .Font_Color, [4]u8{255, 0, 0, 255})
	i: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		i = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()

	// Bold: 2 chars x 12px x 1.12.
	r, _ := niello.rect(i)
	testing.expect(t, abs(r.size.x - 26.88) < EPS, "bold 24px measurement")

	found := false
	for c in niello.draw_list() {
		if c.tag == .Text {
			found = true
			testing.expect(t, c.font_size == 24, "command carries font_size")
			testing.expect(t, c.font_weight == 700, "command carries font_weight")
			testing.expect(t, c.font_slant == 1, "command carries font_slant (Italic)")
			testing.expect(t, c.color == [4]u8{255, 0, 0, 255}, "command carries font_color")
		}
	}
	testing.expect(t, found, "expected a Text command")
}

@(test)
test_span_bytes :: proc(t: ^testing.T) {
	s := "Héllo" // é is 2 bytes: H(0) é(1-2) l(3) l(4) o(5)
	bs, be := niello.span_bytes(s, 1, 3)
	testing.expect(t, bs == 1 && be == 4, "rune range [1,3) -> bytes [1,4)")
	testing.expect(t, s[bs:be] == "él", "sliced bytes are the runes")

	bs, be = niello.span_bytes(s, 0, 5)
	testing.expect(t, bs == 0 && be == 6, "full range")

	bs, be = niello.span_bytes(s, 3, 3)
	testing.expect(t, bs == 0 && be == 0, "empty range")

	bs, be = niello.span_bytes(s, 4, 99)
	testing.expect(t, bs == 5 && be == 6, "clamped at the end")
}

@(test)
test_text_spans_fragment_widths :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	u: niello.Unit
	niello.mint(
		&u,
		niello.NO_UNIT,
		{text_spans = []niello.Text_Span{{start = 1, end = 4, font_weight = .Bold}}},
	)
	show :: proc(root, u: niello.Unit) -> niello.Instance {
		i: niello.Instance
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
		if _, ok := niello.begin(root); ok {
			i = niello.show(u, 0, niello.With{text = "Hello you"})
		}
		niello.frame_end()
		return i
	}

	i := show(root, u)
	// "Hello": H(8) + ell(3*8*1.12=26.88) + o(8) = 42.88; space 8; "you" 24.
	r, _ := niello.rect(i)
	testing.expect(t, abs(r.size.x - 74.88) < EPS, "span widths flow into layout")

	// Second frame, same spans: cache hit, same result.
	i2 := show(root, u)
	r2, _ := niello.rect(i2)
	testing.expect(t, abs(r2.size.x - 74.88) < EPS, "cache hit repeats the widths")
}

@(test)
test_span_emission :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	u: niello.Unit
	red := [4]u8{255, 0, 0, 255}
	niello.mint(
		&u,
		niello.NO_UNIT,
		{
			text_spans = []niello.Text_Span{
				{start = 1, end = 4, font_weight = .Bold},
				{start = 6, end = 9, font_color = red},
			},
		},
	)
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		niello.show(u, 0, niello.With{text = "Hello you"})
	}
	niello.frame_end()

	// Runs: "H" regular, "ell" bold, "o " regular (gap merges into the
	// preceding run), "you" red (a new run: the color differs).
	got: [dynamic]text_run
	defer delete(got)
	for c in niello.draw_list() {
		if c.tag == .Text {
			append(&got, text_run{string(c.text_ptr[:c.text_len]), c.font_weight, c.color, c.bounds.pos.x})
		}
	}
	testing.expect(t, len(got) == 4, "four merged runs")
	if len(got) == 4 {
		testing.expect(t, got[0].text == "H" && got[0].weight == 400, "first run")
		testing.expect(t, got[1].text == "ell" && got[1].weight == 700, "bold run")
		testing.expect(t, abs(got[1].x - 8) < EPS, "bold run positioned after H")
		testing.expect(t, got[2].text == "o " && got[2].weight == 400, "gap merges into preceding run")
		testing.expect(t, got[3].text == "you" && got[3].color == red, "red run carries the span color")
		testing.expect(t, abs(got[3].x - 50.88) < EPS, "red run positioned after 'o '")
	}
}

@(test)
test_multiline_emission :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	lbl: niello.Unit
	niello.mint(&lbl, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fit()}, wrap = .Word})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		// 88px unwrapped in a 40px box -> "aa bb" / "cc dd".
		niello.show(lbl, 0, niello.With{text = "aa bb cc dd"})
	}
	niello.frame_end()

	n := 0
	y1 := f32(-1)
	for c in niello.draw_list() {
		if c.tag == .Text {
			n += 1
			if n == 2 {
				y1 = c.bounds.pos.y
			}
			testing.expect(t, !c.truncated, "wrapped lines are never truncated")
		}
	}
	testing.expect(t, n == 2, "one Text command per laid-out line")
	testing.expect(t, abs(y1 - 16) < EPS, "second line steps by line_h")
}

@(test)
test_backend_hooks :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	defer niello.measure_word_hook = nil
	defer niello.line_height_hook = nil
	hook_calls = 0
	hook_line_calls = 0
	niello.measure_word_hook = proc(font: niello.Font_Handle, weight: niello.Font_Weight, slant: niello.Font_Slant, size: f32, text: string) -> f32 {
		hook_calls += 1
		return f32(len(text)) * 10
	}
	niello.line_height_hook = proc(font: niello.Font_Handle, weight: niello.Font_Weight, slant: niello.Font_Slant, size: f32) -> f32 {
		hook_line_calls += 1
		return size * 2
	}

	root := fixed_root()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT)
	i: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		i = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()
	testing.expect(t, hook_calls > 0, "hook fires on cache miss")
	testing.expect(t, hook_line_calls > 0, "line hook fires on cache miss")
	r, _ := niello.rect(i)
	testing.expect(t, abs(r.size.x - 20) < EPS, "backend width is used")
	testing.expect(t, abs(r.size.y - 32) < EPS, "backend line height is used")

	miss_calls := hook_calls
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()
	testing.expect(t, hook_calls == miss_calls, "hook does not fire on cache hit")
}

@(test)
test_font_color_change_recolors_cached_text :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {font_color = niello.Color{10, 20, 30, 255}})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		_ = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()
	colors := text_colors()
	defer delete(colors)
	testing.expect(t, len(colors) == 1 && colors[0] == niello.Color{10, 20, 30, 255},
		"first frame emits the base font_color")

	// Same text, same spans: the word-cache entry is warm and must be
	// reused. Only the paint-only base color changes — a theme
	// broadcast (group_set .Font_Color) does exactly this.
	niello.set(u, .Font_Color, niello.Color{200, 210, 220, 255})
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		_ = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()
	clear(&colors)
	for c in niello.draw_list() {
		if c.tag == .Text {
			append(&colors, c.color)
		}
	}
	testing.expect(t, len(colors) == 1 && colors[0] == niello.Color{200, 210, 220, 255},
		"cached text takes the CURRENT base font_color at emission")
}

@(test)
test_span_color_survives_base_color_change :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	red := niello.Color{255, 0, 0, 255}
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {
		font_color = niello.Color{10, 20, 30, 255},
		text_spans = []niello.Text_Span{{start = 0, end = 1, font_color = red}},
	})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		_ = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()
	colors := text_colors()
	defer delete(colors)
	testing.expect(t, len(colors) == 2 && colors[0] == red &&
		colors[1] == niello.Color{10, 20, 30, 255},
		"span fragment red, base fragment in the base color")

	niello.set(u, .Font_Color, niello.Color{200, 210, 220, 255})
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		_ = niello.show(u, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()
	clear(&colors)
	for c in niello.draw_list() {
		if c.tag == .Text {
			append(&colors, c.color)
		}
	}
	testing.expect(t, len(colors) == 2 && colors[0] == red &&
		colors[1] == niello.Color{200, 210, 220, 255},
		"span override is keyed and survives; the base fragment follows the new color")
}

// A unit OWNS its spans (and its style text): mint/set clone the
// reference-typed fields, so a caller mutating its slice afterwards
// cannot reach in. This is the deterministic form of a real failure:
// apps mint inside an init proc that returns, the stored header kept
// pointing at that dead frame, and at -o:none every span silently
// vanished (the suite runs -o:speed, whose layout luck masked it).
@(test)
test_style_spans_are_owned_copies :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	u: niello.Unit
	spans := []niello.Text_Span{{start = 1, end = 4, font_weight = .Bold}}
	niello.mint(&u, niello.NO_UNIT, {text_spans = spans})
	spans[0] = niello.Text_Span{start = 0, end = 0} // the caller scribbles

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		niello.show(u, 0, niello.With{text = "Hello you"})
	}
	niello.frame_end()
	bold := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Text && cmd.font_weight == 700 {
			bold = true
		}
	}
	testing.expect(t, bold, "mint cloned the spans; the scribble did not reach the unit")

	// Same for the set() path, with a color span this time.
	spans2 := []niello.Text_Span{{start = 0, end = 5, font_color = niello.Color{9, 8, 7, 255}}}
	niello.set(u, .Text_Spans, spans2)
	spans2[0] = niello.Text_Span{}
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if _, ok := niello.begin(root); ok {
		niello.show(u, 0, niello.With{text = "Hello you"})
	}
	niello.frame_end()
	want := niello.Color{9, 8, 7, 255}
	colored := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Text && cmd.color == want {
			colored = true
		}
	}
	testing.expect(t, colored, "set cloned the spans too")
}

// ---------------------------------------------------------------------------
// Whitespace modes (§3.18). Mock metrics: every character, spaces
// included, is 8px at the default size.

ws_root_u, ws_u: niello.Unit
ws_i: niello.Instance
ws_text_v: string
ws_spans_v: []niello.Text_Span

ws_declare :: proc() {
	if _, ok := niello.begin(ws_root_u); ok {
		ws_i = niello.show(ws_u, 0, {text = ws_text_v, text_spans = ws_spans_v})
	}
}

ws_measure :: proc(text: string) -> f32 {
	ws_text_v = text
	ws_spans_v = nil
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	ws_declare()
	niello.frame_end()
	r, _ := niello.rect(ws_i)
	return r.size.x
}

@(test)
test_whitespace_collapse_is_the_default :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ws_root_u = fixed_root()
	niello.mint(&ws_u, niello.NO_UNIT, {}) // no whitespace field: Collapse
	testing.expect(t, abs(ws_measure("aa bb") - 40) < EPS, "one gap counts once")
	testing.expect(t, abs(ws_measure("aa  bb") - 40) < EPS, "a run collapses to one gap")
	testing.expect(t, abs(ws_measure("aa ") - 16) < EPS, "trailing space hangs")
	testing.expect(t, abs(ws_measure(" aa") - 16) < EPS, "leading space hangs")
}

@(test)
test_whitespace_preserve_counts_every_space :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ws_root_u = fixed_root()
	niello.mint(&ws_u, niello.NO_UNIT, {whitespace = niello.Whitespace.Preserve})
	testing.expect(t, abs(ws_measure("aa bb") - 40) < EPS, "one space, one advance")
	testing.expect(t, abs(ws_measure("aa  bb") - 48) < EPS, "a run counts in full")
	testing.expect(t, abs(ws_measure("aa ") - 24) < EPS, "trailing space counts (caret truth)")
	testing.expect(t, abs(ws_measure(" aa") - 24) < EPS, "leading space counts")
	testing.expect(t, abs(ws_measure("aa bb ") - 48) < EPS, "trailing after words counts")
}

@(test)
test_whitespace_preserve_gap_uses_its_own_style :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ws_root_u = fixed_root()
	niello.mint(&ws_u, niello.NO_UNIT, {whitespace = niello.Whitespace.Preserve})
	// The space sits under a 32px span: its advance is 16, not 8 —
	// gaps are cut at span boundaries and priced per style, like words.
	spans := make([]niello.Text_Span, 1)
	spans[0] = niello.Text_Span{start = 1, end = 2, font_size = f32(32)}
	ws_spans_v = spans
	ws_text_v = "a b"
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	ws_declare()
	niello.frame_end()
	r, _ := niello.rect(ws_i)
	testing.expect(t, abs(r.size.x - 32) < EPS, "8 + 16 (span-sized space) + 8")
	delete(spans)
}

wrapbox_u: niello.Unit
wrap_a_i, wrap_b_i: niello.Instance
wrap_a_u, wrap_b_u: niello.Unit

wrap_declare :: proc() {
	if _, ok := niello.begin(ws_root_u); ok {
		wrap_a_i = niello.show(wrap_a_u, niello.key_int(1), {text = "aa  bb"})
		wrap_b_i = niello.show(wrap_b_u, niello.key_int(2), {text = "aa  bb"})
	}
}

@(test)
test_whitespace_preserve_wrap_breaks_on_real_gaps :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ws_root_u = fixed_root()
	box := niello.Style_Decl{
		size = niello.Size{niello.fixed(40), niello.fit()},
		wrap = niello.Text_Wrap.Word,
	}
	niello.mint(&wrap_a_u, niello.NO_UNIT, box) // Collapse
	box.whitespace = niello.Whitespace.Preserve
	niello.mint(&wrap_b_u, niello.NO_UNIT, box) // Preserve
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	wrap_declare()
	niello.frame_end()
	ra, _ := niello.rect(wrap_a_i)
	rb, _ := niello.rect(wrap_b_i)
	// Collapse: 16 + 8 + 16 = 40 fits the box -> one line.
	testing.expect(t, abs(ra.size.y - 16) < EPS, "collapse fits on one line")
	// Preserve: 16 + 16 + 16 = 48 > 40 -> the real gap forces a break.
	testing.expect(t, abs(rb.size.y - 32) < EPS, "preserve wraps at the real gap width")
}

@(test)
test_whitespace_preserve_emission_positions :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ws_root_u = fixed_root()
	niello.mint(&ws_u, niello.NO_UNIT, {whitespace = niello.Whitespace.Preserve})
	// Leading spaces: the emitted run's bytes extend over them and
	// its width prices them, so following content sits at the true x.
	ws_text_v = "  aa"
	ws_spans_v = nil
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	ws_declare()
	niello.frame_end()
	found := false
	for c in niello.draw_list() {
		if c.tag == .Text {
			txt := string(c.text_ptr[:c.text_len])
			testing.expect(t, txt == "  aa", "the run carries the leading spaces")
			testing.expect(t, abs(c.bounds.size.x - 32) < EPS, "and prices them (4 chars)")
			found = true
		}
	}
	testing.expect(t, found, "a text command was emitted")
}

// ---------------------------------------------------------------------------
// With.text is copied into the frame arena at declare time: a caller
// may reuse ONE scratch buffer for every row (the virtualized-list
// pattern). Before the copy existed, every row rendered the buffer's
// final contents sliced to its own length.

@(test)
test_with_text_copied_at_declare :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root := fixed_root()
	leaf: niello.Unit
	niello.mint(&leaf, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(120), niello.fixed(20)},
	})
	buf: [16]u8
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
	if _, ok := niello.begin(root); ok {
		for k in 0 ..< 3 {
			n := len(fmt.bprintf(buf[:], "Row %d", k + 1))
			niello.show(leaf, niello.key_int(k + 1), {text = string(buf[:n])})
		}
	}
	niello.frame_end()
	seen: [3]bool
	for cmd in niello.draw_list() {
		if cmd.tag != .Text {
			continue
		}
		txt := string(cmd.text_ptr[:cmd.text_len])
		switch txt {
		case "Row 1":
			seen[0] = true
		case "Row 2":
			seen[1] = true
		case "Row 3":
			seen[2] = true
		}
	}
	testing.expect(t, seen[0] && seen[1] && seen[2],
		"each row kept its own bytes despite the shared buffer")
}
