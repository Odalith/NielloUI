// stamps_test.odin — the §5 stamps change model (2026-10-23): per-unit
// visual generations, the presented-content digest, and the interaction
// state stamp, replacing the per-instance content hash. Each test pins
// one leg: a damage source the hash covered must still damage, a
// non-source must not, and the new contracts (VISUAL_FIELDS exclusions,
// static_values, per-instance cross-context generations) hold.
package tests

import niello ".."
import "core:testing"

// ---- shared tree: root + box + label --------------------------------------

st_root, st_box, st_lbl, st_tgt, st_flash: niello.Unit
st_text: string
st_static: bool
st_box_i: niello.Instance

declare_st_tree :: proc() {
	if _, ok := niello.begin(st_root); ok {
		st_box_i = niello.show(st_box)
		niello.show(st_lbl, 0, niello.With{text = st_text, static_values = st_static})
	}
}

st_idle :: niello.Input{viewport = {400, 300}}

st_frame :: proc() -> niello.Frame_Result {
	niello.frame_begin(niello.test_context(), st_idle, 1.0 / 60.0)
	declare_st_tree()
	return niello.frame_end()
}

mint_st :: proc() {
	niello.mint(&st_root, niello.NO_UNIT, {size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	niello.mint(&st_box, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(100), niello.fixed(50)},
		color = niello.Color{200, 0, 0, 255},
	})
	niello.mint(&st_lbl, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})
	niello.mint(&st_tgt, niello.NO_UNIT, {color = niello.Color{0, 0, 200, 255}})
	niello.mint(&st_flash, niello.NO_UNIT, {color = niello.Color{0, 200, 0, 255}})
}

// ---- the visual mask -------------------------------------------------------

@(test)
test_stamp_visual_fields_membership :: proc(t: ^testing.T) {
	excluded := [?]niello.Field{.Cursor, .Scroll_Chain, .Smooth_Scroll, .Smooth_Ms, .Overscroll, .Overscroll_Px}
	for f in excluded {
		testing.expect(t, f not_in niello.VISUAL_FIELDS, "non-visual field stays out of the visual mask")
		testing.expect(t, f in niello.ALL_FIELDS, "excluded field still exists in ALL_FIELDS")
	}
	n_all, n_vis := 0, 0
	for f in niello.Field {
		if f in niello.ALL_FIELDS { n_all += 1 }
		if f in niello.VISUAL_FIELDS { n_vis += 1 }
	}
	testing.expect(t, n_vis == n_all - 6, "visual mask is ALL minus exactly the six non-visual fields")
	testing.expect(t, .Color in niello.VISUAL_FIELDS && .Text in niello.VISUAL_FIELDS &&
		.Image in niello.VISUAL_FIELDS, "paint fields are visual")
}

// ---- generation leg --------------------------------------------------------

@(test)
test_stamp_nonvisual_write_no_damage :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_st()
	st_text = ""
	st_static = false

	st_frame()
	res := st_frame()
	testing.expect(t, !res.changed, "settled frame is clean")

	niello.set_many(st_box, {cursor = niello.Cursor_Kind.Pointer})
	res = st_frame()
	testing.expect(t, !res.changed, "cursor-only write must not repaint")

	niello.set(st_box, .Color, niello.Color{0, 0, 200, 255})
	res = st_frame()
	testing.expect(t, res.changed, "color write damages (control)")
	res = st_frame()
	testing.expect(t, !res.changed, "clean again after the restyle")
}

// ---- digest leg: the static_values promise ---------------------------------

@(test)
test_stamp_static_values_trusted :: proc(t: ^testing.T) {
	when #config(NIELLO_DEBUG, false) {
		// Debug builds assert the promise instead of trusting it;
		// breaking it on purpose is not testable there.
		return
	}
	niello.test_reset()
	defer niello.test_teardown()
	mint_st()
	st_static = true
	st_text = "AAAA"

	st_frame()
	res := st_frame()
	testing.expect(t, !res.changed, "static label settles clean")

	st_text = "BBBB" // same size under mock metrics; the promise is
	                 // that the engine does not look
	res = st_frame()
	testing.expect(t, !res.changed, "static_values: changed presented text is not detected, by contract")

	st_static = false
	res = st_frame()
	testing.expect(t, res.changed, "dropping the promise re-arms detection against the frozen baseline")
	res = st_frame()
	testing.expect(t, !res.changed, "clean again")
}

// ---- state stamp leg: overlay generations only count while active --------

st2_root, st2_btn, st2_hov: niello.Unit

declare_st2_tree :: proc() {
	if _, ok := niello.begin(st2_root); ok {
		niello.show(st2_btn)
	}
}

st2_input :: proc(mouse: niello.Vec2) -> niello.Input {
	return niello.Input{viewport = {400, 300}, mouse = mouse, mouse_valid = true, window_focused = true}
}

st2_frame :: proc(mouse: niello.Vec2) -> niello.Frame_Result {
	niello.frame_begin(niello.test_context(), st2_input(mouse), 1.0 / 60.0)
	declare_st2_tree()
	return niello.frame_end()
}

// st2_settle frames until the tree reports clean (births and hover
// transitions each cost a frame) and returns the last result.
st2_settle :: proc(mouse: niello.Vec2) -> niello.Frame_Result {
	res: niello.Frame_Result
	for _ in 0 ..< 5 {
		res = st2_frame(mouse)
		if !res.changed { break }
	}
	return res
}

@(test)
test_stamp_overlay_gen_active_window :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&st2_root, niello.NO_UNIT, {size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	niello.mint(&st2_hov, niello.NO_UNIT, {color = niello.Color{0, 200, 0, 255}})
	niello.mint(&st2_btn, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(100), niello.fixed(50)},
		color = niello.Color{200, 0, 0, 255},
		hover = st2_hov,
	})

	AWAY :: niello.Vec2{300, 200}
	OVER :: niello.Vec2{10, 10}

	res := st2_settle(AWAY)
	testing.expect(t, !res.changed, "settled unhovered")

	niello.set(st2_hov, .Color, niello.Color{0, 0, 200, 255})
	res = st2_frame(AWAY)
	testing.expect(t, !res.changed, "overlay write while inactive costs nothing")

	res = st2_frame(OVER)
	testing.expect(t, res.changed, "hover lands")
	res = st2_settle(OVER)
	testing.expect(t, !res.changed, "hovered and settled")

	niello.set(st2_hov, .Color, niello.Color{200, 200, 0, 255})
	res = st2_frame(OVER)
	testing.expect(t, res.changed, "overlay write while active damages")
	res = st2_settle(OVER)
	testing.expect(t, !res.changed, "settled again")

	res = st2_frame(AWAY)
	testing.expect(t, res.changed, "hover leaves")
	res = st2_settle(AWAY)
	testing.expect(t, !res.changed, "clean at rest")
}

// ---- mutation legs: transients and tweens signal through the stamps -------

@(test)
test_stamp_transient_window :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_st()
	st_text = ""
	st_static = false

	st_frame()
	res := st_frame()
	testing.expect(t, !res.changed, "settled clean")

	niello.transient(st_box_i, st_flash, 100, 100)
	flags: [20]bool
	changed_count := 0
	for i in 0 ..< 20 {
		flags[i] = st_frame().changed
		if flags[i] { changed_count += 1 }
	}
	testing.expect(t, changed_count >= 10 && changed_count <= 16,
		"frames damage while the pulse is in flight")
	// The changed frames form ONE contiguous run from the firing:
	// every in-flight frame damages, the expiry frame damages once
	// (the stamp loses the transient bit), and silence follows.
	first_clean := -1
	for i in 0 ..< 20 {
		if !flags[i] {
			first_clean = i
			break
		}
	}
	testing.expect(t, first_clean > 0, "the pulse ends within the window")
	if first_clean > 0 {
		silent := true
		for i in first_clean ..< 20 {
			if flags[i] { silent = false }
		}
		testing.expect(t, silent, "no damage after the expiry frame")
	}
}

@(test)
test_stamp_tween_window :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	mint_st()
	st_text = ""
	st_static = false

	st_frame()
	res := st_frame()
	testing.expect(t, !res.changed, "settled clean")

	niello.tween(st_box, st_tgt, 100, niello.Fields{.Color})
	testing.expect(t, st_frame().changed, "glide frame 1 damages")
	testing.expect(t, st_frame().changed, "glide frame 2 damages")
	clean_seen := false
	for _ in 0 ..< 12 {
		if !st_frame().changed {
			clean_seen = true
			break
		}
	}
	testing.expect(t, clean_seen, "the glide lands and the tree settles")
	testing.expect(t, !st_frame().changed, "still clean after the glide")
}

// ---- generations are per-instance across contexts --------------------------

xc_root, xc_box: niello.Unit

declare_xc_tree :: proc() {
	if _, ok := niello.begin(xc_root); ok {
		niello.show(xc_box)
	}
}

xc_frame :: proc(ctx: ^niello.Context, input: niello.Input) -> niello.Frame_Result {
	niello.frame_begin(ctx, input, 0.016)
	declare_xc_tree()
	return niello.frame_end()
}

@(test)
test_stamp_cross_context_generation :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ctx1 := niello.test_context()
	ctx2 := niello.context_create()
	defer niello.context_destroy(ctx2)
	niello.mint(&xc_root, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}})
	niello.mint(&xc_box, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(50), niello.fixed(50)},
		color = niello.Color{10, 20, 30, 255},
	})
	inp := niello.Input{viewport = {200, 100}}

	xc_frame(ctx1, inp)
	xc_frame(ctx2, inp)
	testing.expect(t, !xc_frame(ctx1, inp).changed, "ctx1 settled")
	testing.expect(t, !xc_frame(ctx2, inp).changed, "ctx2 settled")

	// One global write: each context owes damage on its OWN next
	// frame. The write is not "used up" by whichever frames first —
	// the old journal-consumption shape would have lost ctx1's
	// damage here; the per-instance generation cannot.
	niello.set(xc_box, .Color, niello.Color{99, 0, 0, 255})
	testing.expect(t, xc_frame(ctx2, inp).changed, "ctx2 damages on its next frame")
	testing.expect(t, !xc_frame(ctx2, inp).changed, "ctx2 clean again")
	testing.expect(t, xc_frame(ctx1, inp).changed, "ctx1 still owes its damage")
	testing.expect(t, !xc_frame(ctx1, inp).changed, "ctx1 clean again")
}
