// layout.odin — the layout engine: seven linear passes over the flat node array.
// Faithful to UI_API_Design.md §9. Deviations from the doc are marked DEVIATION
// and collected in the test report.
//
//   pass 0: measure_text_all   (text leaves -> content/min_c via word cache)
//   pass A: accumulate(X)      (bottom-up intrinsic widths)
//   pass B: distribute(X)      (top-down widths + waterfill)
//   pass C: wrap_text          (pack words into resolved widths)
//   pass D: accumulate(Y)      (bottom-up heights)
//   pass E: distribute(Y)      (top-down heights)
//   pass F: position_and_damage(positions, instance rects, damage, overflow)
package niello


Lay :: struct {
	content: Vec2, // intrinsic size (measured / accumulated)
	min_c:   Vec2, // shrink floor
	size:    Vec2, // resolved size
	pos:     Vec2, // resolved top-left
	overfl:  Vec2, // content extent beyond bounds, per axis
	tight:   [2]bool,
	gen:     u32, // layout-generation stamp (debug size-read discipline)
}

X_AXIS, Y_AXIS :: 0, 1

main_axis :: proc(l: Layout) -> int {
	return X_AXIS if l == .Left_To_Right else Y_AXIS
}

padding_sum :: proc(s: ^Style, axis: int) -> f32 {
	if axis == X_AXIS {
		return f32(s.padding[0]) + f32(s.padding[2])
	}
	return f32(s.padding[1]) + f32(s.padding[3])
}

// scrollable_axis: Scroll is per-axis in the public API; layout needs it per axis.
scrollable_axis :: proc(s: ^Style, axis: int) -> bool {
	if axis == X_AXIS {
		return s.scroll == .Horizontal || s.scroll == .Both
	}
	return s.scroll == .Vertical || s.scroll == .Both
}

// NOTE: implements the doc's current End->max(free,0). The pending §7.1
// decision proposes End->free (anchor-invariant); that would change one line.
align_offset :: proc(a: Align_Kind, free: f32) -> f32 {
	switch a {
	case .Start:
		return 0
	case .Center:
		return free / 2
	case .End:
		return max(free, 0)
	}
	unreachable()
}

stack_align_offset :: proc(s: ^Style, child_size, inner: Vec2) -> Vec2 {
	return Vec2{
		align_offset(s.align[X_AXIS], inner.x - child_size.x),
		align_offset(s.align[Y_AXIS], inner.y - child_size.y),
	}
}

// NOTE: resolve_root was called but never defined in the design doc.
// Definition: roots fill the viewport unless FIXED/PERCENT say otherwise.
resolve_root :: proc(r: int, axis: int, viewport_extent: f32) -> f32 {
	sz := node_style(r).size[axis]
	v := viewport_extent
	switch sz.kind {
	case .Fixed:
		v = sz.value
	case .Percent:
		v = sz.value * viewport_extent
	case .Fit, .Grow:
	// fill the viewport
	}
	return clamp(v, sz.min, sz.max)
}

floor_of :: proc(c: int, axis: int) -> f32 {
	s := node_style(c)
	// min_c is the true shrink floor: measure_text already folded the
	// ellipsis policy into it (no-wrap ellipsis text floors at the "…"
	// width), so this is a plain read plus the user's explicit Sizing min.
	return max(s.size[axis].min, g.lay[c].min_c[axis])
}

ceil_of :: proc(c: int, axis: int) -> f32 {
	return node_style(c).size[axis].max
}

set_size :: proc(c: int, axis: int, v: f32, tight: bool) {
	g.lay[c].size[axis] = v
	g.lay[c].tight[axis] = tight
	g.lay[c].gen = g.layout_gen
}

// ---------------------------------------------------------------------------
// Pass 0 + list building

build_child_lists :: proc() {
	n := len(g.nodes)
	resize(&g.first_child, n)
	resize(&g.next_sibling, n)
	resize(&g.subtree_end, n)
	for i in 0 ..< n {
		g.first_child[i] = -1
		g.next_sibling[i] = -1
		g.subtree_end[i] = i
	}
	resize(&g.scratch_ints, n)
	last_child := g.scratch_ints[:]
	for i in 0 ..< n {
		last_child[i] = -1
	}
	for i in 0 ..< n {
		p := g.nodes[i].parent
		if p < 0 {
			continue
		}
		if g.first_child[p] == -1 {
			g.first_child[p] = i
		} else {
			g.next_sibling[last_child[p]] = i
		}
		last_child[p] = i
	}
	// Subtree ends, reverse pass (children known before parents).
	for i := n - 1; i >= 0; i -= 1 {
		p := g.nodes[i].parent
		if p >= 0 {
			g.subtree_end[p] = max(g.subtree_end[p], g.subtree_end[i])
		}
	}
}

measure_text_all :: proc() {
	n := len(g.nodes)
	resize(&g.lay, n)
	for i in 0 ..< n {
		g.lay[i] = Lay{}
	}
	for i in 0 ..< n {
		nd := &g.nodes[i]
		s := node_style(i)
		if nd.has_text {
			uw, minw := measure_text(s, nd.spans, nd.spans_hash, nd.text_hash, nd.text, s.wrap)
			g.lay[i].content = uw
			g.lay[i].min_c = Vec2{minw, 0}
		} else if !nd.is_container {
			// Plain leaf: FIXED axes contribute their value as content so FIT
			// parents can accumulate them; everything else contributes 0.
			for a in 0 ..< 2 {
				if s.size[a].kind == .Fixed {
					g.lay[i].content[a] = s.size[a].value
					g.lay[i].min_c[a] = s.size[a].value
				}
			}
		}
	}
}

// A child's contribution to its parent's accumulated size: FIXED children
// contribute their fixed value (not their intrinsic content — e.g. a FIXED-200
// text node whose unwrapped text is 240px still takes 200px). Everything else
// contributes its intrinsic content / shrink floor.
accum_size :: proc(c: int, axis: int) -> f32 {
	sz := node_style(c).size[axis]
	if sz.kind == .Fixed {
		return sz.value
	}
	return g.lay[c].content[axis]
}

accum_min :: proc(c: int, axis: int) -> f32 {
	sz := node_style(c).size[axis]
	if sz.kind == .Fixed {
		return sz.value
	}
	// min_c is already the effective floor (measure_text folds the ellipsis
	// policy into it at measurement time), so accumulation is a plain read.
	return g.lay[c].min_c[axis]
}

// ---------------------------------------------------------------------------
// Passes A/D: bottom-up intrinsic accumulation (reverse walk)

accumulate :: proc(axis: int) {
	n := len(g.nodes)
	for i := n - 1; i >= 0; i -= 1 {
		nd := &g.nodes[i]
		if !nd.is_container {
			continue
		}
		s := node_style(i)
		pad := padding_sum(s, axis)
		gap := f32(s.gap)
		if s.layout == .Stack {
			m, mmin := f32(0), f32(0)
			for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
				m = max(m, accum_size(c, axis))
				mmin = max(mmin, accum_min(c, axis))
			}
			g.lay[i].content[axis] = m + pad
			g.lay[i].min_c[axis] = mmin + pad
		} else if axis == main_axis(s.layout) {
			total, mtotal := f32(0), f32(0)
			nchild := 0
			for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
				total += accum_size(c, axis) + gap
				mtotal += accum_min(c, axis) + gap
				nchild += 1
			}
			if nchild > 0 {
				total -= gap
				mtotal -= gap
			}
			g.lay[i].content[axis] = total + pad
			g.lay[i].min_c[axis] = mtotal + pad
		} else {
			m, mmin := f32(0), f32(0)
			for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
				m = max(m, accum_size(c, axis))
				mmin = max(mmin, accum_min(c, axis))
			}
			g.lay[i].content[axis] = m + pad
			g.lay[i].min_c[axis] = mmin + pad
		}
	}
}

// ---------------------------------------------------------------------------
// Passes B/E: top-down distribution (forward walk)

resolve_cross :: proc(c: int, axis: int, inner: f32) {
	sz := node_style(c).size[axis]
	switch sz.kind {
	case .Fixed:
		set_size(c, axis, clamp(sz.value, sz.min, sz.max), true)
	case .Percent:
		set_size(c, axis, clamp(sz.value * inner, sz.min, sz.max), true)
	case .Fit:
		// FIT grants content, bounded by the space the parent offers — the
		// cross-axis mirror of the main axis's waterfill bound. Without the
		// offer bound a FIT child keeps its full intrinsic size however
		// narrow the parent is, and (for text) the ellipsis never engages.
		// The shrink floor still wins over the offer: content that cannot
		// shrink further resolves at its floor and pass F records the excess
		// as overflow, exactly like waterfill_take's surviving deficit. A
		// parent scrollable on this axis is exempt — the child's natural
		// size IS the scroll extent there.
		v := g.lay[c].content[axis]
		if p := g.nodes[c].parent; p < 0 || !scrollable_axis(node_style(p), axis) {
			v = min(v, inner)
		}
		v = max(v, floor_of(c, axis))
		set_size(c, axis, clamp(v, sz.min, sz.max), false)
	case .Grow:
		set_size(c, axis, clamp(inner, sz.min, sz.max), true)
	}
}

// Fair-share distribution. O(n^2) worst case here; sort candidates once for
// O(n log n) — same result.
waterfill_give :: proc(cands: []int, axis: int, amount: f32) {
	active := cands
	remaining := amount
	for len(active) > 0 {
		share := remaining / f32(len(active))
		if share <= 1e-6 {
			break
		}
		clamped := false
		for j := len(active) - 1; j >= 0; j -= 1 {
			c := active[j]
			ceil := ceil_of(c, axis)
			if g.lay[c].size[axis] + share >= ceil {
				remaining -= ceil - g.lay[c].size[axis]
				g.lay[c].size[axis] = ceil
				g.lay[c].gen = g.layout_gen
				// swap-remove (order is irrelevant to the waterfill)
				active[j] = active[len(active) - 1]
				active = active[:len(active) - 1]
				clamped = true
			}
		}
		if !clamped {
			for c in active {
				g.lay[c].size[axis] += share
				g.lay[c].gen = g.layout_gen
			}
			break
		}
	}
}

waterfill_take :: proc(cands: []int, axis: int, deficit: f32) {
	active := cands
	remaining := deficit
	for len(active) > 0 {
		share := remaining / f32(len(active))
		if share <= 1e-6 {
			break
		}
		clamped := false
		for j := len(active) - 1; j >= 0; j -= 1 {
			c := active[j]
			floor := floor_of(c, axis)
			if g.lay[c].size[axis] - share <= floor {
				remaining -= g.lay[c].size[axis] - floor
				g.lay[c].size[axis] = floor
				g.lay[c].gen = g.layout_gen
				// swap-remove (order is irrelevant to the waterfill)
				active[j] = active[len(active) - 1]
				active = active[:len(active) - 1]
				clamped = true
			}
		}
		if !clamped {
			for c in active {
				g.lay[c].size[axis] -= share
				g.lay[c].gen = g.layout_gen
			}
			break
		}
	}
	// Any surviving deficit becomes overflow, recorded in pass F.
}

distribute_main :: proc(i: int, axis: int, inner: f32) {
	s := node_style(i)
	// Reused across containers (cleared per use); the waterfill swap-removes
	// inside the slice, which is fine because nothing survives the clear.
	growers := &g.scratch_a
	shrinkables := &g.scratch_b
	clear(growers)
	clear(shrinkables)
	// Committed space: EVERY child's starting size, growers included. The
	// waterfill adds the leftover ON TOP of a grower's content size, so
	// leaving growers out of the sum hands them their content twice — the
	// final total overshoots by the sum of the growers' content sizes.
	committed := f32(0)
	nchild := 0
	// A root is never "fit" here: resolve_root gives it a definite size from
	// the viewport whatever its style kind says, so its GROW children grow.
	// Only a non-root FIT container is truly content-sized — the circular
	// case the GROW-in-FIT fallback below exists for.
	parent_fit := s.size[axis].kind == .Fit && g.nodes[i].parent >= 0
	for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
		nchild += 1
		sz := node_style(c).size[axis]
		switch sz.kind {
		case .Fixed:
			v := clamp(sz.value, sz.min, sz.max)
			set_size(c, axis, v, true)
			committed += v
		case .Percent:
			v := clamp(sz.value * inner, sz.min, sz.max)
			set_size(c, axis, v, true)
			committed += v
		case .Fit:
			v := clamp(g.lay[c].content[axis], sz.min, sz.max)
			set_size(c, axis, v, false)
			committed += v
			append(shrinkables, c)
		case .Grow:
			if parent_fit {
				// DEVIATION from naive reading: GROW inside FIT is circular
				// (parent sizes to children, child wants parent's leftovers).
				// Documented fallback: behave as FIT.
				v := clamp(g.lay[c].content[axis], sz.min, sz.max)
				set_size(c, axis, v, false)
				committed += v
				append(shrinkables, c)
			} else {
				v := clamp(g.lay[c].content[axis], sz.min, sz.max)
				set_size(c, axis, v, false)
				committed += v
				append(growers, c)
				append(shrinkables, c)
			}
		}
	}
	gaps := f32(0)
	if nchild > 0 {
		gaps = f32(nchild-1) * f32(s.gap)
	}
	remaining := inner - committed - gaps
	if parent_fit {
		return // parent sized to content; nothing to distribute
	}
	if remaining < 0 && !scrollable_axis(s, axis) {
		// Scroll containers skip the take: children keep natural sizes and the
		// excess becomes scrollable overflow. That IS the scroll semantic.
		waterfill_take(shrinkables[:], axis, -remaining)
	} else if remaining > 0 && len(growers) > 0 {
		waterfill_give(growers[:], axis, remaining)
	}
	// remaining > 0 with no growers: space stays empty; main-axis alignment
	// at position time handles it.
}

distribute :: proc(axis: int, viewport_extent: f32) {
	n := len(g.nodes)
	for i in 0 ..< n {
		if g.nodes[i].parent == -1 {
			g.lay[i].size[axis] = resolve_root(i, axis, viewport_extent)
		}
	}
	for i in 0 ..< n {
		nd := &g.nodes[i]
		if !nd.is_container {
			continue
		}
		s := node_style(i)
		inner := g.lay[i].size[axis] - padding_sum(s, axis)
		if inner < 0 {
			inner = 0
		}
		if s.layout == .Stack {
			// Stack children are excluded from the waterfill: each resolves
			// independently against the full content box.
			for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
				resolve_cross(c, axis, inner)
			}
			continue
		}
		if axis == main_axis(s.layout) {
			distribute_main(i, axis, inner)
		} else {
			for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
				resolve_cross(c, axis, inner)
			}
		}
	}
	// DEVIATION (bug fix vs the doc's pseudocode): the doc appends text nodes to
	// wrap_list inside distribute_main, which also runs for the Y axis — so text
	// under a Top_To_Bottom parent would never wrap (pass C already ran).
	// Wrapping needs the resolved X width, which exists after distribute(X)
	// regardless of parent direction, so collection happens here, on X only.
	if axis == X_AXIS {
		for i in 0 ..< n {
			nd := &g.nodes[i]
			if nd.has_text && node_style(i).wrap == .Word {
				append(&g.wrap_list, i)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Pass C: wrap text into resolved widths

wrap_text :: proc() {
	for w in g.wrap_list {
		if g.lay[w].content.x <= g.lay[w].size.x + 1e-6 {
			continue // fits: single line, already correct
		}
		nd := &g.nodes[w]
		s := node_style(w)
		lines, line_h := wrapped_lines(s, nd.spans, nd.spans_hash, nd.text_hash, nd.text, g.lay[w].size.x)
		g.lay[w].content.y = f32(lines) * line_h
		// Width stays: content.x keeps its unwrapped meaning ("how wide would
		// this want to be"); size.x is the truth the rest of the frame uses.
	}
	clear(&g.wrap_list)
}

// ---------------------------------------------------------------------------
// Pass F: positioning, instance rects, damage, overflow

// content_hash fingerprints everything about a node that reaches the draw
// list: the resolved style's value fields plus the declare-time text and
// span hashes. The string/slice fields are covered by those hashes rather
// than by their headers. Cursor and Scroll_Chain are deliberately
// excluded: neither is visual (cursor is host state; scroll_chain steers
// dispatch), so changing them must not repaint.
@(private)
content_hash :: proc(i: int) -> u64 {
	s := node_style(i)
	nd := &g.nodes[i]
	h := u64(14695981039346656037)
	mixc :: proc(h: u64, c: Color) -> u64 {
		return hash_mix(h, u64(c[0]) | u64(c[1]) << 8 | u64(c[2]) << 16 | u64(c[3]) << 24)
	}
	h = mixc(h, s.color)
	h = mixc(h, s.font_color)
	h = mixc(h, s.border_color)
	h = hash_mix(h, u64(s.font))
	h = hash_mix(h, u64(transmute(u32)(s.font_size)))
	h = hash_mix(h, u64(s.font_weight))
	h = hash_mix(h, u64(s.font_slant))
	h = hash_mix(h, nd.text_hash)
	h = hash_mix(h, nd.spans_hash)
	for v in s.padding {
		h = hash_mix(h, u64(v))
	}
	h = hash_mix(h, u64(s.gap))
	h = hash_mix(h, u64(s.border_width))
	h = hash_mix(h, u64(s.corner_radius))
	h = hash_mix(h, u64(s.opacity))
	h = hash_mix(h, u64(s.layout))
	for a in 0 ..< 2 {
		sz := s.size[a]
		h = hash_mix(h, u64(sz.kind))
		h = hash_mix(h, u64(transmute(u32)(sz.value)))
		h = hash_mix(h, u64(transmute(u32)(sz.min)))
		h = hash_mix(h, u64(transmute(u32)(sz.max)))
		h = hash_mix(h, u64(s.align[a]))
	}
	h = hash_mix(h, u64(s.scroll))
	h = hash_mix(h, u64(s.wrap))
	h = hash_mix(h, u64(s.ellipsis ? 1 : 0))
	h = hash_mix(h, u64(s.overflow))
	h = mixc(h, s.overlay_color)
	h = mixc(h, s.overlay_border_color)
	h = hash_mix(h, u64(s.overlay_border_width))
	return h
}

rect_union :: proc(a, b: Rect) -> Rect {
	min_p := Vec2{min(a.pos.x, b.pos.x), min(a.pos.y, b.pos.y)}
	max_a := Vec2{a.pos.x + a.size.x, a.pos.y + a.size.y}
	max_b := Vec2{b.pos.x + b.size.x, b.pos.y + b.size.y}
	max_p := Vec2{max(max_a.x, max_b.x), max(max_a.y, max_b.y)}
	return Rect{min_p, max_p - min_p}
}

position_and_damage :: proc() {
	n := len(g.nodes)
	for r in 0 ..< n {
		if g.nodes[r].parent == -1 {
			g.lay[r].pos = Vec2{0, 0}
		}
	}
	for i in 0 ..< n {
		nd := &g.nodes[i]
		if !nd.is_container {
			continue
		}
		s := node_style(i)
		// The live scroll offset: the stored value, clamped per
		// scrollable axis to last frame's range (g.scroll_max — g.lay
		// was zeroed by pass 0, so the range cannot come from there).
		// The fresh range computed below re-clamps it for storage.
		scroll := Vec2{0, 0}
		stored_off, has_off := g.scroll_off[nd.identity]
		if has_off {
			prev_max := g.scroll_max[nd.identity]
			for axis in 0 ..< 2 {
				if scrollable_axis(s, axis) {
					scroll[axis] = clamp(stored_off[axis], 0, prev_max[axis])
				}
			}
		}
		base := g.lay[i].pos
		pad := Vec2{f32(s.padding[0]), f32(s.padding[1])}
		axis := main_axis(s.layout) if s.layout != .Stack else X_AXIS
		cursor := base + pad - scroll
		if s.layout != .Stack {
			// Main-axis alignment: shift the whole row/column in leftover space.
			used := f32(0)
			nchild := 0
			for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
				used += g.lay[c].size[axis]
				nchild += 1
			}
			if nchild > 0 {
				used += f32(nchild-1) * f32(s.gap)
			}
			free := (g.lay[i].size[axis] - padding_sum(s, axis)) - used
			cursor[axis] += align_offset(s.align[axis], free)
		}
		max_end := Vec2{0, 0} // pre-scroll content extent
		for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
			p := cursor
			if s.layout == .Stack {
				inner := g.lay[i].size - Vec2{padding_sum(s, X_AXIS), padding_sum(s, Y_AXIS)}
				p = base + pad - scroll + stack_align_offset(s, g.lay[c].size, inner)
			} else {
				cross := 1 - axis
				free := (g.lay[i].size[cross] - padding_sum(s, cross)) - g.lay[c].size[cross]
				p[cross] += align_offset(s.align[cross], free)
			}
			g.lay[c].pos = p
			g.lay[c].gen = g.layout_gen
			if s.layout != .Stack {
				cursor[axis] += g.lay[c].size[axis] + f32(s.gap)
			}
			ce := p + scroll + g.lay[c].size // content extent, pre-scroll
			max_end.x = max(max_end.x, ce.x)
			max_end.y = max(max_end.y, ce.y)
		}
		origin := base + pad
		inner := Vec2{
			g.lay[i].size.x - padding_sum(s, X_AXIS),
			g.lay[i].size.y - padding_sum(s, Y_AXIS),
		}
		g.lay[i].overfl = Vec2{
			max(0, max_end.x - (origin.x + inner.x)),
			max(0, max_end.y - (origin.y + inner.y)),
		}
		// Publish the fresh range for the next frame's clamps, and
		// store back the offset re-clamped against it: scroll_offset()
		// then reports rendered truth, and shrinking content pulls a
		// stranded offset back in. The write-back clamps the STORED
		// value (not this frame's read-clamped scroll), so an offset
		// set before the first frame survives to be rendered once a
		// range exists. Pass F never creates an offset entry.
		if scrollable_axis(s, X_AXIS) || scrollable_axis(s, Y_AXIS) {
			if g.scroll_max == nil {
				g.scroll_max = make(map[Instance]Vec2)
			}
			g.scroll_max[nd.identity] = g.lay[i].overfl
		}
		if has_off {
			eff := Vec2{0, 0}
			for axis in 0 ..< 2 {
				if scrollable_axis(s, axis) {
					eff[axis] = clamp(stored_off[axis], 0, g.lay[i].overfl[axis])
				}
			}
			g.scroll_off[nd.identity] = eff
		}
	}
	// Accumulated ancestor clips for the next frame's hit test (input.odin's
	// pick reads them alongside these positions): a node's pick clip is its
	// parent's, intersected with the parent's rect when the parent clips —
	// the same predicate emit uses for Push_Clip (Overflow.Clip, or any
	// scrolling). Positions are final here, parents before children.
	resize(&g.pick_clip, n)
	for i in 0 ..< n {
		p := g.nodes[i].parent
		if p < 0 {
			g.pick_clip[i] = Rect{{-1e18, -1e18}, {2e18, 2e18}}
			continue
		}
		clip := g.pick_clip[p]
		ps := node_style(p)
		if ps.overflow == .Clip || scrollable_axis(ps, X_AXIS) || scrollable_axis(ps, Y_AXIS) {
			clip = rect_intersect(clip, Rect{g.lay[p].pos, g.lay[p].size})
		}
		g.pick_clip[i] = clip
	}
	// Commit rects + damage: old ∪ new, expanded by overflow (children painting
	// outside their bounds must be covered). §5's rule is "changed → new
	// rect": changed means the committed CONTENT changed, not just the
	// rect — a same-size text edit or a set() restyle damages too, via the
	// per-instance content hash.
	if g.instances == nil {
		g.instances = make(map[Instance]Rect)
	}
	if g.inst_hash == nil {
		g.inst_hash = make(map[Instance]u64)
	}
	for i in 0 ..< n {
		id := g.nodes[i].identity
		new := Rect{g.lay[i].pos, g.lay[i].size}
		h := content_hash(i)
		old, ok := g.instances[id]
		old_h := g.inst_hash[id] // 0 when absent; real hashes are never 0 here
		if !ok {
			r := new
			r.size.x += g.lay[i].overfl.x
			r.size.y += g.lay[i].overfl.y
			append(&g.damage, r)
		} else if old != new || old_h != h {
			r := rect_union(old, new)
			r.size.x += g.lay[i].overfl.x
			r.size.y += g.lay[i].overfl.y
			append(&g.damage, r)
		}
		g.instances[id] = new
		g.inst_hash[id] = h
	}
	// NOTE: destroyed instances (in the map but not declared this frame) should
	// have their old rects appended to damage. Left for the recycle pass.
}

// ---------------------------------------------------------------------------

layout_pass :: proc(viewport: Vec2) {
	build_child_lists()
	measure_text_all() // 0
	accumulate(X_AXIS) // A
	distribute(X_AXIS, viewport.x) // B
	wrap_text() // C
	accumulate(Y_AXIS) // D
	distribute(Y_AXIS, viewport.y) // E
	position_and_damage() // F
	g.layout_gen += 1
}
