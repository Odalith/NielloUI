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
cx_cap_hovered: bool

@(private)
cx_declare :: proc() {
	niello.show(cx_root)
	if _, open := niello.begin(cx_root); open {
		cx_box_inst = niello.show(cx_box)
		cx_cap_focused = niello.focused(cx_box_inst)
		cx_cap_hovered = niello.hovered(cx_box_inst)
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

// ---- M4: hover, popups, tween ownership, cross-context reads ----

@(test)
test_two_contexts_hover_isolation :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx1 := niello.test_context()
	ctx2 := niello.context_create()
	defer niello.context_destroy(ctx2)
	cx_mint()

	plain := niello.Input{viewport = {200, 100}}
	cx_frame(ctx1, plain)
	cx_frame(ctx2, plain)

	over := niello.Input{viewport = {200, 100}, mouse = {25, 25}, mouse_valid = true}
	cx_frame(ctx1, over)
	testing.expect(t, cx_cap_hovered, "box hovered in ctx1 with the pointer over it")
	cx_frame(ctx2, plain)
	testing.expect(t, !cx_cap_hovered, "ctx2 hover unaffected by ctx1's pointer")
}

@(private)
px_menu: niello.Unit
@(private)
px_popup_inst: niello.Instance
@(private)
px_cap_dismiss: bool

@(private)
px_declare :: proc() {
	if _, open := niello.begin(cx_root); open {
		box := niello.show(cx_box)
		if pi, ok := niello.begin_popup(px_menu, box, .Below, key = niello.key_int(7)); ok {
			px_popup_inst = pi
			px_cap_dismiss = niello.dismiss_requested(pi)
		}
	}
}

@(private)
px_frame :: proc(ctx: ^niello.Context, input: niello.Input) {
	niello.frame_begin(ctx, input, 0.016)
	px_declare()
	niello.frame_end()
}

@(test)
test_two_contexts_popup_isolation :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx1 := niello.test_context()
	ctx2 := niello.context_create()
	defer niello.context_destroy(ctx2)
	cx_mint()
	niello.mint(&px_menu, niello.NO_UNIT, {size = niello.Size{niello.fixed(80), niello.fixed(60)}, color = niello.Color{50, 50, 60, 255}})

	plain := niello.Input{viewport = {200, 100}}
	px_frame(ctx1, plain)
	px_frame(ctx2, plain)
	testing.expect(t, !px_cap_dismiss, "no dismiss before any press")

	// An outside press in ctx2 only: it must flag ctx2's popup and
	// leave ctx1's identical popup untouched.
	press := niello.Input{
		viewport = {200, 100}, mouse = {170, 90}, mouse_valid = true,
		buttons_down = {.Left}, buttons_pressed = {.Left},
	}
	px_frame(ctx2, press)
	testing.expect(t, px_cap_dismiss, "outside press flags ctx2's popup")
	px_frame(ctx1, plain)
	testing.expect(t, !px_cap_dismiss, "ctx1's popup survives ctx2's outside press")
}

@(private)
tw_white, tw_red: niello.Unit

@(private)
box_color :: proc() -> niello.Color {
	for c in niello.draw_list() {
		if c.tag == .Rect && c.bounds == (niello.Rect{{0, 0}, {50, 50}}) {
			return c.color
		}
	}
	return {}
}

@(test)
test_two_contexts_tween_ownership :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx1 := niello.test_context()
	ctx2 := niello.context_create()
	defer niello.context_destroy(ctx2)
	cx_mint() // cx_box starts at {10, 20, 30, 255}
	niello.mint(&tw_white, niello.NO_UNIT, {color = niello.Color{255, 255, 255, 255}})
	niello.mint(&tw_red, niello.NO_UNIT, {color = niello.Color{255, 0, 0, 255}})

	plain := niello.Input{viewport = {200, 100}}
	cx_frame(ctx1, plain)
	cx_frame(ctx2, plain)

	// ctx1 starts a 100ms color glide on the shared box.
	niello.set_current(ctx1)
	niello.tween(cx_box, tw_white, 100, niello.Fields{.Color})

	// ctx2's clock races ahead — it must NOT step ctx1's tween.
	for _ in 0 ..< 4 {
		niello.frame_begin(ctx2, plain, 0.5)
		cx_declare()
		niello.frame_end()
	}
	// ctx1 advances 1ms: the glide has barely begun.
	niello.frame_begin(ctx1, plain, 0.001)
	cx_declare()
	niello.frame_end()
	early := box_color()
	testing.expect(t, early.r < 60, "ctx2's frames did not advance ctx1's tween")

	// ctx2 retargets the same field: ownership transfers (ctx1's
	// tween is cancelled across contexts), and until ctx2 frames,
	// NOTHING moves the value — not even ctx1 with huge steps.
	niello.set_current(ctx2)
	niello.tween(cx_box, tw_red, 100, niello.Fields{.Color})
	for _ in 0 ..< 3 {
		niello.frame_begin(ctx1, plain, 0.5)
		cx_declare()
		niello.frame_end()
	}
	testing.expect(t, box_color() == early, "transferred tween does not step on the old owner's clock")

	// ctx2 frames past the duration: its glide completes exactly.
	niello.frame_begin(ctx2, plain, 0.2)
	cx_declare()
	niello.frame_end()
	testing.expect(t, box_color() == niello.Color{255, 0, 0, 255}, "new owner's tween completes on its own clock")
}

@(private)
rd_root, rd_box: niello.Unit
@(private)
rd_box_inst: niello.Instance

@(private)
rd_declare :: proc() {
	if _, open := niello.begin(rd_root); open {
		rd_box_inst = niello.show(rd_box)
	}
}

@(test)
test_cross_context_reads :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx1 := niello.test_context()
	ctx2 := niello.context_create()
	defer niello.context_destroy(ctx2)

	niello.mint(&rd_root, niello.NO_UNIT, {layout = niello.Layout.Left_To_Right, size = niello.Size{niello.percent(1), niello.percent(1)}})
	niello.mint(&rd_box, niello.NO_UNIT, {size = niello.Size{niello.percent(0.5), niello.fixed(50)}})

	niello.frame_begin(ctx1, niello.Input{viewport = {200, 100}}, 0.016)
	rd_declare()
	niello.frame_end()
	niello.frame_begin(ctx2, niello.Input{viewport = {400, 300}}, 0.016)
	rd_declare()
	niello.frame_end()

	// Bound to ctx2 now: read ctx1's committed state WITHOUT binding
	// it. Same identity, different committed rect per context.
	r1, ok1 := niello.rect_in(ctx1, rd_box_inst)
	testing.expect(t, ok1, "peer rect exists")
	testing.expect(t, r1 == niello.Rect{{0, 0}, {100, 50}}, "peer rect is ctx1's (200-wide tree)")
	r2, _ := niello.rect_in(ctx2, rd_box_inst)
	testing.expect(t, r2 == niello.Rect{{0, 0}, {200, 50}}, "own rect is ctx2's (400-wide tree)")
	u, oku := niello.unit_in(ctx1, rd_box_inst)
	testing.expect(t, oku && u == rd_box, "peer unit lookup")
	testing.expect(t, niello.instance_count(ctx1) == 2 && niello.instance_count(ctx2) == 2, "instance counts per context")
	_, okb := niello.rect_in(ctx1, niello.Instance(987654))
	testing.expect(t, !okb, "unknown instance reads false")
}
