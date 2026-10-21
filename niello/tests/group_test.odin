package tests

import niello ".."
import "core:testing"

// Groups (TODO #7, §3.7): an address book of (unit, field-mask) members.
// Membership writes nothing — group_set is the only group write, and it
// reaches only the members present when it is issued.

grp_root, grp_a, grp_b, grp_lbl: niello.Unit
grp_a_i, grp_b_i, grp_lbl_i: niello.Instance

mint_group_tree :: proc() {
	niello.mint(&grp_root, niello.NO_UNIT, {
		size   = niello.Size{niello.fixed(400), niello.fixed(300)},
		layout = .Top_To_Bottom,
	})
	niello.mint(&grp_a, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(40), niello.fixed(20)},
	})
	niello.mint(&grp_b, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(40), niello.fixed(20)},
	})
	niello.mint(&grp_lbl, niello.NO_UNIT, {}) // FIT: width follows its text
}

declare_group_tree :: proc() {
	if _, ok := niello.begin(grp_root); ok {
		grp_a_i = niello.show(grp_a)
		grp_b_i = niello.show(grp_b)
		grp_lbl_i = niello.show(grp_lbl, 0, {text = "AAAA"})
	}
}

grp_frame :: proc() -> niello.Frame_Result {
	niello.frame_begin(idle_input(AWAY_PT), 0.016)
	return finish(declare_group_tree)
}

expect_width :: proc(t: ^testing.T, i: niello.Instance, want: f32, msg: string) {
	r, ok := niello.rect(i)
	testing.expect(t, ok, "instance has a rect")
	testing.expect(t, abs(r.size.x - want) < EPS, msg)
}

@(test)
test_group_membership_writes_nothing :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	theme := niello.group_new("theme")
	mint_group_tree()
	niello.group_add(theme, grp_a)
	// grp_b joins at mint instead (its own unit, same tree slot shape).
	niello.mint(&grp_b, niello.NO_UNIT, {
		size   = niello.Size{niello.fixed(40), niello.fixed(20)},
		groups = []niello.Group{theme},
	})

	grp_frame()
	expect_width(t, grp_a_i, 40, "group_add membership applies nothing")
	expect_width(t, grp_b_i, 40, "mint-declared membership applies nothing")

	niello.group_set(theme, .Size, niello.Size{niello.fixed(90), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_a_i, 90, "broadcast reaches the group_add member")
	expect_width(t, grp_b_i, 90, "broadcast reaches the mint-declared member")
}

@(test)
test_group_no_retention :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	g := niello.group_new("late")
	// A broadcast with nobody home is gone, not stored for later.
	niello.group_set(g, .Size, niello.Size{niello.fixed(90), niello.fixed(20)})

	mint_group_tree()
	niello.group_add(g, grp_a)
	grp_frame()
	expect_width(t, grp_a_i, 40, "minted after the broadcast: keeps its own values")

	niello.group_set(g, .Size, niello.Size{niello.fixed(70), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_a_i, 70, "but it is located for the next broadcast")
}

@(test)
test_group_masked_membership :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	g := niello.group_new("text-only")
	mint_group_tree()
	niello.group_add_masked(g, niello.Fields{.Font_Size}, grp_lbl)

	grp_frame()
	expect_width(t, grp_lbl_i, 32, "label at the default font size") // 4 chars x 8px

	niello.group_set(g, .Size, niello.Size{niello.fixed(90), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_lbl_i, 32, "Size is outside the mask: broadcast skips it")

	niello.group_set(g, .Font_Size, f32(32))
	grp_frame()
	expect_width(t, grp_lbl_i, 64, "Font_Size is inside the mask: broadcast lands")
}

@(test)
test_group_all_fields_complete :: proc(t: ^testing.T) {
	// Pure: guards the hand-written ALL_FIELDS literal against a Field
	// added later and silently left out of the default mask.
	for f in niello.Field {
		testing.expect(t, f in niello.ALL_FIELDS, "ALL_FIELDS covers every Field")
	}
}

@(test)
test_group_pin :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	g := niello.group_new("actions")
	mint_group_tree()
	niello.group_add(g, grp_lbl)
	niello.pin(grp_lbl, niello.Fields{.Size})

	niello.group_set(g, .Size, niello.Size{niello.fixed(90), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_lbl_i, 32, "pinned field ignores the broadcast")

	niello.group_set(g, .Font_Size, f32(48))
	grp_frame()
	expect_width(t, grp_lbl_i, 96, "pin is per-field: Font_Size still lands")

	niello.unpin(grp_lbl, niello.Fields{.Size})
	niello.group_set(g, .Size, niello.Size{niello.fixed(90), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_lbl_i, 90, "unpin re-admits the field")
}

@(test)
test_group_merge_flattens :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	g1 := niello.group_new("outer")
	g2 := niello.group_new("inner")
	mint_group_tree()
	niello.group_add(g1, grp_a)
	niello.group_add_masked(g2, niello.Fields{.Font_Size}, grp_lbl)
	niello.group_add(g2, grp_b)
	niello.group_merge(g1, g2)

	niello.group_set(g1, .Size, niello.Size{niello.fixed(90), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_a_i, 90, "own member reached")
	expect_width(t, grp_b_i, 90, "merged member reached")
	expect_width(t, grp_lbl_i, 32, "the member's mask traveled with it")

	niello.group_set(g1, .Font_Size, f32(48))
	grp_frame()
	expect_width(t, grp_lbl_i, 96, "merged masked member reached on its field")

	niello.group_set(g2, .Size, niello.Size{niello.fixed(60), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_b_i, 60, "the source group stays independent")
	expect_width(t, grp_a_i, 90, "and reaches only its own members")

	niello.group_add_masked(g1, niello.Fields{.Size}, grp_lbl)
	niello.group_set(g1, .Size, niello.Size{niello.fixed(70), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_lbl_i, 70, "re-adding a member unions the masks")
}

@(test)
test_group_last_write_wins :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	g := niello.group_new("plain")
	mint_group_tree()
	niello.group_add(g, grp_a)

	niello.group_set(g, .Size, niello.Size{niello.fixed(90), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_a_i, 90, "broadcast lands")

	niello.set(grp_a, .Size, niello.Size{niello.fixed(50), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_a_i, 50, "a direct set after the broadcast stands")

	niello.group_set(g, .Size, niello.Size{niello.fixed(70), niello.fixed(20)})
	grp_frame()
	expect_width(t, grp_a_i, 70, "the next broadcast overwrites it: call order decides")
}
