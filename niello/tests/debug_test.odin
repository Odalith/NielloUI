package tests

// debug_test.odin — TODO #18 D1/D2: the gated debug snapshot,
// the §3.13 overflow report, and the highlight channel. The
// whole file compiles only under -define:NIELLO_DEBUG=true; a
// prod test run never sees these tests (or the API they pin).

import "core:testing"
import niello ".."

when niello.NIELLO_DEBUG {

	@(private)
	dbg_root, dbg_wide, dbg_leaf, dbg_scroll, dbg_tall: niello.Unit
	@(private)
	dbg_root_inst, dbg_leaf_inst: niello.Instance

	@(private)
	dbg_declare :: proc() {
		if r, open := niello.begin(dbg_root); open {
			dbg_root_inst = r
			niello.show(dbg_wide)
			dbg_leaf_inst = niello.show(dbg_leaf)
			if _, open2 := niello.begin(dbg_scroll); open2 {
				niello.show(dbg_tall)
			}
		}
	}

	@(private)
	dbg_frame :: proc(ctx: ^niello.Context) {
		niello.frame_begin(ctx, niello.Input{viewport = {400, 300}}, 0.016)
		dbg_declare()
		niello.frame_end()
	}

	@(private)
	dbg_mint :: proc() {
		niello.mint(&dbg_root, niello.NO_UNIT, {
			layout = niello.Layout.Top_To_Bottom,
			size = niello.Size{niello.fixed(200), niello.fixed(100)},
		})
		niello.mint(&dbg_wide, niello.NO_UNIT, {size = niello.Size{niello.fixed(300), niello.fixed(20)}})
		niello.mint(&dbg_leaf, niello.NO_UNIT, {
			size = niello.Size{niello.fixed(40), niello.fixed(20)},
			text = "a much longer piece of text",
			color = niello.Color{9, 8, 7, 255},
		})
		niello.mint(&dbg_scroll, niello.NO_UNIT, {
			size = niello.Size{niello.fixed(100), niello.fixed(50)},
			scroll = niello.Scroll.Vertical,
		})
		niello.mint(&dbg_tall, niello.NO_UNIT, {size = niello.Size{niello.fixed(80), niello.fixed(200)}})
	}

	@(private)
	dbg_overlay_count :: proc(color: niello.Color) -> int {
		n := 0
		for cmd in niello.draw_list() {
			if cmd.tag == .Overlay && cmd.color == color {
				n += 1
			}
		}
		return n
	}

	@(test)
	test_debug_tree_cross_context :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		ctx1 := niello.test_context()
		ctx2 := niello.context_create()
		defer niello.context_destroy(ctx2)
		dbg_mint()
		dbg_frame(ctx1)
		dbg_frame(ctx2) // bound to ctx2 from here

		tree := niello.debug_tree(ctx1)
		testing.expect(t, len(tree) == 5, "snapshot holds every declared node")
		testing.expect(t, tree[0].parent == -1 && tree[0].unit == dbg_root, "root first, parent -1")
		testing.expect(t, tree[1].parent == 0 && tree[1].unit == dbg_wide, "children point at the root")
		testing.expect(t, tree[4].parent == 3 && tree[4].unit == dbg_tall, "the scroller's child nests under it")
		r, ok := niello.rect_in(ctx1, tree[2].instance)
		testing.expect(t, ok && tree[2].rect == r, "snapshot rect matches the committed rect")
		testing.expect(t, .Scroll_Y in tree[3].flags, "scroller flagged on its scroll axis")

		found1, found2 := false, false
		for c in niello.debug_contexts() {
			if c == ctx1 { found1 = true }
			if c == ctx2 { found2 = true }
		}
		testing.expect(t, found1 && found2, "debug_contexts lists both live contexts")
		testing.expect(t, len(niello.debug_tree(nil)) == 0, "nil context reads empty")
	}

	@(test)
	test_debug_overflow_report :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		ctx1 := niello.test_context()
		dbg_mint()
		dbg_frame(ctx1)

		recs := niello.debug_overflows(ctx1)
		// Root: content 300 wide in a 200 box -> X by 100.
		// Leaf: 28 glyphs of text in a 40px box -> X by ~184.
		// Scroller: 200 tall in 50 -> exempt (Scroll_Y).
		testing.expect(t, len(recs) == 2, "exactly the two non-exempt overflows report")
		testing.expect(t, recs[0].instance == dbg_root_inst && recs[0].axis == .X, "root reports on X")
		testing.expect_value(t, recs[0].px, f32(100))
		testing.expect(t, recs[0].name == "dbg_root", "report carries the mint debug name")
		testing.expect(t, recs[1].instance == dbg_leaf_inst && recs[1].px > 150, "the text leaf reports its spill")
	}

	@(test)
	test_debug_style_in :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		ctx1 := niello.test_context()
		ctx2 := niello.context_create()
		defer niello.context_destroy(ctx2)
		dbg_mint()
		dbg_frame(ctx1)
		dbg_frame(ctx2)

		s, ok := niello.debug_style_in(ctx1, dbg_leaf_inst)
		testing.expect(t, ok, "style read finds the instance in the peer")
		testing.expect(t, s.color == niello.Color{9, 8, 7, 255}, "and it is the unit's base style")
		_, ok2 := niello.debug_style_in(ctx1, niello.Instance(0xdead))
		testing.expect(t, !ok2, "unknown instance reads false")
		_, ok3 := niello.debug_style_in(nil, dbg_leaf_inst)
		testing.expect(t, !ok3, "nil context reads false")
	}

	@(test)
	test_debug_highlight_channel :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		ctx1 := niello.test_context()
		ctx2 := niello.context_create()
		defer niello.context_destroy(ctx2)
		dbg_mint()
		dbg_frame(ctx1)
		dbg_frame(ctx2)

		niello.debug_highlight(ctx1, dbg_leaf_inst)
		niello.set_current(ctx1)
		testing.expect_value(t, dbg_overlay_count(niello.DEBUG_HIGHLIGHT_COLOR), 1)
		niello.set_current(ctx2)
		testing.expect_value(t, dbg_overlay_count(niello.DEBUG_HIGHLIGHT_COLOR), 0)
		niello.debug_highlight(nil, 0)
		niello.set_current(ctx1)
		testing.expect_value(t, dbg_overlay_count(niello.DEBUG_HIGHLIGHT_COLOR), 0)
	}

	@(private)
	dbg_wleaf: niello.Unit

	@(test)
	test_debug_with_summary_and_loc :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		ctx1 := niello.test_context()
		dbg_mint()
		niello.mint(&dbg_wleaf, niello.NO_UNIT, {size = niello.Size{niello.fixed(30), niello.fixed(20)}})

		niello.frame_begin(ctx1, niello.Input{viewport = {400, 300}}, 0.016)
		if _, open := niello.begin(dbg_root); open {
			niello.show(dbg_wleaf, 0, {
				text = "override",
				disabled = true,
				variant = dbg_wide,
				focusable = true,
				label = "greeting",
			})
		}
		niello.frame_end()

		tree := niello.debug_tree(ctx1)
		found := false
		for dn in tree {
			if dn.unit == dbg_wleaf {
				found = true
				w := dn.with
				testing.expect(t, .Text in w.present && w.text == "override", "With.text captured with its arena value")
				testing.expect(t, .Disabled in w.present, "With.disabled captured")
				testing.expect(t, .Variant in w.present && w.variant == dbg_wide, "With.variant captured")
				testing.expect(t, .Focusable in w.present && w.focusable, "With.focusable captured")
				testing.expect(t, .Label in w.present && w.label == "greeting", "With.label captured")
			}
			if dn.unit == dbg_wide {
				testing.expect(t, dn.with.present == {}, "an unoverridden instance reports an empty With")
			}
		}
		testing.expect(t, found, "the overridden node is in the snapshot")

		file, line, ok := niello.debug_unit_loc(dbg_root)
		testing.expect(t, ok && line > 0, "mint location resolves")
		testing.expect(t, len(file) > 15 && file[len(file) - 15:] == "debug_test.odin", "and names the minting file")
		_, _, ok2 := niello.debug_unit_loc(niello.Unit(9999))
		testing.expect(t, !ok2, "unknown unit has no location")
	}

	@(test)
	test_debug_overflow_overlay :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		ctx1 := niello.test_context()
		dbg_mint()
		dbg_frame(ctx1)

		testing.expect_value(t, dbg_overlay_count(niello.DEBUG_OVERFLOW_COLOR), 0)
		niello.debug_show_overflows(ctx1, true)
		// Root (X spill) + leaf (text spill) tint; the scroller
		// is exempt.
		testing.expect_value(t, dbg_overlay_count(niello.DEBUG_OVERFLOW_COLOR), 2)
		niello.debug_show_overflows(ctx1, false)
		testing.expect_value(t, dbg_overlay_count(niello.DEBUG_OVERFLOW_COLOR), 0)
	}
}
