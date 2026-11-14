package niello

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

// ============ command vocabulary ============

// Draw_Cmd_Tag is the kind of a draw command.
Draw_Cmd_Tag :: enum u8 {
	Rect, // filled rect with optional inset border
	Text, // text run; the backend shapes it
	Push_Clip, // intersect the clip with bounds
	Pop_Clip, // restore the clip
	Push_Opacity, // group opacity (backend: saveLayer)
	Pop_Opacity, // restore
	Overlay, // an overlay over a node (state overlays, the focus ring, debug):
	         // fill + optional inset border
	Image, // image draw: bounds = dest rect; src_rect/image/interp payload
}

// Draw_Cmd is one drawing command of a frame (draw_list), for a host to
// render. Its layout is shared with the native backend: it does not change
// without a new native release.
Draw_Cmd :: struct {
	tag:    Draw_Cmd_Tag,
	bounds: Rect, // in DIP; for drawing commands, also the area they touch

	// Rect / Overlay payload. For Text commands, color carries the text color.
	color:        Color, // fill color
	radius:       u8, // corner radius (Rect/Overlay/Push_Clip/Image; raw style value — the backend clamps it)
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

	// Image payload.
	src_rect: [4]f32, // source rect in the image's pixel space (x, y, w, h)
	image:    u32,    // backend image id; 0 = none
	interp:   u8,     // Image_Interp discriminant (sampling quality)
}

// ============ emission ============

// draw_list returns the current frame's draw commands, for a host to
// render. Call it after frame_end; the slice is valid until the next
// frame_begin, and calling again rebuilds the list.
//
// Commands come in paint order: declaration order, later siblings on top.
// A node pushes its opacity and clip, draws its fill and border, image,
// text and overlay, then its children, then pops; content outside the
// window or a clip is skipped. Text commands borrow the text's bytes:
// With.text_no_copy text must stay unchanged while the list is in use.
//
// With rects (Frame_Result.repaint), the list holds only what touches
// them: for a backend that keeps the previous frame's pixels and repaints
// just those regions, clearing each and replaying the list clipped to it.
// Nil or empty rects give the whole frame.
draw_list :: proc(rects: []Rect = nil) -> []Draw_Cmd {
	clear(&g.draw_cmds)
	// Iterative pre-order walk over the flat node array, which is already in
	// depth-first declaration order: node i's subtree is the contiguous range
	// [i, subtree_end[i]].
	scopes := &g.emit_scopes
	clips := &g.emit_clips
	clear(scopes)
	clear(clips)
	// The accumulated clip starts at the viewport; a zero viewport
	// means none was ever latched, in which case nothing is culled at
	// emit. Emit is the only culler: layout sees the whole tree.
	root_clip := Rect{{0, 0}, g.viewport}
	if g.viewport == {0, 0} {
		root_clip = Rect{{-1e18, -1e18}, {2e18, 2e18}}
	}
	i := 0
	for i < len(g.nodes) {
		for len(scopes) > 0 && g.subtree_end[scopes[len(scopes) - 1]] < i {
			emit_node_close(pop(scopes))
			pop(clips)
		}
		if g.nodes[i].culled {
			i += 1
			continue
		}
		nd := &g.nodes[i]
		s := node_style(i)
		r := Rect{g.lay[i].pos, g.lay[i].size}
		cur := len(clips) > 0 ? clips[len(clips) - 1] : root_clip
		clips_node := s.overflow == .Clip || scrollable_axis(s, X_AXIS) || scrollable_axis(s, Y_AXIS)
		// Geometric culling at emit: a node whose
		// spill-expanded rect misses the accumulated clip paints
		// nothing itself — its text is never packed, its runs never
		// merged. A clipping node in that state takes its whole
		// subtree with it (everything inside is clipped to the same
		// empty intersection, and the scopes stay balanced by never
		// opening); a non-clipping node's children may still spill
		// into view, so only its own commands are skipped.
		paint := node_paint(i)
		if i == g.ring_idx {
			paint = rect_union(paint, g.ring_painted.rect)
		}
		// Outside the clip, or (repainting regions) outside every one of
		// them: the same two outcomes either way.
		if rect_outside(paint, cur) || (len(rects) > 0 && !touches_any(paint, rects)) {
			if clips_node {
				i = g.subtree_end[i] + 1
				continue
			}
			if emit_node_open(i, false) {
				append(scopes, i)
				append(clips, cur)
			}
			i += 1
			continue
		}
		// The ring's node opens a scope even with no clip or
		// opacity: its close is where the ring paints, above the
		// whole subtree.
		if emit_node_open(i, true) || i == g.ring_idx {
			append(scopes, i)
			append(clips, clips_node ? rect_intersect(cur, r) : cur)
		}
		i += 1
	}
	for len(scopes) > 0 {
		emit_node_close(pop(scopes))
		pop(clips)
	}
	return g.draw_cmds[:]
}

// touches_any reports whether paint overlaps one of the repaint rects,
// each grown by REPAINT_SLACK: a backend rounds a rect out to whole
// pixels, which at a fractional scale reaches up to a pixel past it, and
// commands there must replay too. Extra commands cost nothing visible:
// the backend clips them.
@(private)
touches_any :: proc(paint: Rect, rects: []Rect) -> bool {
	for r in rects {
		grown := Rect{r.pos - {REPAINT_SLACK, REPAINT_SLACK}, r.size + {2 * REPAINT_SLACK, 2 * REPAINT_SLACK}}
		if !rect_outside(paint, grown) {
			return true
		}
	}
	return false
}

@(private)
REPAINT_SLACK :: 2

// node_paint is the area node i can paint, for damage and culling alike:
// its rect, grown by its overflow (children spilling past it), and for a
// text node by an ink pad on every side. Glyphs reach past the line box
// (italic overhang, accents, tall marks), and a full repaint draws that
// ink, so a partial repaint must reach it too. The pad is a quarter of the
// largest font size in the text, plus one DIP.
@(private)
node_paint :: proc(i: int) -> Rect {
	r := Rect{g.lay[i].pos, g.lay[i].size + g.lay[i].overfl}
	nd := &g.nodes[i]
	if !nd.has_text {
		return r
	}
	size := node_style(i).font_size
	for sp in nd.spans {
		if v, ok := sp.font_size.?; ok {
			size = max(size, v)
		}
	}
	pad := f32(int(size * 0.25 + 0.999)) + 1
	return Rect{r.pos - {pad, pad}, r.size + {2 * pad, 2 * pad}}
}

// MAX_REPAINT_RECTS bounds Frame_Result.repaint: a backend replays the
// (culled) command list once per rect.
@(private)
MAX_REPAINT_RECTS :: 8

// repaint_rects turns this frame's damage into the regions a host
// repaints (Frame_Result.repaint): each rect clipped to the window and
// rounded out to whole DIP, then merged — rects that overlap or touch, or
// whose union wastes little area, become one — and capped: past
// MAX_REPAINT_RECTS (or with so many rects that merging would cost more
// than it saves), the bounding rect of them all.
@(private)
repaint_rects :: proc() -> []Rect {
	out := &g.repaint
	clear(out)
	view := Rect{{0, 0}, g.viewport}
	for d in g.damage {
		r := rect_intersect(d, view)
		if r.size.x <= 0 || r.size.y <= 0 {
			continue
		}
		x0, y0 := floor_f32(r.pos.x), floor_f32(r.pos.y)
		x1, y1 := ceil_f32(r.pos.x + r.size.x), ceil_f32(r.pos.y + r.size.y)
		append(out, Rect{{x0, y0}, {x1 - x0, y1 - y0}})
	}
	if len(out) > 64 {
		collapse_to_bounds(out)
		return out[:]
	}
	area :: proc(r: Rect) -> f32 {
		return r.size.x * r.size.y
	}
	for merged := true; merged; {
		merged = false
		outer: for a := 0; a < len(out); a += 1 {
			for b := a + 1; b < len(out); b += 1 {
				u := rect_union(out[a], out[b])
				touching := !(out[a].pos.x > out[b].pos.x + out[b].size.x || out[b].pos.x > out[a].pos.x + out[a].size.x ||
					out[a].pos.y > out[b].pos.y + out[b].size.y || out[b].pos.y > out[a].pos.y + out[a].size.y)
				if touching || area(u) <= area(out[a]) + area(out[b]) + 1024 {
					out[a] = u
					unordered_remove(out, b)
					merged = true
					break outer
				}
			}
		}
	}
	if len(out) > MAX_REPAINT_RECTS {
		collapse_to_bounds(out)
	}
	return out[:]

	collapse_to_bounds :: proc(out: ^[dynamic]Rect) {
		u := out[0]
		for r in out[1:] {
			u = rect_union(u, r)
		}
		clear(out)
		append(out, u)
	}
	floor_f32 :: proc(v: f32) -> f32 {
		t := f32(int(v))
		return t > v ? t - 1 : t
	}
	ceil_f32 :: proc(v: f32) -> f32 {
		t := f32(int(v))
		return t < v ? t + 1 : t
	}
}

// rect_outside reports whether two rects share no area (touching
// edges count as outside: a zero-area intersection paints nothing).
@(private)
rect_outside :: proc(a, b: Rect) -> bool {
	return a.pos.x + a.size.x <= b.pos.x || a.pos.y + a.size.y <= b.pos.y ||
		b.pos.x + b.size.x <= a.pos.x || b.pos.y + b.size.y <= a.pos.y
}

// emit_node_open emits a node's scope opens and its own commands. Returns
// true when it opened a scope (clip and/or opacity).
@(private)
emit_node_open :: proc(i: int, paint_leaves: bool) -> bool {
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
		append(&g.draw_cmds, Draw_Cmd{tag = .Push_Clip, bounds = r, radius = s.corner_radius})
		scoped = true
	}

	if paint_leaves && (s.color.a > 0 || s.border_width > 0) {
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

	if paint_leaves {
		// A leaf's image and text sit in its content box (the rect less
		// its padding); a container's image is its background and
		// fills the whole rect.
		content := r
		if !nd.is_container {
			content = Rect{
				r.pos + Vec2{f32(s.padding[0]), f32(s.padding[1])},
				{max(0, r.size.x - padding_sum(s, X_AXIS)), max(0, r.size.y - padding_sum(s, Y_AXIS))},
			}
		}
		emit_image(nd, s, content)

		if nd.has_text {
			emit_text(i, nd, s, content)
		}
	}

	if paint_leaves && (s.overlay_color.a > 0 || s.overlay_border_width > 0) {
		append(
			&g.draw_cmds,
			Draw_Cmd{
				tag = .Overlay,
				bounds = r,
				color = s.overlay_color,
				radius = s.corner_radius,
				border_width = s.overlay_border_width,
				border_color = s.overlay_border_color,
			},
		)
	}

	// Debug highlight / overflow tint (TODO #18): no-op unless
	// built with NIELLO_DEBUG.
	if paint_leaves {
		emit_debug_overlay(i, nd, s, r)
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
	// Justified lines (Style.justify) start a run per word: lead is the
	// word's natural gap before it, widened at emission by the line's
	// share of the leftover width.
	lead:       f32,
	gap_before: bool,
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
// r is the box the text lays out in: a leaf's content box.
emit_text :: proc(i: int, nd: ^Frame_Node, s: ^Style, r: Rect) {
	e := get_text(s, nd.spans, nd.spans_hash, nd.text_hash, nd.text)
	max_w := r.size.x
	// A leaf's align places its text: align[0] each line across the
	// box, align[1] the whole block down it. The block is the leaf's
	// laid-out content less its padding (its lines, wrapped or not).
	block_y := f32(0)
	if !nd.is_container {
		block_h := g.lay[i].content.y - padding_sum(s, Y_AXIS)
		block_y = align_offset(s.align[1], r.size.y - block_h)
	}

	// Shared scratch (state.odin): cleared here, reused for every
	// text node in this call and every later call — no allocation.
	breaks := &g.emit_breaks
	clear(breaks)
	runs := &g.emit_runs
	clear(runs)

	preserve := s.whitespace == .Preserve
	line_idx := 0
	for seg in e.segs {
		if len(seg.words) == 0 {
			line_idx += 1
			continue
		}
		if s.wrap == .Word {
			pack_line_breaks(seg.words, e.space_w, max_w, breaks, preserve)
		} else {
			clear(breaks)
			append(breaks, [2]int{0, len(seg.words)})
		}
		for br, bi in breaks^ {
			// Justify spreads every wrapped line of a paragraph to the
			// full width except its last one (and lines of one word).
			justify := s.justify && s.wrap == .Word && bi < len(breaks^) - 1 && br[1] - br[0] > 1
			lead_next := f32(-1)
			// Build merged runs: fragments in word order; inter-word gaps
			// are attributed to the preceding fragment's style (gaps are
			// invisible, so color is irrelevant; this keeps runs maximal
			// and the command count low). The gap's WIDTH is the mode's
			// (§3.18): the canonical space in Collapse, the word's
			// measured space_before in Preserve — the run's bytes carry
			// the actual spaces either way (its end extends to the next
			// word's start), so Preserve's width is the drawn truth.
			clear(runs)
			line_w := f32(0)
			for wi in br[0] ..< br[1] {
				w := &seg.words[wi]
				if wi > br[0] {
					gap := preserve ? w.space_before : e.space_w
					line_w += gap
					if justify {
						lead_next = gap // the word starts its own run
					} else {
						runs^[len(runs^) - 1].end = w.start
						runs^[len(runs^) - 1].width += gap
					}
				}
				for f in w.frags {
					line_w += f.width
					// The fragment's effective color: its span override,
					// or the node's CURRENT base font_color. The word
					// cache deliberately does not store the base color
					// (it is not in the cache key), so a Font_Color write
					// recolors already-cached text on the next frame.
					f_color := f.span_color.? or_else s.font_color
					if lead_next < 0 && len(runs) > 0 && same_run_style(runs^[len(runs^) - 1], f, f_color) && runs^[len(runs^) - 1].end == f.start {
						runs^[len(runs^) - 1].end = f.end
						runs^[len(runs^) - 1].width += f.width
					} else {
						append(runs, Text_Run{
							start = f.start, end = f.end, width = f.width,
							font = f.font, font_size = f.font_size,
							font_weight = f.font_weight, font_slant = f.font_slant,
							font_color = f_color,
							lead = max(lead_next, 0), gap_before = lead_next >= 0,
						})
						lead_next = -1
					}
				}
				if preserve && s.wrap == .None && wi == br[0] &&
				   w.space_before > 0 && len(runs) > 0 {
					// Leading run (§3.18): extend the first run's
					// bytes back over the spaces and price them at
					// their measured width, so the words sit at
					// their true positions.
					runs^[0].start = w.gap_start
					runs^[0].width += w.space_before
					line_w += w.space_before
				}
			}

			trims := s.wrap == .None && line_w > max_w
			align_w := line_w
			if preserve && br[1] == len(seg.words) {
				// The segment's trailing run counts toward alignment
				// (a centered Preserve line centers its spaces too),
				// but never toward trims — invisible overflow must
				// not ellipsize visible glyphs.
				align_w += seg.trailing
			}
			x0 := align_offset(s.align[0], max_w - align_w)
			per_gap := f32(0)
			if justify {
				x0 = 0
				per_gap = max(0, max_w - line_w) / f32(br[1] - br[0] - 1)
			}
			if trims {
				x0 = 0
			}
			y := r.pos.y + block_y + f32(line_idx) * e.line_h
			x := x0
			for rn in runs^ {
				if rn.gap_before {
					x += rn.lead + per_gap
				}
				if trims {
					if x >= max_w {
						break // past the edge; drop the rest
					}
					if x + rn.width > max_w {
						// Straddling run: the backend trims + draws the
						// ellipsis, so it touches max_width at most.
						append(&g.draw_cmds, Draw_Cmd{
							tag = .Text,
							bounds = Rect{{r.pos.x + x, y}, {max_w - x, e.line_h}},
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
// The focus ring paints between them: outside the node's own clip (it
// sits beyond the rect) but inside its opacity (it fades with it).
@(private)
emit_node_close :: proc(i: int) {
	s := node_style(i)
	r := Rect{g.lay[i].pos, g.lay[i].size}
	if s.overflow == .Clip || scrollable_axis(s, X_AXIS) || scrollable_axis(s, Y_AXIS) {
		append(&g.draw_cmds, Draw_Cmd{tag = .Pop_Clip, bounds = r})
	}
	if i == g.ring_idx {
		rp := g.ring_painted
		append(&g.draw_cmds, Draw_Cmd{
			tag = .Overlay, bounds = rp.rect, radius = rp.radius,
			border_width = rp.width, border_color = rp.color,
		})
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
	case .Rect, .Text, .Overlay, .Image:
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

// emit_image paints the node's image into its rect, behind its
// text and children: a leaf is an image control, a container gets
// a background image. The painted image is the effective style's,
// with With.image winning (declare-resolved on the node); fit
// modes change the paint here only — measure used the declared
// image (§3.25, the text-resolution family rule).
@(private)
emit_image :: proc(nd: ^Frame_Node, s: ^Style, r: Rect) {
	img := s.image
	if nd.image_override {
		img = nd.image
	}
	if img == NO_IMAGE || r.size.x <= 0 || r.size.y <= 0 {
		return
	}
	backend, crop, ok := image_paint_info(img)
	if !ok {
		return
	}
	src_full := Rect{{crop[0], crop[1]}, {crop[2], crop[3]}}
	// A leaf's align places its image in the content box; a
	// container's image is its background, centered over the rect.
	a := nd.is_container ? CENTER : s.align
	dest, src := image_fit_rects(s.image_fit, src_full, r, a)
	if dest.size.x <= 0 || dest.size.y <= 0 {
		return
	}
	append(&g.draw_cmds, Draw_Cmd{
		tag = .Image,
		bounds = dest,
		radius = s.corner_radius,
		src_rect = {src.pos.x, src.pos.y, src.size.x, src.size.y},
		image = backend,
		interp = u8(s.image_interp),
	})
}

// image_fit_rects is Avalonia's Image.Render math: scale the
// source per the fit mode, center the result in the viewport,
// intersect, and derive the matching source rect (the
// Uniform_Fill crop lives here, not in the backend).
@(private)
image_fit_rects :: proc(fit: Image_Fit, src_full: Rect, view: Rect, align: [2]Align_Kind = CENTER) -> (dest: Rect, src: Rect) {
	sw, sh := src_full.size.x, src_full.size.y
	if sw <= 0 || sh <= 0 {
		return {}, {}
	}
	scale: Vec2
	switch fit {
	case .Fill:
		scale = {view.size.x / sw, view.size.y / sh}
	case .Uniform:
		k := min(view.size.x / sw, view.size.y / sh)
		scale = {k, k}
	case .Uniform_Fill:
		k := max(view.size.x / sw, view.size.y / sh)
		scale = {k, k}
	case .None:
		scale = {1, 1}
	}
	scaled := Vec2{sw * scale.x, sh * scale.y}
	// align places the scaled image in the viewport, per axis: Start
	// flush with the top-left, End with the bottom-right. When the image
	// is larger (Uniform_Fill, None) that picks which part is kept.
	frac :: proc(a: Align_Kind) -> f32 {
		switch a {
		case .Start:  return 0
		case .Center: return 0.5
		case .End:    return 1
		}
		return 0.5
	}
	d := Rect{view.pos + (view.size - scaled) * Vec2{frac(align[0]), frac(align[1])}, scaled}
	// Intersect with the viewport.
	x0 := max(d.pos.x, view.pos.x)
	y0 := max(d.pos.y, view.pos.y)
	x1 := min(d.pos.x + d.size.x, view.pos.x + view.size.x)
	y1 := min(d.pos.y + d.size.y, view.pos.y + view.size.y)
	dest = Rect{{x0, y0}, {max(0, x1 - x0), max(0, y1 - y0)}}
	// The source sub-rect that lands in dest: where dest starts within
	// the placed image, back in source pixels.
	sub := Vec2{dest.size.x / scale.x, dest.size.y / scale.y}
	src = Rect{src_full.pos + (dest.pos - d.pos) / scale, sub}
	return dest, src
}

// ============ focus ring ============

// focus_ring_resolve finds the node that shows the ring this frame and
// the ring it paints (see set_focus_ring). Run at the end of frame_end,
// after every focus move (modal grab/restore and survival run after
// layout): it damages exactly the change from the last painted ring
// and leaves g.ring_idx / g.ring_painted for draw_list.
@(private)
focus_ring_resolve :: proc() {
	g.ring_idx = -1
	now := Ring_Paint{}
	cfg := store.focus_ring.? or_else DEFAULT_FOCUS_RING
	if g.focus_id != 0 && cfg.width > 0 {
		for idx in 0 ..< len(g.nodes) {
			nd := &g.nodes[idx]
			if nd.identity != g.focus_id {
				continue
			}
			if nd.culled || nd.ring_mode == .Never || !(g.focus_visible || nd.ring_mode == .Always) {
				break
			}
			r := Rect{g.lay[idx].pos, g.lay[idx].size}
			e := f32(cfg.offset) + f32(cfg.width)
			outer := Rect{r.pos - {e, e}, r.size + {2 * e, 2 * e}}
			if outer.size.x <= 0 || outer.size.y <= 0 {
				break
			}
			// Concentric with the instance's own corners: its radius
			// as the backend clamps it, grown by the ring's distance.
			// A square instance keeps a square ring.
			cr := min(f32(node_style(idx).corner_radius), min(r.size.x, r.size.y) * 0.5)
			rad := cr > 0 ? clamp(cr + e, 0, 255) : 0
			now = Ring_Paint{on = true, rect = outer, color = cfg.color, width = cfg.width, radius = u8(rad)}
			g.ring_idx = idx
			break
		}
	}
	if now != g.ring_painted {
		if g.ring_painted.on {
			append(&g.damage, g.ring_painted.rect)
		}
		if now.on {
			append(&g.damage, now.rect)
		}
		g.ring_painted = now
	}
}
