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
	text_ptr:    [^]u8,
	text_len:    i64,
	font:        Font_Handle, // family; 0 = platform default
	font_size:   f32, // px in DIP
	font_weight: u16, // CSS 100-900, matches Font_Weight discriminants
	font_slant:  u8, // 0=upright, 1=italic, 2=oblique; matches Font_Slant order
	max_width:   f32, // available width; the backend trims with an ellipsis when truncated
	truncated:   bool,

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
	s := node_style(i)
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
		emit_text(i, nd, s, r)
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

// A merged run of same-style text within one laid-out line.
@(private)
Text_Run :: struct {
	start, end: int, // byte offsets into the node's text
	width:      f32,
	font:        Font_Handle,
	font_size:   f32,
	font_weight: Font_Weight,
	font_slant:  Font_Slant,
	font_color:  Color,
}

@(private)
same_run_style :: proc(r: Text_Run, f: Text_Frag, f_color: Color) -> bool {
	return r.font == f.font && r.font_size == f.font_size && r.font_weight == f.font_weight && r.font_slant == f.font_slant && r.font_color == f_color
}

// emit_text lays out the node's text into positioned Text commands: one per
// line per style-run. Consecutive fragments with identical style merge into a
// single command, so plain text emits one command per line. Each line is
// positioned by the node's horizontal align; the backend applies the
// baseline from each run's font metrics.
//
// Paint-time trim (§3.12): when wrap==.None and the line exceeds the resolved
// width, runs are walked from the left and the straddling run is emitted with
// truncated=true; the backend draws the ellipsis. The trim is computed as if
// Start-aligned (ellipsis + Center/End is a rare combo; fitting text still
// aligns normally).
@(private)
emit_text :: proc(i: int, nd: ^Frame_Node, s: ^Style, r: Rect) {
	e := get_text(s, nd.spans, nd.spans_hash, nd.text_hash, nd.text)
	max_w := g.lay[i].size.x

	breaks: [dynamic][2]int
	defer delete(breaks)
	runs: [dynamic]Text_Run
	defer delete(runs)

	line_idx := 0
	for seg in e.segs {
		if len(seg) == 0 {
			line_idx += 1
			continue
		}
		if s.wrap == .Word {
			pack_line_breaks(seg, e.space_w, max_w, &breaks)
		} else {
			clear(&breaks)
			append(&breaks, [2]int{0, len(seg)})
		}
		for br in breaks {
			// Build merged runs: fragments in word order; inter-word gaps
			// are attributed to the preceding fragment's style (gaps are
			// invisible, so color is irrelevant; this keeps runs maximal
			// and the command count low).
			clear(&runs)
			line_w := f32(0)
			for wi in br[0] ..< br[1] {
				w := &seg[wi]
				if wi > br[0] {
					line_w += e.space_w
					runs[len(runs)-1].end = w.start
					runs[len(runs)-1].width += e.space_w
				}
				for f in w.frags {
					line_w += f.width
					// The fragment's effective color: its span override,
					// or the node's CURRENT base font_color. The word
					// cache deliberately does not store the base color
					// (it is not in the cache key), so a Font_Color write
					// recolors already-cached text on the next frame.
					f_color := f.span_color.? or_else s.font_color
					if len(runs) > 0 && same_run_style(runs[len(runs)-1], f, f_color) && runs[len(runs)-1].end == f.start {
						runs[len(runs)-1].end = f.end
						runs[len(runs)-1].width += f.width
					} else {
						append(&runs, Text_Run{
							start = f.start, end = f.end, width = f.width,
							font = f.font, font_size = f.font_size,
							font_weight = f.font_weight, font_slant = f.font_slant,
							font_color = f_color,
						})
					}
				}
			}

			trims := s.wrap == .None && line_w > max_w
			x0 := align_offset(s.align[0], max_w - line_w)
			if trims {
				x0 = 0
			}
			y := r.pos.y + f32(line_idx) * e.line_h
			x := x0
			for rn in runs {
				if trims {
					if x >= max_w {
						break // past the edge; drop the rest
					}
					if x + rn.width > max_w {
						// Straddling run: the backend trims + draws the ellipsis.
						append(&g.draw_cmds, Draw_Cmd{
							tag = .Text,
							bounds = Rect{{r.pos.x + x, y}, {rn.width, e.line_h}},
							color = rn.font_color,
							text_ptr = raw_data(nd.text[rn.start:rn.end]),
							text_len = i64(rn.end - rn.start),
							font = rn.font, font_size = rn.font_size,
							font_weight = u16(rn.font_weight), font_slant = u8(rn.font_slant),
							max_width = max_w - x, truncated = true,
						})
						break
					}
				}
				append(&g.draw_cmds, Draw_Cmd{
					tag = .Text,
					bounds = Rect{{r.pos.x + x, y}, {rn.width, e.line_h}},
					color = rn.font_color,
					text_ptr = raw_data(nd.text[rn.start:rn.end]),
					text_len = i64(rn.end - rn.start),
					font = rn.font, font_size = rn.font_size,
					font_weight = u16(rn.font_weight), font_slant = u8(rn.font_slant),
					max_width = max_w, truncated = false,
				})
				x += rn.width
			}
			line_idx += 1
		}
	}
}

// emit_node_close emits a node's scope closes, in reverse of the opens.
@(private)
emit_node_close :: proc(i: int) {
	s := node_style(i)
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
