// Render command stream (Phase 1: Odin-only).
//
// draw_list() walks the committed frame and emits a flat, FFI-clean command
// buffer describing everything the backend must paint: rects, text, clip and
// opacity scopes, and debug/focus overlays. A C++ shim will later replay these
// onto SkCanvas; nothing here knows about Skia.
//
// FFI contract: Draw_Cmd is a fixed-size struct with C-compatible layout
// (tag + bounds + payload, fields in declaration order). No Odin union
// crosses the boundary. Text is borrowed (pointer + length); the buffer
// returned by draw_list() is valid until the next frame_begin.
package niello

// ============ command vocabulary ============

Draw_Cmd_Tag :: enum u8 {
	Rect, // filled rect with optional inset border
	Text, // text run; the backend shapes it
	Push_Clip, // intersect the clip with bounds
	Pop_Clip, // restore the clip
	Push_Opacity, // group opacity (backend: saveLayer)
	Pop_Opacity, // restore
	Overlay, // debug/focus overlay: fill + optional inset border
}

Draw_Cmd :: struct {
	tag:    Draw_Cmd_Tag,
	bounds: Rect, // DIP. For leaf commands, the damage-culling bounds.

	// Rect / Overlay payload. For Text commands, color carries the text color.
	color:        Color, // fill color
	radius:       u8, // corner radius (Rect only)
	border_width: u16, // inset border width; 0 = no border
	border_color: Color,

	// Text payload. Borrowed bytes, valid until the next frame_begin.
	text_ptr:  [^]u8,
	text_len:  i64,
	font:      Font_Handle,
	max_width: f32, // available width; the backend trims with an ellipsis when truncated
	truncated: bool,

	// Push_Opacity payload.
	opacity: u8,
}

// ============ emission ============

// draw_list emits the frame's draw commands into a reused buffer and returns
// them. Call it after frame_end; the result is valid until the next
// frame_begin. It is idempotent: each call re-emits from the committed frame.
//
// Paint order is declaration order (later siblings paint on top). Per node:
// optional opacity scope, optional clip scope, rect fill + border, text,
// overlay. Scopes wrap the node's whole subtree: opens emit on entry, closes
// emit once the walk leaves the subtree (detected via subtree_end, which the
// layout builds). A clipped container's children therefore paint inside its
// clip.
//
// Text note: text_ptr borrows the node's bytes. For With.text those live in
// the frame arena (freed at frame_begin); for With.text_no_copy they are the
// app's bytes, which must stay alive until the next frame_begin when the
// command buffer is in use.
draw_list :: proc() -> []Draw_Cmd {
	clear(&g.draw_cmds)
	// Iterative pre-order walk over the flat node array, which is already in
	// depth-first declaration order: node i's subtree is the contiguous range
	// [i, subtree_end[i]].
	scopes := make([dynamic]int)
	defer delete(scopes)
	for i in 0 ..< len(g.nodes) {
		for len(scopes) > 0 && g.subtree_end[scopes[len(scopes)-1]] < i {
			emit_node_close(pop(&scopes))
		}
		if g.nodes[i].culled {
			continue
		}
		if emit_node_open(i) {
			append(&scopes, i)
		}
	}
	for len(scopes) > 0 {
		emit_node_close(pop(&scopes))
	}
	return g.draw_cmds[:]
}

// emit_node_open emits a node's scope opens and its own commands. Returns
// true when it opened a scope (clip and/or opacity).
@(private)
emit_node_open :: proc(i: int) -> bool {
	nd := &g.nodes[i]
	s := style_of(nd.unit)
	r := Rect{g.lay[i].pos, g.lay[i].size}

	scoped := false
	if s.opacity < 255 {
		append(&g.draw_cmds, Draw_Cmd{tag = .Push_Opacity, bounds = r, opacity = s.opacity})
		scoped = true
	}
	clips := s.overflow == .Clip || scrollable_axis(s, X_AXIS) || scrollable_axis(s, Y_AXIS)
	if clips {
		append(&g.draw_cmds, Draw_Cmd{tag = .Push_Clip, bounds = r})
		scoped = true
	}

	if s.color.a > 0 || s.border_width > 0 {
		append(
			&g.draw_cmds,
			Draw_Cmd{
				tag = .Rect,
				bounds = r,
				color = s.color,
				radius = s.corner_radius,
				border_width = s.border_width,
				border_color = s.border_color,
			},
		)
	}

	if nd.has_text {
		// Paint-time trim signal (§3.12): the backend draws the ellipsis when
		// the intrinsic width exceeds the resolved width. Text is drawn with
		// its origin at the rect's top-left; the backend applies the baseline
		// from its font metrics.
		truncated := s.wrap == .None && g.lay[i].content.x > g.lay[i].size.x
		append(
			&g.draw_cmds,
			Draw_Cmd{
				tag = .Text,
				bounds = r,
				color = s.text_color,
				text_ptr = raw_data(nd.text),
				text_len = i64(len(nd.text)),
				font = s.font,
				max_width = g.lay[i].size.x,
				truncated = truncated,
			},
		)
	}

	if s.overlay_color.a > 0 || s.overlay_border_width > 0 {
		append(
			&g.draw_cmds,
			Draw_Cmd{
				tag = .Overlay,
				bounds = r,
				color = s.overlay_color,
				border_width = s.overlay_border_width,
				border_color = s.overlay_border_color,
			},
		)
	}

	return scoped
}

// emit_node_close emits a node's scope closes, in reverse of the opens.
@(private)
emit_node_close :: proc(i: int) {
	s := style_of(g.nodes[i].unit)
	r := Rect{g.lay[i].pos, g.lay[i].size}
	if s.overflow == .Clip || scrollable_axis(s, X_AXIS) || scrollable_axis(s, Y_AXIS) {
		append(&g.draw_cmds, Draw_Cmd{tag = .Pop_Clip, bounds = r})
	}
	if s.opacity < 255 {
		append(&g.draw_cmds, Draw_Cmd{tag = .Pop_Opacity, bounds = r})
	}
}

// ============ damage-driven replay ============

// draw_cmd_visible reports whether cmd must be replayed for the given damage
// set (the damage rects from frame_end). Stack commands are never culled:
// dropping a Push_Clip while keeping its clipped content would corrupt the
// clip stack, so pushes/pops always replay and leaf commands cull
// individually against their own bounds.
draw_cmd_visible :: proc(cmd: Draw_Cmd, damage: []Rect) -> bool {
	switch cmd.tag {
	case .Push_Clip, .Pop_Clip, .Push_Opacity, .Pop_Opacity:
		return true
	case .Rect, .Text, .Overlay:
		for d in damage {
			if rects_overlap(cmd.bounds, d) {
				return true
			}
		}
		return false
	}
	return false
}

@(private)
rects_overlap :: proc(a, b: Rect) -> bool {
	return(
		a.pos.x < b.pos.x + b.size.x &&
		a.pos.x + a.size.x > b.pos.x &&
		a.pos.y < b.pos.y + b.size.y &&
		a.pos.y + a.size.y > b.pos.y \
	)
}
