// Headless tests for the draw-command emitter (render.odin). No backend needed:
// these assert on the command stream draw_list() produces from known layouts.
package tests

import niello ".."
import "core:testing"

@(test)
test_draw_list_rect_and_text :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	niello.mint(
		&root,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(400), niello.fixed(300)}, color = [4]u8{32, 32, 32, 255}},
	)
	box: niello.Unit
	niello.mint(
		&box,
		niello.NO_UNIT,
		{
			size = niello.Size{niello.fixed(100), niello.fixed(50)},
			color = [4]u8{200, 0, 0, 255},
			border_width = 2,
			border_color = [4]u8{0, 0, 0, 255},
		},
	)
	label: niello.Unit
	niello.mint(&label, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	if _, ok := niello.begin(root); ok {
		niello.show(box)
		niello.show(label, 0, niello.With{text = "Hi"})
	}
	niello.frame_end()

	cmds := niello.draw_list()
	testing.expect(t, len(cmds) == 3, "root rect + box rect + label text")

	testing.expect(t, cmds[0].tag == .Rect, "first command paints the root")
	testing.expect(t, cmds[0].bounds.size[0] == 400, "root rect width")
	testing.expect(t, cmds[0].bounds.size[1] == 300, "root rect height")
	testing.expect(t, cmds[0].color == [4]u8{32, 32, 32, 255}, "root fill color")
	testing.expect(t, cmds[0].border_width == 0, "root has no border")

	testing.expect(t, cmds[1].tag == .Rect, "second command paints the box")
	testing.expect(t, cmds[1].bounds.size[0] == 100, "box width")
	testing.expect(t, cmds[1].bounds.size[1] == 50, "box height")
	testing.expect(t, cmds[1].border_width == 2, "box border width")
	testing.expect(t, cmds[1].border_color == [4]u8{0, 0, 0, 255}, "box border color")

	testing.expect(t, cmds[2].tag == .Text, "third command draws the text")
	testing.expect(t, cmds[2].bounds.pos[0] == 100, "text sits right of the box")
	text := string(cmds[2].text_ptr[:int(cmds[2].text_len)])
	testing.expect(t, text == "Hi", "text bytes are borrowed through")
	testing.expect(t, !cmds[2].truncated, "fitting text is not flagged truncated")

	// Idempotent: a second call re-emits the same stream.
	again := niello.draw_list()
	testing.expect(t, len(again) == len(cmds), "draw_list re-emits deterministically")
}

@(test)
test_draw_list_truncation :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	lbl: niello.Unit
	// "Hello world" is 11 chars x 8px = 88px intrinsic; the 40px box truncates it.
	niello.mint(&lbl, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fit()}})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	if _, ok := niello.begin(root); ok {
		niello.show(lbl, 0, niello.With{text = "Hello world"})
	}
	niello.frame_end()

	found := false
	for c in niello.draw_list() {
		if c.tag == .Text {
			found = true
			testing.expect(t, c.truncated, "overflowing no-wrap text is flagged truncated")
			testing.expect(t, c.max_width == 40, "max_width is the resolved width")
		}
	}
	testing.expect(t, found, "expected a Text command")
}

@(test)
test_draw_list_clip_and_opacity :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	clipbox: niello.Unit
	niello.mint(
		&clipbox,
		niello.NO_UNIT,
		{
			size = niello.Size{niello.fixed(200), niello.fixed(200)},
			color = [4]u8{0, 0, 255, 255},
			overflow = .Clip,
		},
	)
	inner: niello.Unit
	niello.mint(
		&inner,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(50), niello.fixed(50)}, color = [4]u8{255, 0, 0, 255}},
	)
	fade: niello.Unit
	niello.mint(
		&fade,
		niello.NO_UNIT,
		{
			size = niello.Size{niello.fixed(60), niello.fixed(60)},
			color = [4]u8{0, 255, 0, 255},
			opacity = 128,
		},
	)

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	if _, ok := niello.begin(root); ok {
		if _, ok2 := niello.begin(clipbox); ok2 {
			niello.show(inner)
		}
		niello.show(fade)
	}
	niello.frame_end()

	cmds := niello.draw_list()

	push_clip, pop_clip, push_op, pop_op := -1, -1, -1, -1
	inner_rect := -1
	for c, idx in cmds {
		#partial switch c.tag {
		case .Push_Clip:
			push_clip = idx
		case .Pop_Clip:
			pop_clip = idx
		case .Push_Opacity:
			push_op = idx
			testing.expect(t, c.opacity == 128, "opacity payload carries the alpha")
		case .Pop_Opacity:
			pop_op = idx
		case .Rect:
			// (named var: a `[N]T{...}` literal directly after `==` in an
			// if-condition confuses the parser)
			want_red := [4]u8{255, 0, 0, 255}
			if c.color == want_red {
				inner_rect = idx
			}
		}
	}
	testing.expect(t, push_clip >= 0 && pop_clip > push_clip, "clip scope opens and closes")
	testing.expect(
		t,
		push_clip < inner_rect && inner_rect < pop_clip,
		"clipped child paints inside the clip scope",
	)
	testing.expect(t, push_op >= 0 && pop_op > push_op, "opacity scope opens and closes")

	// The whole stream stays stack-balanced.
	clip_depth, op_depth := 0, 0
	for c in cmds {
		#partial switch c.tag {
		case .Push_Clip:
			clip_depth += 1
		case .Pop_Clip:
			clip_depth -= 1
		case .Push_Opacity:
			op_depth += 1
		case .Pop_Opacity:
			op_depth -= 1
		}
		testing.expect(t, clip_depth >= 0 && op_depth >= 0, "scopes never pop unopened")
	}
	testing.expect(t, clip_depth == 0 && op_depth == 0, "all scopes closed by stream end")
}

@(test)
test_draw_list_overlay :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	dbg: niello.Unit
	niello.mint(
		&dbg,
		niello.NO_UNIT,
		{
			size = niello.Size{niello.fixed(100), niello.fixed(100)},
			overlay_color = [4]u8{255, 255, 0, 128},
			overlay_border_color = [4]u8{255, 0, 0, 255},
			overlay_border_width = 3,
		},
	)

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	if _, ok := niello.begin(root); ok {
		niello.show(dbg)
	}
	niello.frame_end()

	overlay_seen, rect_seen := false, false
	for c in niello.draw_list() {
		#partial switch c.tag {
		case .Overlay:
			overlay_seen = true
			testing.expect(t, c.color == [4]u8{255, 255, 0, 128}, "overlay fill color")
			testing.expect(t, c.border_width == 3, "overlay border width")
			testing.expect(t, c.border_color == [4]u8{255, 0, 0, 255}, "overlay border color")
			testing.expect(t, c.bounds.size[0] == 100, "overlay covers the instance rect")
		case .Rect:
			if c.bounds.size[0] == 100 {
				rect_seen = true
			}
		}
	}
	testing.expect(t, overlay_seen, "overlay fields emit an Overlay command")
	testing.expect(t, !rect_seen, "transparent fill with no border emits no Rect")
}

@(test)
test_draw_cmd_visible :: proc(t: ^testing.T) {
	// Pure predicate test: no frames needed.
	r := niello.Draw_Cmd{tag = .Rect, bounds = niello.Rect{pos = {10, 10}, size = {20, 20}}}
	far := []niello.Rect{niello.Rect{pos = {0, 0}, size = {5, 5}}}
	near := []niello.Rect{niello.Rect{pos = {15, 15}, size = {50, 50}}}
	empty: []niello.Rect = nil

	testing.expect(t, !niello.draw_cmd_visible(r, far), "non-overlapping damage culls the command")
	testing.expect(t, niello.draw_cmd_visible(r, near), "overlapping damage keeps the command")
	testing.expect(t, !niello.draw_cmd_visible(r, empty), "empty damage draws nothing")

	push := niello.Draw_Cmd{tag = .Push_Clip, bounds = niello.Rect{pos = {10, 10}, size = {20, 20}}}
	testing.expect(t, niello.draw_cmd_visible(push, far), "stack commands are never culled")
	testing.expect(t, niello.draw_cmd_visible(push, empty), "stack commands replay even with empty damage")
}

@(test)
test_draw_list_truncation_in_column :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	// Top_To_Bottom root: the label's width is the CROSS axis here (in a row
	// it would be the main axis, where the waterfill already shrinks it).
	niello.mint(&root, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size   = niello.Size{niello.fixed(60), niello.fixed(300)},
	})
	lbl: niello.Unit
	niello.mint(&lbl, niello.NO_UNIT, {}) // FIT text, wrap .None, ellipsis on

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	if _, ok := niello.begin(root); ok {
		niello.show(lbl, 0, niello.With{text = "Hello world"}) // 88px intrinsic
	}
	niello.frame_end()

	found := false
	for c in niello.draw_list() {
		if c.tag == .Text {
			found = true
			testing.expect(t, c.truncated, "cross-axis FIT text truncates to the column width")
			testing.expect(t, c.max_width == 60, "max_width is the column's inner width")
		}
	}
	testing.expect(t, found, "expected a Text command")
}

@(test)
test_draw_list_truncation_nested_fit :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size   = niello.Size{niello.fixed(60), niello.fixed(300)},
	})
	card: niello.Unit
	// FIT-width column inside the fixed column: the offer bound must
	// propagate — card clamps to 60, then the label truncates inside it.
	niello.mint(&card, niello.NO_UNIT, {layout = .Top_To_Bottom})
	lbl: niello.Unit
	niello.mint(&lbl, niello.NO_UNIT, {})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	if _, ok := niello.begin(root); ok {
		if _, ok := niello.begin(card); ok {
			niello.show(lbl, 0, niello.With{text = "Hello world"})
		}
	}
	niello.frame_end()

	found := false
	for c in niello.draw_list() {
		if c.tag == .Text {
			found = true
			testing.expect(t, c.truncated, "label inside a FIT card truncates when the card is clamped")
			testing.expect(t, c.max_width == 60, "max_width is the clamped card's inner width")
		}
	}
	testing.expect(t, found, "expected a Text command")
}

@(test)
test_cross_fit_not_clamped_when_scrollable :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	root: niello.Unit
	// Horizontally scrollable column: on the scroll axis a FIT child's
	// natural size IS the scroll extent, so no offer bound applies.
	niello.mint(&root, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size   = niello.Size{niello.fixed(60), niello.fixed(300)},
		scroll = .Horizontal,
	})
	lbl: niello.Unit
	niello.mint(&lbl, niello.NO_UNIT, {})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	if _, ok := niello.begin(root); ok {
		niello.show(lbl, 0, niello.With{text = "Hello world"})
	}
	niello.frame_end()

	found := false
	for c in niello.draw_list() {
		if c.tag == .Text {
			found = true
			testing.expect(t, !c.truncated, "scrollable axis: FIT text keeps its natural width")
		}
	}
	testing.expect(t, found, "expected a Text command")
}

// ---- damage on content change (§5: "changed → new rect" — changed means
// the committed content, not just the rect). Both tests pin behavior the
// old rect-only diff missed: they fail if damage ever goes back to
// comparing positions alone.

dmg_root, dmg_box, dmg_lbl: niello.Unit
dmg_text: string

declare_dmg_tree :: proc() {
	if _, ok := niello.begin(dmg_root); ok {
		niello.show(dmg_box)
		niello.show(dmg_lbl, 0, niello.With{text = dmg_text})
	}
}

dmg_frame :: proc() -> niello.Frame_Result {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
	declare_dmg_tree()
	return niello.frame_end()
}

@(test)
test_damage_on_style_change :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(
		&dmg_root,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(400), niello.fixed(300)}},
	)
	niello.mint(
		&dmg_box,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(100), niello.fixed(50)}, color = [4]u8{200, 0, 0, 255}},
	)
	dmg_text = ""

	dmg_frame()
	res := dmg_frame()
	testing.expect(t, !res.changed, "identical frame stays clean")

	// A set() restyle moves nothing — and must still damage the frame.
	niello.set(dmg_box, .Color, niello.Color{0, 0, 200, 255})
	res = dmg_frame()
	testing.expect(t, res.changed, "style change damages the frame")
	testing.expect(t, len(res.damage) > 0, "style change produces damage rects")

	res = dmg_frame()
	testing.expect(t, !res.changed, "frame is clean again after the restyle")
}

@(test)
test_damage_on_text_change_same_size :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(
		&dmg_root,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(400), niello.fixed(300)}},
	)
	niello.mint(
		&dmg_box,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(100), niello.fixed(50)}},
	)
	niello.mint(&dmg_lbl, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})

	dmg_text = "AAAA" // 4 chars x 8px under mock metrics
	dmg_frame()
	res := dmg_frame()
	testing.expect(t, !res.changed, "identical text stays clean")

	dmg_text = "BBBB" // same width, same rect — only the bytes changed
	res = dmg_frame()
	testing.expect(t, res.changed, "same-size text change damages the frame")

	res = dmg_frame()
	testing.expect(t, !res.changed, "frame is clean again after the text change")
}
