package tests

// Mutation layer (TODO #7, §3.16): tweens, group_tween, group_set with
// ms, edit, propagate, transient. Time is deterministic here: the
// engine clock accumulates frame_begin's dt, so a frame helper with a
// fixed dt steps animations exactly. House curve is cubic ease-out:
// e(0.5) = 0.875, which the midpoint assertions lean on.

import "core:testing"
import niello ".."

m_input :: niello.Input{viewport = {400, 300}, window_focused = true}

// mframe runs one frame with an explicit dt (seconds).
mframe :: proc(declare: proc(), dt: f32) -> niello.Frame_Result {
	niello.frame_begin(niello.test_context(), m_input, dt)
	declare()
	return niello.frame_end()
}

noop_declare :: proc() {}

// ---------------------------------------------------------------------------
// Tweens

@(test)
test_tween_glides_and_lands :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a, b: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {color = niello.Color{0, 0, 0, 255}})
	niello.mint(&b, niello.NO_UNIT, {color = niello.Color{200, 100, 40, 255}})

	mframe(noop_declare, 0.016) // establish the clock
	niello.tween(a, b, 100, niello.Fields{.Color})
	fr := mframe(noop_declare, 0.05) // elapsed 50: t=0.5, e=0.875
	testing.expect(t, fr.next_wake_ms <= 16, "an active tween keeps a short wake")
	testing.expect(t, niello.test_style(a).color == niello.Color{175, 88, 35, 255},
		"midpoint is the eased interpolation")
	fr = mframe(noop_declare, 0.05) // elapsed 100: lands exactly
	testing.expect(t, niello.test_style(a).color == niello.Color{200, 100, 40, 255},
		"a finished glide lands on the exact target")
	testing.expect(t, fr.next_wake_ms == max(u32),
		"with nothing animating, the wake returns to infinity")
}

@(test)
test_tween_snaps_discrete_fields_at_t0 :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a, b: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {color = niello.Color{0, 0, 0, 255}})
	niello.mint(&b, niello.NO_UNIT, {
		color  = niello.Color{200, 0, 0, 255},
		layout = niello.Layout.Top_To_Bottom,
	})
	niello.tween(a, b, 100) // ALL_FIELDS
	mframe(noop_declare, 0.016)
	testing.expect(t, niello.test_style(a).layout == niello.Layout.Top_To_Bottom,
		"Layout snapped at t=0")
	c := niello.test_style(a).color.r
	testing.expect(t, c > 0 && c < 200, "Color is mid-glide, not snapped")
}

@(test)
test_tween_retarget_is_continuous :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a, b, c: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {color = niello.Color{0, 0, 0, 255}})
	niello.mint(&b, niello.NO_UNIT, {color = niello.Color{200, 0, 0, 255}})
	niello.mint(&c, niello.NO_UNIT, {color = niello.Color{0, 0, 0, 255}})
	niello.tween(a, b, 100, niello.Fields{.Color})
	mframe(noop_declare, 0.05) // elapsed 50: at 175 now
	testing.expect(t, niello.test_style(a).color.r == 175, "mid-glide value")
	niello.tween(a, c, 100, niello.Fields{.Color}) // retarget back to black
	mframe(noop_declare, 0.05) // t=0.5 of the new glide
	testing.expect(t, niello.test_style(a).color.r == 22,
		"lerp(175 -> 0, 0.875) = 22: from re-snapshotted the live value, no jump")
}

@(test)
test_set_cancels_glide :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a, b: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {color = niello.Color{0, 0, 0, 255}})
	niello.mint(&b, niello.NO_UNIT, {color = niello.Color{200, 0, 0, 255}})
	niello.tween(a, b, 100, niello.Fields{.Color})
	mframe(noop_declare, 0.05)
	niello.set(a, .Color, niello.Color{9, 9, 9, 255})
	mframe(noop_declare, 0.05)
	mframe(noop_declare, 0.05)
	testing.expect(t, niello.test_style(a).color == niello.Color{9, 9, 9, 255},
		"an explicit set cancels the glide and sticks")
}

@(test)
test_set_equal_is_noop :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {
		size  = niello.Size{niello.fixed(100), niello.fixed(50)},
		color = niello.Color{10, 20, 30, 255},
		text  = "hello",
	})

	// Size: the Nachtul case — writing the same Size again bumps nothing.
	gen0 := niello.test_generation()
	niello.set(a, .Size, niello.Size{niello.fixed(100), niello.fixed(50)})
	testing.expect(t, niello.test_generation() == gen0,
		"an equal Size set bumps nothing")
	niello.set(a, .Size, niello.Size{niello.fixed(120), niello.fixed(50)})
	testing.expect(t, niello.test_generation() > gen0,
		"a changed Size set still bumps")
	gen1 := niello.test_generation()
	niello.set(a, .Size, niello.Size{niello.fixed(120), niello.fixed(50)})
	testing.expect(t, niello.test_generation() == gen1,
		"the new value, written again, bumps nothing")

	// Text: equal content is a no-op even from a fresh string, and the
	// stored text survives (compare-before-clone, no delete + re-clone).
	niello.set(a, .Text, "hello")
	testing.expect(t, niello.test_generation() == gen1,
		"an equal Text set bumps nothing")
	testing.expect(t, niello.test_style(a).text == "hello",
		"the equal Text set leaves the stored text alone")
	niello.set(a, .Text, "goodbye")
	testing.expect(t, niello.test_style(a).text == "goodbye",
		"a changed Text set still writes")

	// Spans: equal elements are a no-op even from a fresh slice.
	spans := []niello.Text_Span{{start = 0, end = 5}}
	niello.set(a, .Text_Spans, spans)
	gen2 := niello.test_generation()
	niello.set(a, .Text_Spans, []niello.Text_Span{{start = 0, end = 5}})
	testing.expect(t, niello.test_generation() == gen2,
		"an equal Text_Spans set bumps nothing")

	// Glide exception: an equal set while gliding still cancels the glide.
	c: niello.Unit
	niello.mint(&c, niello.NO_UNIT, {color = niello.Color{0, 0, 0, 255}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {color = niello.Color{200, 0, 0, 255}})
	niello.tween(c, b, 100, niello.Fields{.Color})
	mframe(noop_declare, 0.05) // mid-glide: 175
	testing.expect(t, niello.test_style(c).color.r == 175, "mid-glide value")
	niello.set(c, .Color, niello.Color{175, 0, 0, 255})
	mframe(noop_declare, 0.05)
	mframe(noop_declare, 0.05)
	testing.expect(t, niello.test_style(c).color == niello.Color{175, 0, 0, 255},
		"an equal set mid-glide still cancels the glide and sticks")
}

@(test)
test_tween_size_value_glides :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a, b: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(100), niello.fixed(50)},
	})
	niello.mint(&b, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(50)},
	})
	niello.tween(a, b, 100, niello.Fields{.Size})
	mframe(noop_declare, 0.05)
	s := niello.test_style(a).size
	testing.expect(t, abs(s[0].value - 187.5) < EPS,
		"same-kind Size values interpolate (100 -> 200 at e=0.875)")
}

// ---------------------------------------------------------------------------
// Group forms

@(test)
test_group_tween_respects_pin :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	m1, m2, dark: niello.Unit
	niello.mint(&m1, niello.NO_UNIT, {color = niello.Color{240, 240, 240, 255}})
	niello.mint(&m2, niello.NO_UNIT, {color = niello.Color{240, 240, 240, 255}})
	niello.mint(&dark, niello.NO_UNIT, {color = niello.Color{16, 16, 16, 255}})
	grp := niello.group_new("surfaces")
	niello.group_add(grp, m1)
	niello.group_add(grp, m2)
	niello.pin(m2, niello.Fields{.Color})

	niello.group_tween(grp, dark, 100, niello.Fields{.Color})
	mframe(noop_declare, 0.05)
	testing.expect(t, niello.test_style(m1).color.r == 44,
		"member glides (240 -> 16 at e=0.875 is 44)")
	testing.expect(t, niello.test_style(m2).color.r == 240,
		"the pinned member does not move")
}

@(test)
test_group_set_with_ms_glides :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	m1: niello.Unit
	niello.mint(&m1, niello.NO_UNIT, {color = niello.Color{0, 0, 0, 255}})
	grp := niello.group_new("g")
	niello.group_add(grp, m1)
	niello.group_set(grp, .Color, niello.Color{200, 0, 0, 255}, 100)
	mframe(noop_declare, 0.05)
	testing.expect(t, niello.test_style(m1).color.r == 175,
		"group_set with ms glides instead of landing immediately")
	mframe(noop_declare, 0.05)
	testing.expect(t, niello.test_style(m1).color.r == 200, "and lands")
}

// ---------------------------------------------------------------------------
// Edit

@(test)
test_edit_applies_only_changed_fields :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {
		color     = niello.Color{1, 2, 3, 255},
		font_size = 16,
	})
	s := niello.edit(a)
	s.color = niello.Color{50, 60, 70, 255}
	// An intervening set on a field the shadow did not touch must not
	// be clobbered by the frame-end diff.
	niello.set(a, .Font_Size, f32(22))
	mframe(noop_declare, 0.016)
	testing.expect(t, niello.test_style(a).color == niello.Color{50, 60, 70, 255},
		"the changed field applied")
	testing.expect(t, niello.test_style(a).font_size == 22,
		"the intervening set on an untouched field survived")
}

// ---------------------------------------------------------------------------
// Propagate

@(test)
test_propagate_flows_and_respects_explicit :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	proto, child, grand: niello.Unit
	niello.mint(&proto, niello.NO_UNIT, {
		color     = niello.Color{10, 0, 0, 255},
		font_size = 20,
	})
	niello.mint(&child, proto)
	niello.mint(&grand, child)
	niello.set(child, .Color, niello.Color{99, 0, 0, 255}) // child's own choice

	niello.set(proto, .Color, niello.Color{30, 0, 0, 255})
	niello.set(proto, .Font_Size, f32(24))
	niello.propagate(proto, niello.ALL_FIELDS)
	mframe(noop_declare, 0.016)

	testing.expect(t, niello.test_style(child).color.r == 99,
		"an explicitly set field is the unit's own — propagation skips it")
	testing.expect(t, niello.test_style(child).font_size == 24,
		"a never-explicit field receives the proto's new value")
	testing.expect(t, niello.test_style(grand).font_size == 24,
		"the push is transitive in one call (proto -> child -> grandchild)")
	testing.expect(t, niello.test_style(grand).color.r == 99,
		"the grandchild receives the child's current value, explicit and all")

	// Propagated values are not marked explicit: they keep flowing.
	niello.set(proto, .Font_Size, f32(30))
	niello.propagate(proto, niello.ALL_FIELDS)
	testing.expect(t, niello.test_style(child).font_size == 30,
		"a second propagate still reaches the child")
	testing.expect(t, niello.test_style(grand).font_size == 30,
		"and the grandchild")
}

// ---------------------------------------------------------------------------
// Transients

tr_root, tr_box, tr_flash: niello.Unit
tr_box_i: niello.Instance
tr_fire: bool

declare_tr_tree :: proc() {
	if _, ok := niello.begin(tr_root); ok {
		tr_box_i = niello.show(tr_box)
		if tr_fire {
			niello.transient(tr_box_i, tr_flash, 100, 100)
			tr_fire = false
		}
	}
}

// fill_color_at finds the Rect command painted at the given rect —
// how the resolved (post-transient) color is observed headlessly.
fill_color_at :: proc(r: niello.Rect) -> (niello.Color, bool) {
	for cmd in niello.draw_list() {
		if cmd.tag == .Rect && cmd.bounds == r {
			return cmd.color, true
		}
	}
	return {}, false
}

@(test)
test_transient_envelope :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&tr_root, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(100)},
	})
	niello.mint(&tr_box, niello.NO_UNIT, {
		size  = niello.Size{niello.fixed(80), niello.fixed(40)},
		color = niello.Color{40, 40, 40, 255},
	})
	niello.mint(&tr_flash, niello.NO_UNIT, {color = niello.Color{240, 240, 240, 255}})

	mframe(declare_tr_tree, 0.05) // settle frame
	r, _ := niello.rect(tr_box_i)
	c, ok := fill_color_at(r)
	testing.expect(t, ok && c.r == 40, "base color before the pulse")

	tr_fire = true
	mframe(declare_tr_tree, 0.05) // fires this frame; k = 0 at resolve
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 40, "the fire frame starts at k=0")
	mframe(declare_tr_tree, 0.05) // elapsed 50: in-phase k=0.5
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 140, "halfway in, the color is the midpoint")
	mframe(declare_tr_tree, 0.05) // elapsed 100: the peak
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 240, "the peak shows the full flash color")
	mframe(declare_tr_tree, 0.05) // elapsed 150: out-phase k=0.5
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 140, "halfway out, the midpoint again")
	fr := mframe(declare_tr_tree, 0.05) // elapsed 200: expired
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 40, "after the envelope, the base color is back")
	testing.expect(t, fr.next_wake_ms == max(u32),
		"and the wake returns to infinity")
}

@(test)
test_transient_is_paint_only :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&tr_root, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(100)},
	})
	niello.mint(&tr_box, niello.NO_UNIT, {
		size  = niello.Size{niello.fixed(80), niello.fixed(40)},
		color = niello.Color{40, 40, 40, 255},
	})
	// The flash unit also declares a Size — a layout field, which a
	// transient must ignore.
	niello.mint(&tr_flash, niello.NO_UNIT, {
		color = niello.Color{240, 240, 240, 255},
		size  = niello.Size{niello.fixed(190), niello.fixed(90)},
	})
	mframe(declare_tr_tree, 0.05)
	r0, _ := niello.rect(tr_box_i)
	tr_fire = true
	mframe(declare_tr_tree, 0.05)
	mframe(declare_tr_tree, 0.05) // k=0.5: color blended...
	c, _ := fill_color_at(r0)
	testing.expect(t, c.r == 140, "...the paint field blends")
	r1, _ := niello.rect(tr_box_i)
	testing.expect(t, r1 == r0, "...but the rect never moves: Size is ignored")
}

// Re-firing the identical pulse while it is in flight must be a
// no-op: the natural pattern `if hovered(i) { transient(i, ...) }`
// calls transient every frame for the whole hover, and restarting
// the envelope on each call would pin it at k=0 until the hover
// ends. A fire with different parameters still replaces.
tr_fire_always: bool

declare_tr_tree_always :: proc() {
	if _, ok := niello.begin(tr_root); ok {
		tr_box_i = niello.show(tr_box)
		if tr_fire_always {
			niello.transient(tr_box_i, tr_flash, 100, 100)
		}
	}
}

@(test)
test_transient_refire_does_not_restart :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&tr_root, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(200), niello.fixed(100)},
	})
	niello.mint(&tr_box, niello.NO_UNIT, {
		size  = niello.Size{niello.fixed(80), niello.fixed(40)},
		color = niello.Color{40, 40, 40, 255},
	})
	niello.mint(&tr_flash, niello.NO_UNIT, {color = niello.Color{240, 240, 240, 255}})

	mframe(declare_tr_tree_always, 0.05) // settle
	r, _ := niello.rect(tr_box_i)
	tr_fire_always = true
	mframe(declare_tr_tree_always, 0.05) // fires; k=0
	c, _ := fill_color_at(r)
	testing.expect(t, c.r == 40, "the pulse starts")
	mframe(declare_tr_tree_always, 0.05) // re-fired identically: no-op
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 140,
		"the envelope advanced on the FIRST fire's schedule (k=0.5), not restarted")
	mframe(declare_tr_tree_always, 0.05)
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 240, "and peaks on schedule")
	mframe(declare_tr_tree_always, 0.05)
	mframe(declare_tr_tree_always, 0.05) // first pulse expires this frame
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 40, "the pulse ended on schedule despite constant re-firing")
	mframe(declare_tr_tree_always, 0.05) // a fresh pulse begins (the guard still holds)
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 140, "after expiry, the next identical fire starts a new pulse")
	tr_fire_always = false

	// A fire with different parameters replaces mid-flight.
	tr_fire = true
	mframe(declare_tr_tree, 0.05) // fires (100/100)
	mframe(declare_tr_tree, 0.05) // k=0.5 of that envelope
	niello.transient(tr_box_i, tr_flash, 100, 400) // different out_ms
	mframe(declare_tr_tree, 0.05) // the replacement's own k=0.5 point is also 140...
	c, _ = fill_color_at(r)
	testing.expect(t, c.r == 140, "the replacement is mid-in-phase")
	mframe(declare_tr_tree, 0.05) // old envelope would have ENDED the out phase by now;
	c, _ = fill_color_at(r)        // the replacement (out=400) is still near its peak
	testing.expect(t, c.r > 200, "the replacement envelope governs, not the original")
}
