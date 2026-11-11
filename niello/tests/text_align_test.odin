// Headless tests for a leaf's align placing its text (align[0] each
// line, align[1] the block) and for Style.justify.
// Mock metrics: 8 px per byte at 16 px, lines 16 px tall, space 8.
package tests

import niello ".."
import "core:testing"

ta_root, ta_leaf: niello.Unit
ta_inst: niello.Instance
ta_text: string

ta_setup :: proc(decl: niello.Style_Decl, text: string) {
	niello.test_reset()
	niello.mint(&ta_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(800), niello.fixed(600))})
	niello.mint(&ta_leaf, niello.NO_UNIT, decl)
	ta_text = text
	for _ in 0 ..< 2 {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0.016)
		if niello.begin(ta_root) {
			ta_inst = niello.show(ta_leaf, {text = ta_text})
		}
		niello.frame_end()
	}
}

// ta_texts returns the Text commands' bounds in draw order.
ta_texts :: proc() -> [dynamic]niello.Rect {
	out := make([dynamic]niello.Rect, context.temp_allocator)
	for cmd in niello.draw_list() {
		if cmd.tag == .Text {
			append(&out, cmd.bounds)
		}
	}
	return out
}

@(test)
test_leaf_align_places_text_vertically :: proc(t: ^testing.T) {
	wants := [3]f32{0, 42, 84} // free height 100 - 16 = 84
	for a, k in ([]niello.Align_Kind{.Start, .Center, .End}) {
		ta_setup({size = niello.size(niello.fixed(200), niello.fixed(100)), align = niello.align(.Start, a)}, "Label")
		r, _ := niello.rect(ta_inst)
		b := ta_texts()[0]
		want := wants[k]
		testing.expectf(t, abs(b.pos.y - r.pos.y - want) < EPS, "%v: text at y+%v (got +%v)", a, want, b.pos.y - r.pos.y)
		niello.test_teardown()
	}
}

@(test)
test_one_leaf_centered_button :: proc(t: ^testing.T) {
	// A button as a single node: fixed height, padding, CENTER.
	ta_setup({size = niello.size(niello.fit(), niello.fixed(36)), padding = niello.pad_xy(16, 0), align = niello.CENTER}, "Save")
	defer niello.test_teardown()
	r, _ := niello.rect(ta_inst)
	b := ta_texts()[0]
	testing.expectf(t, abs(r.size.x - (32 + 32)) < EPS, "width is the label plus padding (got %v)", r.size.x)
	testing.expectf(t, abs(b.pos.x - (r.pos.x + 16)) < EPS && abs(b.pos.y - (r.pos.y + 10)) < EPS,
		"the label is centered inside the padding (at %v in %v)", b.pos, r)
}

@(test)
test_justify_spreads_wrapped_lines :: proc(t: ^testing.T) {
	// 100 wide: "aa bb cc dd" (88) | "ee ff gg" — two lines. Justified,
	// the full line spreads to 100: each of its 3 gaps grows by
	// (100 - 88) / 3 = 4. The last line keeps align (Start).
	ta_setup({size = niello.size(niello.fixed(100), niello.fit()), wrap = .Word, justify = true}, "aa bb cc dd ee ff gg")
	defer niello.test_teardown()
	r, _ := niello.rect(ta_inst)
	bs := ta_texts()
	testing.expectf(t, len(bs) == 5, "one command per word on the justified line, one run on the last (got %d)", len(bs))
	if len(bs) == 5 {
		testing.expect(t, abs(bs[0].pos.x - r.pos.x) < EPS, "a justified line starts flush left")
		testing.expectf(t, abs(bs[3].pos.x + bs[3].size.x - (r.pos.x + 100)) < EPS,
			"and its last word ends flush right (ends at %v)", bs[3].pos.x + bs[3].size.x - r.pos.x)
		testing.expectf(t, abs(bs[1].pos.x - bs[0].pos.x - (16 + 8 + 4)) < EPS, "gaps widen evenly (got %v)", bs[1].pos.x - bs[0].pos.x)
		testing.expect(t, abs(bs[4].pos.x - r.pos.x) < EPS, "the paragraph's last line is not spread")
	}
	// Without justify the same text is three ordinary runs.
	niello.test_teardown()
	ta_setup({size = niello.size(niello.fixed(100), niello.fit()), wrap = .Word}, "aa bb cc dd ee ff gg")
	testing.expectf(t, len(ta_texts()) == 2, "unjustified lines stay one run each (got %d)", len(ta_texts()))
}

@(test)
test_justify_leaves_paragraph_ends :: proc(t: ^testing.T) {
	// An explicit newline ends a paragraph: its last line is not spread.
	ta_setup({size = niello.size(niello.fixed(100), niello.fit()), wrap = .Word, justify = true}, "aa bb\ncc dd")
	defer niello.test_teardown()
	testing.expectf(t, len(ta_texts()) == 2, "both lines end a paragraph: one run each (got %d)", len(ta_texts()))
}
