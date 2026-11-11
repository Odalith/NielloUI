package tests

import "core:testing"
import niello ".."

wp_root, wp_col, wp_row, wp_card, wp_fitcol, wp_note, wp_btn: niello.Unit
wp_note_i, wp_btn_i, wp_mid_i: niello.Instance
wp_shape: int

LONG :: "the quick brown fox jumps over the lazy dog and keeps on running far beyond the edge of any reasonable box"

wp_declare :: proc() {
	if niello.begin(wp_root) {
		switch wp_shape {
		case 0: // A: column > note
			if niello.begin(wp_col, out = &wp_mid_i) { wp_note_i = niello.show(wp_note, {text = LONG}) }
		case 1: // B: column > grow card > note
			if niello.begin(wp_col) { if niello.begin(wp_card, out = &wp_mid_i) { wp_note_i = niello.show(wp_note, {text = LONG}) } }
		case 2: // C: row > [button, note]
			if niello.begin(wp_row, out = &wp_mid_i) {
				wp_btn_i = niello.show(wp_btn, {text = "Button"})
				wp_note_i = niello.show(wp_note, {text = LONG})
			}
		case 3: // D: column > fit column > note
			if niello.begin(wp_col) { if niello.begin(wp_fitcol, out = &wp_mid_i) { wp_note_i = niello.show(wp_note, {text = LONG}) } }
		case 4: // E: row > fit column > note
			if niello.begin(wp_row) { if niello.begin(wp_fitcol, out = &wp_mid_i) { wp_note_i = niello.show(wp_note, {text = LONG}) } }
		}
	}
}

// A Fit-width paragraph with wrap = .Word takes at most the width it is
// offered and wraps there, whatever kind of container it sits in.
@(test)
test_fit_width_wrapped_text_wraps :: proc(t: ^testing.T) {
	// shape -> expected note width (the parent's inner width)
	want := [?]f32{400, 380, 0, 380, 380}
	for shape in ([]int{0, 1, 3, 4}) {
		niello.test_reset()
		niello.mint(&wp_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(400), niello.fixed(400))})
		niello.mint(&wp_col, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(400), niello.fit())})
		niello.mint(&wp_row, niello.NO_UNIT, {layout = .Left_To_Right, size = niello.size(niello.fixed(400), niello.fit()), gap = 10})
		niello.mint(&wp_card, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.grow(), niello.fit()), padding = niello.pad(10)})
		niello.mint(&wp_fitcol, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fit(), niello.fit()), padding = niello.pad(10)})
		niello.mint(&wp_note, niello.NO_UNIT, {wrap = .Word})
		niello.mint(&wp_btn, niello.NO_UNIT, {padding = niello.pad_xy(10, 4)})
		wp_shape = shape
		for _ in 0 ..< 2 {
			niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0.016)
			wp_declare()
			niello.frame_end()
		}
		nr, _ := niello.rect(wp_note_i)
		testing.expectf(t, abs(nr.size.x - want[shape]) < EPS, "shape %d: the paragraph takes the offered width (got %v)", shape, nr.size.x)
		testing.expectf(t, nr.size.y > 16 + EPS, "shape %d: and wraps onto several lines (height %v)", shape, nr.size.y)
		niello.test_teardown()
	}
}
