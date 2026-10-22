package tests

// context_test.odin — multi-window M1: two contexts interleaved.
// Units and groups are global; frame state is per-context. These
// tests pin the split: the write journal is consumed per context
// (a dirty bitset survives until EVERY context has framed), and
// focus — a window concept — never leaks across contexts.

import "core:testing"
import niello ".."

@(private)
cx_root: niello.Unit
@(private)
cx_box: niello.Unit
@(private)
cx_box_inst: niello.Instance
@(private)
cx_cap_focused: bool

@(private)
cx_declare :: proc() {
	niello.show(cx_root)
	if _, open := niello.begin(cx_root); open {
		cx_box_inst = niello.show(cx_box)
		cx_cap_focused = niello.focused(cx_box_inst)
	}
}

@(private)
cx_frame :: proc(ctx: ^niello.Context, input: niello.Input) {
	niello.frame_begin(ctx, input, 0.016)
	cx_declare()
	niello.frame_end()
}

@(private)
cx_mint :: proc() {
	niello.mint(&cx_root, niello.NO_UNIT, {size = {niello.fixed(200), niello.fixed(100)}, layout = niello.Layout.Left_To_Right})
	niello.mint(&cx_box, niello.NO_UNIT, {size = {niello.fixed(50), niello.fixed(50)}, color = niello.Color{10, 20, 30, 255}, focusable = true})
}

@(test)
test_two_contexts_journal :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx1 := niello.test_context()
	ctx2 := niello.context_create()
	defer niello.context_destroy(ctx2)
	cx_mint()

	plain := niello.Input{viewport = {200, 100}}
	cx_frame(ctx1, plain)
	cx_frame(ctx2, plain)

	// A global write: both windows must see it, each on its own
	// next frame. After ctx1 frames, the dirty bitset must SURVIVE
	// — ctx2 has not consumed the journal entry yet.
	niello.set(cx_box, .Color, niello.Color{200, 0, 0, 255})
	cx_frame(ctx1, plain)
	testing.expect(t, niello.test_dirty(cx_box) != {}, "dirty survives until every context consumed")
	cx_frame(ctx2, plain)
	testing.expect(t, niello.test_dirty(cx_box) == {}, "dirty clears once all contexts consumed")
}

@(test)
test_two_contexts_focus_isolation :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx1 := niello.test_context()
	ctx2 := niello.context_create()
	defer niello.context_destroy(ctx2)
	cx_mint()

	plain := niello.Input{viewport = {200, 100}}
	cx_frame(ctx1, plain)
	cx_frame(ctx2, plain)

	// Press on the box in ctx1 only (click-to-focus lands at the
	// press dispatch, so the press frame's declare already reads
	// the focus).
	press := niello.Input{
		viewport = {200, 100}, mouse = {25, 25}, mouse_valid = true,
		buttons_down = {.Left}, buttons_pressed = {.Left},
	}
	cx_frame(ctx1, press)
	testing.expect(t, cx_cap_focused, "box focused in ctx1 after click")

	// The same identity, queried during ctx2's declare: untouched.
	cx_frame(ctx2, plain)
	testing.expect(t, !cx_cap_focused, "ctx2 focus unaffected by ctx1's click")
}
