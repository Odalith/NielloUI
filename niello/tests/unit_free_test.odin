// Headless tests for freeing: unmint, group_delete and shutdown.
package tests

import niello ".."
import "core:testing"

@(test)
test_unmint_reuses_slot_under_new_handle :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a, b: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {text = "owned text", color = niello.rgb(0x112233)})
	niello.unmint(a)
	testing.expect(t, !niello.unit_live(a), "an unmint-ed handle is dead")
	niello.mint(&b, niello.NO_UNIT, {})
	testing.expect(t, niello.unit_live(b), "the next mint is live")
	testing.expect(t, niello.unit_index(b) == niello.unit_index(a), "and reuses the freed slot")
	testing.expect(t, b != a, "under a different handle")
	testing.expect(t, niello.style_of(b).color == niello.Color{}, "with a fresh style, not the old unit's")
}

@(test)
test_unmint_clears_references :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	hov, proto, child, btn: niello.Unit
	niello.mint(&hov, niello.NO_UNIT, {color = niello.rgb(0xff0000)})
	niello.mint(&proto, niello.NO_UNIT, {color = niello.rgb(0x00ff00)})
	niello.mint(&child, proto)
	niello.mint(&btn, niello.NO_UNIT, {hover = hov, color = niello.rgb(0x0000ff)})
	grp := niello.group_new("g")
	niello.group_add(grp, hov, btn)

	niello.unmint(hov)
	niello.unmint(proto)
	// The group no longer reaches the freed unit: a broadcast only
	// writes btn.
	niello.group_set(grp, .Gap, u16(7))
	testing.expect(t, niello.style_of(btn).gap == 7, "the surviving member still receives broadcasts")
	// child keeps the values it had, and is no longer derived.
	testing.expect(t, niello.style_of(child).color == niello.rgb(0x00ff00), "a derived unit keeps its values")
	testing.expect(t, niello.test_proto(child) == niello.NO_UNIT, "and loses its prototype link")
	// btn's hover overlay is gone: hovering it changes nothing.
	r: niello.Unit
	niello.mint(&r, niello.NO_UNIT, {size = niello.size(niello.fixed(400), niello.fixed(300))})
	@(static) btn_u, root_u: niello.Unit
	@(static) btn_i: niello.Instance
	btn_u, root_u = btn, r
	niello.set(btn, .Size, niello.size(niello.fixed(100), niello.fixed(40)))
	declare :: proc() {
		if niello.begin(root_u) {
			btn_i = niello.show(btn_u)
		}
	}
	for k in 0 ..< 3 {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}, mouse = {20, 20}, mouse_valid = true}, 0.016)
		declare()
		niello.frame_end()
		_ = k
	}
	testing.expect(t, niello.hovered(btn_i), "the button is hovered")
	br, _ := niello.rect(btn_i)
	c, _ := fill_color_at(br)
	testing.expect(t, c == niello.rgb(0x0000ff), "and paints its own color: the freed hover overlay is gone")
}

@(test)
test_unmint_drops_tweens_and_edits :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	u, pose, r: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {color = niello.rgb(0x000000)})
	niello.mint(&pose, niello.NO_UNIT, {color = niello.rgb(0xffffff)})
	niello.mint(&r, niello.NO_UNIT, {})
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
	niello.tween(u, pose, 500)
	e := niello.edit(u)
	e.gap = 9
	niello.unmint(u)
	// frame_end steps tweens and applies edits: neither may touch the
	// freed slot.
	niello.frame_end()
	testing.expect(t, !niello.unit_live(u), "the unit stays dead")
}

@(test)
test_reused_slot_gets_fresh_identity :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	@(static) root, leaf: niello.Unit
	@(static) inst: niello.Instance
	niello.mint(&root, niello.NO_UNIT, {size = niello.size(niello.fixed(400), niello.fixed(300))})
	niello.mint(&leaf, niello.NO_UNIT, {size = niello.size(niello.fixed(10), niello.fixed(10))})
	declare :: proc() {
		if niello.begin(root) {
			inst = niello.show(leaf)
		}
	}
	frame :: proc() {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
		declare()
		niello.frame_end()
	}
	frame()
	first := inst
	niello.unmint(leaf)
	niello.mint(&leaf, niello.NO_UNIT, {size = niello.size(niello.fixed(10), niello.fixed(10))})
	frame()
	testing.expect(t, inst != first, "the unit in a reused slot is a new instance at the same call site")
}

@(test)
test_group_delete :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {gap = 3})
	grp := niello.group_new("gone")
	niello.group_add(grp, u)
	niello.group_delete(grp)
	testing.expect(t, niello.unit_live(u), "deleting a group leaves its units alone")
	testing.expect(t, niello.style_of(u).gap == 3, "and their values")
}

// shutdown frees everything: the runner's tracking allocator reports any
// leak, so this test passes only if contexts, units, groups, caches and
// arenas are all released. It does not use test_reset.
@(test)
test_shutdown_leaves_nothing_allocated :: proc(t: ^testing.T) {
	@(static) root, label: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.fixed(400), niello.fixed(300))})
	niello.mint(&label, niello.NO_UNIT, {text = "owned", text_spans = []niello.Text_Span{{start = 0, end = 3, font_weight = .Bold}}})
	grp := niello.group_new("g")
	niello.group_add(grp, root, label)
	ctx1 := niello.context_create()
	ctx2 := niello.context_create()
	declare :: proc() {
		if niello.begin(root) {
			niello.show(label, {text = "a label", label = "a11y name", role = .Text})
		}
	}
	for ctx in ([]^niello.Context{ctx1, ctx2}) {
		for _ in 0 ..< 2 {
			niello.frame_begin(ctx, niello.Input{viewport = {400, 300}}, 0.016)
			declare()
			niello.frame_end()
		}
	}
	niello.shutdown()
	testing.expect(t, niello.current_context() == nil, "no context is bound after shutdown")
	// A fresh store works after shutdown.
	again: niello.Unit
	niello.mint(&again, niello.NO_UNIT, {})
	testing.expect(t, niello.unit_live(again), "mint works on the fresh store")
	niello.shutdown()
}

// A variant minted from a base shares its state overlays and
// focusability (TODO #53), not its group memberships.
@(test)
test_mint_from_base_inherits_overlays :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	hov, prs, base, variant, other_hov: niello.Unit
	niello.mint(&hov, niello.NO_UNIT, {color = niello.rgb(0x111111)})
	niello.mint(&prs, niello.NO_UNIT, {color = niello.rgb(0x222222)})
	niello.mint(&other_hov, niello.NO_UNIT, {color = niello.rgb(0x333333)})
	grp := niello.group_new("theme")
	niello.mint(&base, niello.NO_UNIT, {hover = hov, press = prs, focusable = true, groups = []niello.Group{grp}})
	niello.mint(&variant, base, {color = niello.rgb(0xff0000), hover = other_hov})
	testing.expect(t, niello.test_overlay(variant, .Press) == prs, "the press overlay is inherited")
	testing.expect(t, niello.test_overlay(variant, .Hover) == other_hov, "the decl replaces an inherited overlay")
	testing.expect(t, niello.test_focusable(variant), "focusability is inherited")
	niello.clear_overlay(variant, .Press)
	testing.expect(t, niello.test_overlay(base, .Press) == prs, "clearing the variant's overlay leaves the base's")
	niello.group_set(grp, .Gap, u16(5))
	testing.expect(t, niello.style_of(base).gap == 5 && niello.style_of(variant).gap == 0, "the variant did not join the base's group")
}
