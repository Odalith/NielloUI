// input.odin — pointer dispatch, interaction state, and state-overlay
// resolution.
//
// Model (§3.8): events are polled, not delivered. frame_begin hit-tests the
// input against the PREVIOUS frame's committed tree — one frame of latency,
// invisible at refresh rate — and records interaction state keyed by
// identity. User code asks clicked/hovered/pressed during declare; handlers
// run inline with full access to their locals, which is what makes the
// no-callback design work in Odin.
//
// Semantics ruled 2026-10-20:
//   - Press capture: a button press captures the picked instance until the
//     matching release, wherever the cursor goes (pressed stays true;
//     hover keeps following the cursor).
//   - Click = press + release over the same instance or one of its
//     descendants, left button only in v1. Queries bubble: an instance
//     counts as hovered/pressed/clicked when it is the target or an
//     ancestor of the target, so a button fires when its label is hit.
//   - Disabled absorbs: the first disabled instance on the pick's ancestor
//     chain truncates it. That instance reports hovered (it can paint its
//     disabled state) but press/click never fire through it.
//   - Cursor departure ends all interaction at once. Window-focus loss
//     drops press capture only — no click completes across it — while
//     hover follows the cursor regardless of focus, and the click that
//     focuses the window dispatches like any other (click-to-activate).
//   - Overlay precedence, weakest first, merged field-wise from each
//     overlay unit's explicit fields: base < variant < focus < hover <
//     press < disabled.
package niello

// ---------------------------------------------------------------------------
// Small helpers

@(private)
point_in_rect :: proc(p: Vec2, r: Rect) -> bool {
	return(
		p.x >= r.pos.x &&
		p.x < r.pos.x + r.size.x &&
		p.y >= r.pos.y &&
		p.y < r.pos.y + r.size.y \
	)
}

@(private)
rect_intersect :: proc(a, b: Rect) -> Rect {
	p := Vec2{max(a.pos.x, b.pos.x), max(a.pos.y, b.pos.y)}
	e := Vec2{
		min(a.pos.x + a.size.x, b.pos.x + b.size.x),
		min(a.pos.y + a.size.y, b.pos.y + b.size.y),
	}
	return Rect{p, Vec2{max(e.x - p.x, 0), max(e.y - p.y, 0)}}
}

@(private)
chain_contains :: proc(chain: []Instance, id: Instance) -> bool {
	if id == 0 {
		return false
	}
	for c in chain {
		if c == id {
			return true
		}
	}
	return false
}

// note_affected records an instance whose resolved style may change because
// of a state transition; frame_end damages its rect and forces the frame.
@(private)
note_affected :: proc(id: Instance) {
	if id != 0 {
		append(&g.affected, id)
		g.input_dirty = true
	}
}

// ---------------------------------------------------------------------------
// The pick

// point_in_node tests the node's painted shape: its committed rect with
// rounded corners cut out, so hit truth matches paint truth at the
// corners too. The arc radius clamps to half the smaller dimension,
// matching how the backend paints an over-large radius. Styles come from
// last frame's resolution — the same tree the rect came from.
@(private)
point_in_node :: proc(i: int, p: Vec2) -> bool {
	r := Rect{g.lay[i].pos, g.lay[i].size}
	if !point_in_rect(p, r) {
		return false
	}
	rad := min(f32(node_style(i).corner_radius), min(r.size.x, r.size.y) / 2)
	if rad <= 0 {
		return true
	}
	l := Vec2{p.x - r.pos.x, p.y - r.pos.y}
	cx, cy := f32(-1), f32(-1)
	if l.x < rad {
		cx = rad
	} else if l.x >= r.size.x - rad {
		cx = r.size.x - rad
	}
	if l.y < rad {
		cy = rad
	} else if l.y >= r.size.y - rad {
		cy = r.size.y - rad
	}
	if cx < 0 || cy < 0 {
		return true // not in any corner square
	}
	d := Vec2{l.x - cx, l.y - cy}
	return d.x * d.x + d.y * d.y <= rad * rad
}

// pick_at returns the topmost node index at p in the tree currently in
// g.nodes (at dispatch time: last frame's committed tree), or -1. Reverse
// array order is reverse paint order, so the first hit is the visible one.
// The accumulated pick clip keeps children that are scrolled or clipped
// away from false-hitting outside their visible region.
@(private)
pick_at :: proc(p: Vec2) -> int {
	for i := len(g.nodes) - 1; i >= 0; i -= 1 {
		if g.nodes[i].culled {
			continue
		}
		if point_in_node(i, p) && point_in_rect(p, g.pick_clip[i]) {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// Dispatch (frame_begin, before the frame store is cleared)

// dispatch_input converts one frame of host input into interaction state.
// It reads last frame's nodes/lay/pick_clip exactly as frame_end left them.
@(private)
dispatch_input :: proc(input: Input, dt: f32) {
	// clicked answers for exactly one declare: the one following the
	// dispatch that produced it. Consumed or not, it ends here.
	g.clicked_id = 0
	clear(&g.clicked_chain)
	clear(&g.affected)

	// Focus loss drops press capture on the falling edge only, so no
	// click can complete across an alt-tab. Hover is NOT focus-gated:
	// it tracks the cursor over unfocused windows too, and the press
	// that focuses the window dispatches below like any other.
	if !input.window_focused && g.prev_focused {
		for b in Mouse_Button {
			if g.press_ids[b] != 0 {
				note_affected(g.press_ids[b])
				g.press_ids[b] = 0
				clear(&g.press_chains[b])
			}
		}
	}
	g.prev_focused = input.window_focused

	if !input.mouse_valid {
		// Cursor departure: everything ends at once.
		note_affected(g.hover_id)
		g.hover_id = 0
		clear(&g.hover_chain)
		clear(&g.hover_since)
		for b in Mouse_Button {
			note_affected(g.press_ids[b])
			g.press_ids[b] = 0
			clear(&g.press_chains[b])
		}
		return
	}

	pick := pick_at(input.mouse)

	// The pick's ancestor chain as node indices, root first.
	chain_idx: [dynamic]int
	defer delete(chain_idx)
	if pick >= 0 {
		depth := 0
		for c := pick; c != -1; c = g.nodes[c].parent {
			depth += 1
		}
		resize(&chain_idx, depth)
		k := depth - 1
		for c := pick; c != -1; c = g.nodes[c].parent {
			chain_idx[k] = c
			k -= 1
		}
	}

	// Disabled absorbs: truncate the working chain at the first disabled
	// instance (walking from the root). Press/click are blocked outright.
	blocked := false
	hover_len := len(chain_idx)
	for idx, k in chain_idx {
		if g.nodes[idx].with.disabled {
			hover_len = k + 1
			blocked = true
			break
		}
	}

	// Hover follows the cursor, never the capture. Durations are per
	// instance: every chain member stamps its entry time when it joins
	// the chain and loses the stamp when it leaves, so a button keeps
	// one continuous timer whether the cursor is over its body or its
	// label (each with its own start), and hover_duration answers for
	// any member of the chain.
	g.hover_clock += dt
	if g.hover_since == nil {
		g.hover_since = make(map[Instance]f32)
	}
	new_hover := Instance(0)
	if hover_len > 0 {
		new_hover = g.nodes[chain_idx[hover_len - 1]].identity
	}
	for id in g.hover_chain {
		stays := false
		for k in 0 ..< hover_len {
			if g.nodes[chain_idx[k]].identity == id {
				stays = true
				break
			}
		}
		if !stays {
			delete_key(&g.hover_since, id)
		}
	}
	clear(&g.hover_chain)
	for k in 0 ..< hover_len {
		id := g.nodes[chain_idx[k]].identity
		append(&g.hover_chain, id)
		if _, ok := g.hover_since[id]; !ok {
			g.hover_since[id] = g.hover_clock
		}
	}
	if new_hover != g.hover_id {
		note_affected(g.hover_id)
		note_affected(new_hover)
		g.hover_id = new_hover
	}

	// Press capture and click completion, per button.
	for b in Mouse_Button {
		if b in input.buttons_pressed && pick >= 0 && !blocked {
			g.press_ids[b] = g.nodes[pick].identity
			clear(&g.press_chains[b])
			for idx in chain_idx {
				append(&g.press_chains[b], g.nodes[idx].identity)
			}
			note_affected(g.press_ids[b])
		}
		if b in input.buttons_released {
			target := g.press_ids[b]
			if target != 0 {
				note_affected(target)
				if b == .Left && pick >= 0 && !blocked {
					// Release over the target or a descendant of it:
					// the target sits on the pick's chain.
					for idx in chain_idx {
						if g.nodes[idx].identity == target {
							g.clicked_id = target
							clear(&g.clicked_chain)
							append(&g.clicked_chain, ..g.press_chains[b][:])
							break
						}
					}
				}
				g.press_ids[b] = 0
				clear(&g.press_chains[b])
			}
		}
	}

	// The wheel is consumed last, once the pick's chain and its blocked
	// state are known; it writes offsets only (pass F does the moving).
	consume_wheel(input.wheel, chain_idx[:], blocked)
}

// consume_wheel routes one frame of accumulated wheel delta to the
// scrollable containers on the pick's ancestor chain, deepest first,
// per axis independently. A scrollable container takes what it can in
// the delta's direction (clamped to last frame's scroll range — pass F
// re-clamps against the live range); the leftover climbs to the next
// scrollable ancestor only while the container that held it has
// scroll_chain set — an opt-out ends the wheel region: the leftover is
// dropped, never skipped past. A disabled pick absorbs the wheel whole,
// like it absorbs clicks. Non-container nodes never participate: a
// leaf's scroll field has no children to move and no scroll range.
@(private)
consume_wheel :: proc(wheel: Vec2, chain: []int, blocked: bool) {
	if blocked || len(chain) == 0 || (wheel.x == 0 && wheel.y == 0) {
		return
	}
	if g.scroll_off == nil {
		g.scroll_off = make(map[Instance]Vec2)
	}
	for axis in 0 ..< 2 {
		// Sign: the host reports the scroll-UP direction as positive
		// (the SDL convention), so a positive delta DECREASES the
		// offset — the offset delta is the negation.
		rem := -wheel[axis] * WHEEL_UNIT_PX
		if rem == 0 {
			continue
		}
		for k := len(chain) - 1; k >= 0; k -= 1 {
			idx := chain[k]
			if !g.nodes[idx].is_container {
				continue
			}
			s := node_style(idx)
			if !scrollable_axis(s, axis) {
				continue
			}
			id := g.nodes[idx].identity
			off := g.scroll_off[id]
			clamped := clamp(off[axis] + rem, 0, g.scroll_max[id][axis])
			used := clamped - off[axis]
			if used != 0 {
				off[axis] = clamped
				g.scroll_off[id] = off
			}
			rem -= used
			if rem == 0 {
				break
			}
			if !s.scroll_chain {
				break // opt-out ends the wheel region
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Overlay resolution (frame_end, before layout)

// node_style is how layout and emit read a node's style: the resolved
// effective style when frame_end produced one, the unit's own style
// otherwise. Declare-time text/span resolution is the exception — it reads
// the base style, so an overlay cannot rewrite a node's text in v1 (font
// fields in overlays DO apply: measurement reads node_style).
@(private)
node_style :: proc(i: int) -> ^Style {
	if g.nodes[i].has_eff {
		return &g.eff[i]
	}
	return style_of(g.nodes[i].unit)
}

@(private)
resolve_styles :: proc() {
	n := len(g.nodes)
	resize(&g.eff, n)
	resize(&g.disabled_flags, n)
	for i in 0 ..< n {
		nd := &g.nodes[i]
		p := nd.parent
		dis := nd.with.disabled || (p >= 0 && g.disabled_flags[p])
		g.disabled_flags[i] = dis
		nd.has_eff = false

		id := nd.identity
		hov := chain_contains(g.hover_chain[:], id)
		prs := false
		for b in Mouse_Button {
			if chain_contains(g.press_chains[b][:], id) {
				prs = true
				break
			}
		}
		foc := g.focus_id != 0 && id == g.focus_id
		if !hov && !prs && !foc && !dis && nd.with.variant == NO_UNIT {
			continue
		}
		rec := &g.units[int(nd.unit)]
		eff := rec.style
		apply_overlay(&eff, nd.with.variant) // persistent per-instance overlay
		if foc { apply_overlay(&eff, rec.focus) }
		if hov { apply_overlay(&eff, rec.hover) }
		if prs { apply_overlay(&eff, rec.press) }
		if dis { apply_overlay(&eff, rec.disabled) }
		g.eff[i] = eff
		nd.has_eff = true
	}
}

// apply_overlay merges one overlay unit's explicitly-set fields over dst.
@(private)
apply_overlay :: proc(dst: ^Style, overlay: Unit) {
	if overlay == NO_UNIT {
		return
	}
	rec := &g.units[int(overlay)]
	for f in rec.explicit {
		copy_field(dst, &rec.style, f)
	}
}

@(private)
copy_field :: proc(dst, src: ^Style, f: Field) {
	switch f {
	case .Color:         dst.color         = src.color
	case .Font_Color:    dst.font_color    = src.font_color
	case .Border_Color:  dst.border_color  = src.border_color
	case .Text:          dst.text          = src.text
	case .Font:          dst.font          = src.font
	case .Font_Size:     dst.font_size     = src.font_size
	case .Font_Weight:   dst.font_weight   = src.font_weight
	case .Font_Slant:    dst.font_slant    = src.font_slant
	case .Text_Spans:    dst.text_spans    = src.text_spans
	case .Text_Wrap:     dst.wrap          = src.wrap
	case .Ellipsis:      dst.ellipsis      = src.ellipsis
	case .Padding:       dst.padding       = src.padding
	case .Gap:           dst.gap           = src.gap
	case .Corner_Radius: dst.corner_radius = src.corner_radius
	case .Opacity:       dst.opacity       = src.opacity
	case .Layout:        dst.layout        = src.layout
	case .Align:         dst.align         = src.align
	case .Size:          dst.size          = src.size
	case .Scroll:        dst.scroll        = src.scroll
	case .Overflow:      dst.overflow      = src.overflow
	case .Border_Width:  dst.border_width  = src.border_width
	case .Overlay_Color:        dst.overlay_color        = src.overlay_color
	case .Overlay_Border_Color: dst.overlay_border_color = src.overlay_border_color
	case .Overlay_Border_Width: dst.overlay_border_width = src.overlay_border_width
	case .Cursor:       dst.cursor       = src.cursor
	case .Scroll_Chain: dst.scroll_chain = src.scroll_chain
	}
}

// current_cursor resolves the frame's cursor by walking the hover chain
// from the target upward: the first instance whose effective style names
// a non-default cursor speaks for the whole chain, so a label over a
// button doesn't swallow the button's pointer (this frame's tree).
// A disabled target is the exception: its base cursor is suppressed — a
// disabled control must not advertise interactivity — and only an
// explicit cursor on its disabled overlay unit applies. Disabled is
// read from THIS frame's resolution (disabled_flags), not from the
// dispatch, so the cursor agrees with the paint on the very frame a
// control becomes disabled.
@(private)
current_cursor :: proc() -> Cursor_Kind {
	if g.hover_id == 0 {
		return .Arrow
	}
	for i in 0 ..< len(g.nodes) {
		if g.nodes[i].identity == g.hover_id {
			if i < len(g.disabled_flags) && g.disabled_flags[i] {
				rec := &g.units[int(g.nodes[i].unit)]
				if rec.disabled != NO_UNIT {
					drec := &g.units[int(rec.disabled)]
					if .Cursor in drec.explicit {
						return node_style(i).cursor
					}
				}
				return .Arrow
			}
			break
		}
	}
	for ci := len(g.hover_chain) - 1; ci >= 0; ci -= 1 {
		id := g.hover_chain[ci]
		for i in 0 ..< len(g.nodes) {
			if g.nodes[i].identity == id {
				if c := node_style(i).cursor; c != .Arrow {
					return c
				}
				break
			}
		}
	}
	return .Arrow
}
