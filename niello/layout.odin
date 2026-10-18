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
	sz := g.units[int(g.nodes[r].unit)].style.size[axis]
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
	s := style_of(g.nodes[c].unit)
	fl := g.lay[c].min_c[axis]
	if g.nodes[c].has_text && axis == X_AXIS && s.wrap == .None && s.ellipsis {
		// Ellipsis text may shrink to the "…" width in its own style; paint
		// covers the rest.
		fl = min(fl, ellipsis_width(s))
	}
	return max(s.size[axis].min, fl)
}

ceil_of :: proc(c: int, axis: int) -> f32 {
	return style_of(g.nodes[c].unit).size[axis].max
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
		s := style_of(nd.unit)
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
	sz := style_of(g.nodes[c].unit).size[axis]
	if sz.kind == .Fixed {
		return sz.value
	}
	return g.lay[c].content[axis]
}

accum_min :: proc(c: int, axis: int) -> f32 {
	sz := style_of(g.nodes[c].unit).size[axis]
	if sz.kind == .Fixed {
		return sz.value
	}
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
		s := style_of(nd.unit)
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
	sz := style_of(g.nodes[c].unit).size[axis]
	switch sz.kind {
	case .Fixed:
		set_size(c, axis, clamp(sz.value, sz.min, sz.max), true)
	case .Percent:
		set_size(c, axis, clamp(sz.value * inner, sz.min, sz.max), true)
	case .Fit:
		set_size(c, axis, clamp(g.lay[c].content[axis], sz.min, sz.max), false)
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
	s := style_of(g.nodes[i].unit)
	// Reused across containers (cleared per use); the waterfill swap-removes
	// inside the slice, which is fine because nothing survives the clear.
	growers := &g.scratch_a
	shrinkables := &g.scratch_b
	clear(growers)
	clear(shrinkables)
	fixed_sum := f32(0)
	nchild := 0
	parent_fit := s.size[axis].kind == .Fit
	for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
		nchild += 1
		sz := style_of(g.nodes[c].unit).size[axis]
		switch sz.kind {
		case .Fixed:
			v := clamp(sz.value, sz.min, sz.max)
			set_size(c, axis, v, true)
			fixed_sum += v
		case .Percent:
			v := clamp(sz.value * inner, sz.min, sz.max)
			set_size(c, axis, v, true)
			fixed_sum += v
		case .Fit:
			v := clamp(g.lay[c].content[axis], sz.min, sz.max)
			set_size(c, axis, v, false)
			fixed_sum += v
			append(shrinkables, c)
		case .Grow:
			if parent_fit {
				// DEVIATION from naive reading: GROW inside FIT is circular
				// (parent sizes to children, child wants parent's leftovers).
				// Documented fallback: behave as FIT.
				v := clamp(g.lay[c].content[axis], sz.min, sz.max)
				set_size(c, axis, v, false)
				fixed_sum += v
				append(shrinkables, c)
			} else {
				v := clamp(g.lay[c].content[axis], sz.min, sz.max)
				set_size(c, axis, v, false)
				append(growers, c)
				append(shrinkables, c)
			}
		}
	}
	gaps := f32(0)
	if nchild > 0 {
		gaps = f32(nchild-1) * f32(s.gap)
	}
	remaining := inner - fixed_sum - gaps
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
		s := style_of(nd.unit)
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
			if nd.has_text && style_of(nd.unit).wrap == .Word {
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
		s := style_of(nd.unit)
		lines, line_h := wrapped_lines(s, nd.spans, nd.spans_hash, nd.text_hash, nd.text, g.lay[w].size.x)
		g.lay[w].content.y = f32(lines) * line_h
		// Width stays: content.x keeps its unwrapped meaning ("how wide would
		// this want to be"); size.x is the truth the rest of the frame uses.
	}
	clear(&g.wrap_list)
}

// ---------------------------------------------------------------------------
// Pass F: positioning, instance rects, damage, overflow

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
		s := style_of(nd.unit)
		scroll := Vec2{0, 0} // mock: no live scroll offsets yet
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
	}
	// Commit rects + damage: old ∪ new, expanded by overflow (children painting
	// outside their bounds must be covered).
	if g.instances == nil {
		g.instances = make(map[Instance]Rect)
	}
	for i in 0 ..< n {
		id := g.nodes[i].identity
		new := Rect{g.lay[i].pos, g.lay[i].size}
		old, ok := g.instances[id]
		if !ok {
			r := new
			r.size.x += g.lay[i].overfl.x
			r.size.y += g.lay[i].overfl.y
			append(&g.damage, r)
			g.instances[id] = new
		} else if old != new {
			r := rect_union(old, new)
			r.size.x += g.lay[i].overfl.x
			r.size.y += g.lay[i].overfl.y
			append(&g.damage, r)
			g.instances[id] = new
		}
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
