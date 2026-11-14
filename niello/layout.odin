#+private
package niello

// layout.odin — the layout engine: seven linear passes over the flat node array.
// Faithful to UI_API_Design.md §9. Deviations from the doc are marked DEVIATION
// and collected in the test report.
//
//   pass 0: measure_text_range (text leaves -> content/min_c via word cache)
//   pass A: accumulate(X)      (bottom-up intrinsic widths)
//   pass B: distribute(X)      (top-down widths + waterfill)
//   pass C: wrap_text          (pack words into resolved widths)
//   pass D: accumulate(Y)      (bottom-up heights)
//   pass E: distribute(Y)      (top-down heights)
//   pass F: position_range (positions, overflow, scroll ranges), then
//           pick_clips_and_commit (pick clips, instance rects, damage)
//
// Every pass runs over an index range [lo, hi): the whole tree for the
// main layout, a section's appended nodes for a section pass.


Lay :: struct {
	content: Vec2, // intrinsic size (measured / accumulated)
	min_c:   Vec2, // shrink floor
	size:    Vec2, // resolved size
	pos:     Vec2, // resolved top-left
	overfl:  Vec2, // content extent beyond bounds, per axis
	scroll:  Vec2, // pass F scratch: the effective scroll offset positioning used
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

// Popup roots (§3.19) size like ordinary nodes, not viewport roots:
// Fixed and Percent (of the viewport) as usual, but Fit — and Grow,
// which has no parent to grow into — resolve to the content size.
resolve_popup_root :: proc(r: int, axis: int, viewport_extent: f32) -> f32 {
	sz := node_style(r).size[axis]
	v := g.lay[r].content[axis]
	switch sz.kind {
	case .Fixed:
		v = sz.value
	case .Percent:
		v = sz.value * viewport_extent
	case .Fit, .Grow:
	}
	return clamp(v, sz.min, sz.max)
}

// popup_position resolves a popup root's top-left (§3.19): the
// anchor's last committed rect (pass F commits after positioning,
// so g.instances still holds it) plus this frame's resolved size.
// Anchored placements flip when the content would leave the
// viewport there and fit on the opposite side; the cross axis
// clamps into the viewport. .At and .Center have no anchor to flip
// around: .At clamps the point into the viewport, .Center centers.
// Nothing paints outside the viewport.
popup_position :: proc(r: int) -> Vec2 {
	nd := &g.nodes[r]
	size := g.lay[r].size
	vp := g.viewport
	clamp_to_view :: proc(p: Vec2, size: Vec2, vp: Vec2) -> Vec2 {
		return Vec2{
			clamp(p.x, 0, max(0, vp.x - size.x)),
			clamp(p.y, 0, max(0, vp.y - size.y)),
		}
	}
	if nd.popup_place == .Center {
		return clamp_to_view(
			Vec2{(vp.x - size.x) / 2, (vp.y - size.y) / 2}, size, vp,
		)
	}
	if nd.popup_place == .At {
		// The point is app-owned state (a dragged dialog's
		// position, a menu's cursor point): place the top-left
		// at it and clamp into the viewport. Reflecting around
		// the point — the old behavior — broke app-owned
		// positions: dragging a dialog to the right edge jumped
		// it left by its full width when the far edge crossed
		// the viewport, and back when it crossed back.
		// Clamping pins at the edge instead, with no
		// discontinuity.
		return clamp_to_view(nd.popup_at, size, vp)
	}
	a_rec, ok := g.instances[nd.popup_anchor]
	a := a_rec.rect
	if !ok {
		// begin_popup culled this root (no committed anchor), so
		// the position is never painted or picked; park it at the
		// origin rather than inventing a place.
		return Vec2{0, 0}
	}
	gap := nd.popup_gap
	p := Vec2{0, 0}
	switch nd.popup_place {
	case .Below, .Above:
		p.x = a.pos.x
		below := a.pos.y + a.size.y + gap
		above := a.pos.y - size.y - gap
		p.y = below
		if nd.popup_place == .Above {
			p.y = above
		}
		if nd.popup_place == .Below && below + size.y > vp.y && above >= 0 {
			p.y = above
		}
		if nd.popup_place == .Above && above < 0 && below + size.y <= vp.y {
			p.y = below
		}
	case .Left, .Right:
		p.y = a.pos.y
		right := a.pos.x + a.size.x + gap
		left := a.pos.x - size.x - gap
		p.x = right
		if nd.popup_place == .Left {
			p.x = left
		}
		if nd.popup_place == .Right && right + size.x > vp.x && left >= 0 {
			p.x = left
		}
		if nd.popup_place == .Left && left < 0 && right + size.x <= vp.x {
			p.x = right
		}
	case .At, .Center:
		unreachable()
	}
	return clamp_to_view(p, size, vp)
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

set_size :: proc(c: int, axis: int, v: f32) {
	g.lay[c].size[axis] = v
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

// measure_text_range is pass 0 over the nodes [lo, hi): the whole tree
// for the main layout, a section's new nodes for a section pass.
measure_text_range :: proc(lo, hi: int) {
	resize(&g.lay, len(g.nodes))
	for i in lo ..< hi {
		g.lay[i] = Lay{}
	}
	for i in lo ..< hi {
		nd := &g.nodes[i]
		if nd.is_container {
			continue // containers accumulate their content in passes A/D
		}
		s := node_style(i)
		if nd.has_text {
			uw, minw := measure_text(s, nd.spans, nd.spans_hash, nd.text_hash, nd.text, s.wrap)
			g.lay[i].content = uw
			// The Y floor is the content height: text is vertically
			// incompressible (there is no vertical trimming), so a
			// main-axis deficit must never take a text leaf below its
			// lines — with a 0 floor the waterfill's fair-share take
			// crushed header text to nothing before touching the big
			// shrinkable it should have taken from. The X mirror of
			// this is the ellipsis fold inside measure_text.
			g.lay[i].min_c = Vec2{minw, uw.y}
		}
		if nd.image != NO_IMAGE {
			// An image leaf's intrinsic is the image's size; with
			// text present the two overlap-paint (image behind
			// text), so the content is the elementwise max. The
			// image scales freely — it adds no min_c floor.
			if sz, ok := image_intrinsic(nd.image); ok {
				g.lay[i].content.x = max(g.lay[i].content.x, sz.x)
				g.lay[i].content.y = max(g.lay[i].content.y, sz.y)
			}
		}
		for a in 0 ..< 2 {
			if !nd.has_text && s.size[a].kind == .Fixed {
				// A plain leaf's FIXED axis contributes its value, so FIT
				// parents can accumulate it. (A text leaf keeps its
				// intrinsic size: the wrap decision compares it with the
				// box.)
				g.lay[i].content[a] = s.size[a].value
				g.lay[i].min_c[a] = s.size[a].value
			} else {
				// The intrinsic content plus the leaf's padding: text
				// and images sit inside it.
				pad := padding_sum(s, a)
				g.lay[i].content[a] += pad
				g.lay[i].min_c[a] += pad
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

// accumulate is passes A/D over [lo, hi), children before parents.
accumulate :: proc(axis: int, lo, hi: int) {
	for i := hi - 1; i >= lo; i -= 1 {
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
				if g.nodes[c].anchored {
					continue // chrome is not content (§3.20)
				}
				m = max(m, accum_size(c, axis))
				mmin = max(mmin, accum_min(c, axis))
			}
			g.lay[i].content[axis] = m + pad
			g.lay[i].min_c[axis] = mmin + pad
		} else if axis == main_axis(s.layout) {
			total, mtotal := f32(0), f32(0)
			nchild := 0
			for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
				if g.nodes[c].anchored {
					continue // chrome is not content (§3.20)
				}
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
				if g.nodes[c].anchored {
					continue // chrome is not content (§3.20)
				}
				m = max(m, accum_size(c, axis))
				mmin = max(mmin, accum_min(c, axis))
			}
			g.lay[i].content[axis] = m + pad
			g.lay[i].min_c[axis] = mmin + pad
		}
		if scrollable_axis(s, axis) {
			// A scroller's content is not its floor on the scroll axis:
			// the container may shrink to its padding and scroll the
			// rest. Without this, a grow/fit scroller in a bounded
			// parent keeps its full content size and pushes its
			// siblings out — the dual of the FIT-clamp exemption for
			// children OF a scroller (resolve_cross). The content size
			// above stays honest; only the floor drops.
			g.lay[i].min_c[axis] = pad
		}
	}
}

// ---------------------------------------------------------------------------
// Passes B/E: top-down distribution (forward walk)

// parent_scrolls: the parent scrolls on this axis (a Fit child then
// keeps its natural size — it is the scroll extent).
resolve_cross :: proc(c: int, axis: int, inner: f32, parent_scrolls: bool) {
	sz := node_style(c).size[axis]
	switch sz.kind {
	case .Fixed:
		set_size(c, axis, clamp(sz.value, sz.min, sz.max))
	case .Percent:
		set_size(c, axis, clamp(sz.value * inner, sz.min, sz.max))
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
		if !parent_scrolls {
			v = min(v, inner)
		}
		v = max(v, floor_of(c, axis))
		set_size(c, axis, clamp(v, sz.min, sz.max))
	case .Grow:
		set_size(c, axis, clamp(inner, sz.min, sz.max))
	}
}

// Fair-share distribution. O(n^2) worst case here; sort candidates once for
// O(n log n) — same result.
waterfill_give :: proc(cands: []int, axis: int, amount: f32) {
	weight :: proc(c, axis: int) -> f32 {
		return node_style(c).size[axis].weight
	}
	active := cands
	remaining := amount
	for len(active) > 0 {
		total := f32(0)
		for c in active {
			total += weight(c, axis)
		}
		if remaining <= 1e-6 || total <= 0 {
			break
		}
		// Each grower's share is proportional to its weight. A grower
		// whose share would carry it past its ceiling takes only up to
		// the ceiling and leaves; the rest is shared again.
		per := remaining / total
		clamped := false
		for j := len(active) - 1; j >= 0; j -= 1 {
			c := active[j]
			ceil := ceil_of(c, axis)
			if g.lay[c].size[axis] + per * weight(c, axis) >= ceil {
				remaining -= ceil - g.lay[c].size[axis]
				g.lay[c].size[axis] = ceil
				// swap-remove (order is irrelevant to the waterfill)
				active[j] = active[len(active) - 1]
				active = active[:len(active) - 1]
				clamped = true
			}
		}
		if !clamped {
			for c in active {
				g.lay[c].size[axis] += per * weight(c, axis)
			}
			break
		}
	}
}

// waterfill_take shrinks cands fairly toward their floors and returns
// the part of the deficit they could not absorb.
waterfill_take :: proc(cands: []int, axis: int, deficit: f32) -> (left: f32) {
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
				// swap-remove (order is irrelevant to the waterfill)
				active[j] = active[len(active) - 1]
				active = active[:len(active) - 1]
				clamped = true
			}
		}
		if !clamped {
			for c in active {
				g.lay[c].size[axis] -= share
			}
			return 0
		}
	}
	return max(remaining, 0)
}

// shrink_by_priority takes a deficit from the shrinkable children in
// tiers: the lowest Sizing.priority first, fairly within the tier, down
// to its floors, and only what that tier cannot absorb moves on to the
// next. With every priority equal (the default) it is one fair pass.
// Any deficit left after the last tier becomes overflow, recorded in
// pass F.
shrink_by_priority :: proc(cands: []int, axis: int, deficit: f32) {
	prio :: proc(c, axis: int) -> i8 {
		return node_style(c).size[axis].priority
	}
	lo, hi := i8(127), i8(-128)
	for c in cands {
		p := prio(c, axis)
		lo, hi = min(lo, p), max(hi, p)
	}
	if lo == hi {
		waterfill_take(cands, axis, deficit)
		return
	}
	// Insertion sort by priority, lowest first: rows are short.
	for i in 1 ..< len(cands) {
		c := cands[i]
		j := i
		for j > 0 && prio(cands[j - 1], axis) > prio(c, axis) {
			cands[j] = cands[j - 1]
			j -= 1
		}
		cands[j] = c
	}
	left := deficit
	for i := 0; i < len(cands) && left > 1e-6; {
		p := prio(cands[i], axis)
		j := i
		for j < len(cands) && prio(cands[j], axis) == p {
			j += 1
		}
		left = waterfill_take(cands[i:j], axis, left)
		i = j
	}
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
		if g.nodes[c].anchored {
			continue // overlays are not flow (§3.20): distribute
			// resolves them against the inner box directly
		}
		nchild += 1
		sz := node_style(c).size[axis]
		switch sz.kind {
		case .Fixed:
			v := clamp(sz.value, sz.min, sz.max)
			set_size(c, axis, v)
			committed += v
		case .Percent:
			v := clamp(sz.value * inner, sz.min, sz.max)
			set_size(c, axis, v)
			committed += v
		case .Fit:
			v := clamp(g.lay[c].content[axis], sz.min, sz.max)
			set_size(c, axis, v)
			committed += v
			append(shrinkables, c)
		case .Grow:
			if parent_fit {
				// DEVIATION from naive reading: GROW inside FIT is circular
				// (parent sizes to children, child wants parent's leftovers).
				// Documented fallback: behave as FIT.
				v := clamp(g.lay[c].content[axis], sz.min, sz.max)
				set_size(c, axis, v)
				committed += v
				append(shrinkables, c)
			} else {
				v := clamp(g.lay[c].content[axis], sz.min, sz.max)
				set_size(c, axis, v)
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
	if remaining < 0 && !scrollable_axis(s, axis) {
		// Scroll containers skip the take: children keep natural sizes and the
		// excess becomes scrollable overflow. That IS the scroll semantic.
		// The take runs even under parent_fit: FIT only means the container
		// ASKED for its content size — if its own parent shrunk it anyway
		// (the waterfill above us), the deficit passes through to the
		// shrinkable children instead of stranding them at full content
		// size inside a squeezed box (a button's label, say). A FIT
		// container that truly got its content size has remaining == 0
		// here, so this changes nothing for it.
		shrink_by_priority(shrinkables[:], axis, -remaining)
	} else if remaining > 0 && len(growers) > 0 && !parent_fit {
		// The give stays suppressed under FIT: the parent sized itself to
		// the children's content, so there is no leftover to hand out and
		// GROW children were already degraded to FIT above.
		waterfill_give(growers[:], axis, remaining)
	}
	// remaining > 0 with no growers: space stays empty; main-axis alignment
	// at position time handles it.
}

// distribute_node hands container i's children their sizes on axis.
distribute_node :: #force_inline proc(i: int, axis: int) {
	nd := &g.nodes[i]
	if !nd.is_container {
		return
	}
	s := node_style(i)
	inner := g.lay[i].size[axis] - padding_sum(s, axis)
	if inner < 0 {
		inner = 0
	}
	scrolls := scrollable_axis(s, axis)
	// Anchored overlays (§3.20) resolve against the parent's FULL
	// rect on every axis, whatever the layout: padding insets flow
	// content, never overlays (a scrollbar hugs the panel edge).
	if nd.has_anchored {
		for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
			if g.nodes[c].anchored {
				resolve_cross(c, axis, g.lay[i].size[axis], scrolls)
			}
		}
	}
	if s.layout == .Stack {
		// Stack children are excluded from the waterfill: each resolves
		// independently against the full content box.
		for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
			if !g.nodes[c].anchored {
				resolve_cross(c, axis, inner, scrolls)
			}
		}
		return
	}
	if axis == main_axis(s.layout) {
		distribute_main(i, axis, inner)
	} else {
		for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
			if !g.nodes[c].anchored {
				resolve_cross(c, axis, inner, scrolls)
			}
		}
	}
}

// distribute is passes B/E over [lo, hi): roots resolve against the
// viewport, then every container hands its children their sizes,
// parents before children. host >= 0 is a section pass: the host's
// size is already final, and it distributes to its (new) children
// before the range's own containers.
distribute :: proc(axis: int, viewport_extent: f32, host, lo, hi: int) {
	for i in lo ..< hi {
		if g.nodes[i].parent == -1 {
			if g.nodes[i].is_popup {
				g.lay[i].size[axis] = resolve_popup_root(i, axis, viewport_extent)
			} else {
				g.lay[i].size[axis] = resolve_root(i, axis, viewport_extent)
			}
		}
	}
	if host >= 0 {
		distribute_node(host, axis)
	}
	for i in lo ..< hi {
		distribute_node(i, axis)
	}
	// DEVIATION (bug fix vs the doc's pseudocode): the doc appends text nodes to
	// wrap_list inside distribute_main, which also runs for the Y axis — so text
	// under a Top_To_Bottom parent would never wrap (pass C already ran).
	// Wrapping needs the resolved X width, which exists after distribute(X)
	// regardless of parent direction, so collection happens here, on X only.
	if axis == X_AXIS {
		for i in lo ..< hi {
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
		// The text wraps inside the content box: the width less the
		// horizontal padding; the height adds the vertical padding back.
		inner_w := max(0, g.lay[w].size.x - padding_sum(s, X_AXIS))
		lines, line_h := wrapped_lines(s, nd.spans, nd.spans_hash, nd.text_hash, nd.text, inner_w)
		g.lay[w].content.y = f32(lines) * line_h + padding_sum(s, Y_AXIS)
		// Width stays: content.x keeps its unwrapped meaning ("how wide would
		// this want to be"); size.x is the truth the rest of the frame uses.
	}
	clear(&g.wrap_list)
}

// purge_scroll_state drops an instance's scroll records when its
// committed record goes away (lifetime ruled with the
// instances, 2026-11-04).
purge_scroll_state :: proc(id: Instance) {
	if len(g.scroll_off) > 0 {
		delete_key(&g.scroll_off, id)
	}
	if len(g.scroll_max) > 0 {
		delete_key(&g.scroll_max, id)
	}
	if len(g.scroll_glides) > 0 {
		delete_key(&g.scroll_glides, id)
	}
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

// position_range is pass F's positioning over [lo, hi): roots take
// their place, every container places its children (parents before
// children), then overflow closes bottom-up and scroll ranges publish.
// host >= 0 is a section pass: the host re-places its children (the
// new flow content and its chrome) first and closes last. A section
// host met inside a range (the main layout, or an enclosing section)
// places its chrome but does not publish its scroll range: its content
// arrives in its own section pass, and an empty host would clamp the
// stored offset to nothing.
position_range :: proc(host, lo, hi: int) {
	for r in lo ..< hi {
		if g.nodes[r].parent == -1 {
			if g.nodes[r].is_popup {
				g.lay[r].pos = popup_position(r)
			} else {
				g.lay[r].pos = Vec2{0, 0}
			}
		}
	}
	if host >= 0 {
		place_children(host)
	}
	for i in lo ..< hi {
		place_children(i)
	}
	// Overflow, bottom-up: a container's content
	// extent includes each child's own overflow — a grandchild
	// spilling past a non-clipping child extends the grandparent's
	// overflow (and therefore its scroll range). Children sit after
	// their parents in declare order, so this pass runs in reverse:
	// every child's overfl is final before its parent reads it. The
	// scroll-range publish and offset write-back ride along: both
	// consume the final overflow.
	for i := hi - 1; i >= lo; i -= 1 {
		close_overflow(i, !g.nodes[i].is_section)
	}
	if host >= 0 {
		close_overflow(host, true)
	}
}

// place_children positions container i's children (pass F, top-down).
@(private)
place_children :: #force_inline proc(i: int) {
	nd := &g.nodes[i]
	if !nd.is_container {
		return
	}
	s := node_style(i)
	// The live scroll offset: the stored value, clamped per
	// scrollable axis to last frame's range (g.scroll_max — g.lay
	// was zeroed by pass 0, so the range cannot come from there).
	// The fresh range computed below re-clamps it for storage.
	scroll := Vec2{0, 0}
	stored_off, has_off := Vec2{}, false
	if len(g.scroll_off) > 0 {
		stored_off, has_off = g.scroll_off[nd.identity]
	}
	if has_off {
		prev_max := g.scroll_max[nd.identity]
		// An overscroll-enabled scroller (§3.22) renders its
		// offset inside the widened band domain; the spring
		// in scroll_glides owns positions out there.
		allow := s.overscroll ? f32(s.overscroll_px) : f32(0)
		for axis in 0 ..< 2 {
			if scrollable_axis(s, axis) {
				scroll[axis] = clamp(stored_off[axis], -allow, prev_max[axis] + allow)
			}
		}
	}
	base := g.lay[i].pos
	pad := Vec2{f32(s.padding[0]), f32(s.padding[1])}
	axis := main_axis(s.layout) if s.layout != .Stack else X_AXIS
	g.lay[i].scroll = scroll
	cursor := base + pad - scroll
	if s.layout != .Stack {
		// Main-axis alignment: shift the whole row/column in leftover space.
		used := f32(0)
		nchild := 0
		for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
			if g.nodes[c].anchored {
				continue // overlays take no flow slot (§3.20)
			}
			used += g.lay[c].size[axis]
			nchild += 1
		}
		if nchild > 0 {
			used += f32(nchild-1) * f32(s.gap)
		}
		free := (g.lay[i].size[axis] - padding_sum(s, axis)) - used
		cursor[axis] += align_offset(s.align[axis], free)
	}
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
		anchored := g.nodes[c].anchored
		if anchored {
			// Overlay (§3.20): positioned against the parent's
			// FULL rect — its origin plus its align, read per
			// axis [x, y] as for every other child — no padding
			// inset, NO scroll applied, no flow slot consumed.
			p = base + stack_align_offset(s, g.lay[c].size, g.lay[i].size)
		}
		g.lay[c].pos = p
		if s.layout != .Stack && !anchored {
			cursor[axis] += g.lay[c].size[axis] + f32(s.gap)
		}
	}
}

// close_overflow computes container i's overflow from its children's
// final rects (pass F, bottom-up) and, when publish is set, publishes
// its scroll range and re-clamps its stored offset.
@(private)
close_overflow :: #force_inline proc(i: int, publish: bool) {
	nd := &g.nodes[i]
	if !nd.is_container {
		return
	}
	s := node_style(i)
	base := g.lay[i].pos
	pad := Vec2{f32(s.padding[0]), f32(s.padding[1])}
	origin := base + pad
	inner := Vec2{
		g.lay[i].size.x - padding_sum(s, X_AXIS),
		g.lay[i].size.y - padding_sum(s, Y_AXIS),
	}
	max_end := Vec2{0, 0} // pre-scroll content extent
	for c := g.first_child[i]; c != -1; c = g.next_sibling[c] {
		if g.nodes[c].anchored {
			continue // overlays take no flow slot (§3.20)
		}
		ce := g.lay[c].pos + g.lay[i].scroll + g.lay[c].size
		// A clipping child (Overflow.Clip or any scrolling — the
		// Push_Clip predicate) paints nothing past its rect, so its
		// own overflow stays inside it; only a non-clipping child's
		// spill extends this container's extent.
		cs := node_style(c)
		if !(cs.overflow == .Clip || scrollable_axis(cs, X_AXIS) || scrollable_axis(cs, Y_AXIS)) {
			ce += g.lay[c].overfl
		}
		max_end.x = max(max_end.x, ce.x)
		max_end.y = max(max_end.y, ce.y)
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
	// A culled container (a popup not shown) has no laid-out
	// children, so its range here is meaningless.
	if nd.culled || !publish {
		return
	}
	if scrollable_axis(s, X_AXIS) || scrollable_axis(s, Y_AXIS) {
		g.scroll_max[nd.identity] = g.lay[i].overfl
	}
	if len(g.scroll_off) == 0 {
		return
	}
	stored_off, has_off := g.scroll_off[nd.identity]
	if has_off {
		eff := Vec2{0, 0}
		// The stored offset re-clamps to the fresh range — or
		// to the band domain while a spring owns the position
		// (§3.22). An out-of-range offset with no spring (a
		// stale one, say) heals back to the legal range here.
		allow := s.overscroll ? f32(s.overscroll_px) : f32(0)
		gl, has_gl := Scroll_Glide{}, false
		if len(g.scroll_glides) > 0 {
			gl, has_gl = g.scroll_glides[nd.identity]
		}
		for axis in 0 ..< 2 {
			if scrollable_axis(s, axis) {
				// Per axis: the band domain
				// applies to an axis while ITS spring owns it.
				springing := has_gl && gl.active[axis] && gl.axis[axis].spring
				lo := springing ? -allow : f32(0)
				hi := springing ? g.lay[i].overfl[axis] + allow : g.lay[i].overfl[axis]
				eff[axis] = clamp(stored_off[axis], lo, hi)
			}
		}
		g.scroll_off[nd.identity] = eff
	}
}

// pick_clips_and_commit is the rest of pass F, once over the whole tree
// after every section has laid out: pick clips, instance commits,
// damage and the recycle sweep.
@(private)
pick_clips_and_commit :: proc() {
	// Accumulated ancestor clips for the next frame's hit test (input.odin's
	// pick reads them alongside these positions): a node's pick clip is its
	// parent's, intersected with the parent's rect when the parent clips —
	// the same predicate emit uses for Push_Clip (Overflow.Clip, or any
	// scrolling). Positions are final here, parents before children.
	n := len(g.nodes)
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
	// Commit rects + damage: old ∪ new paint rects (node_paint: the rect
	// expanded by overflow, since children painting outside their bounds
	// must be covered, and by a text node's ink pad). §5's rule is "changed → new
	// rect": changed means the committed CONTENT changed, not just the
	// rect — a same-size text edit or a set() restyle damages too. The
	// change model is the stamps (§5): the unit's visual generation
	// (exact — every style write funnels through touch), the node's
	// presented-content digest from declare, and the interaction
	// state stamp from resolve_styles. A live transient damages
	// unconditionally: its blend factor moves every frame without
	// any stamp moving.
	commits := 0 // pass-F commits this frame (presented nodes)
	for i in 0 ..< n {
		nd := &g.nodes[i]
		id := nd.identity
		if nd.culled {
			// Not presented (a popup with no committed anchor, and
			// its subtree): no instance is committed and the node
			// adds no damage of its own — but a node committed last
			// frame has now vanished, so its old rect is damage and
			// its instance, with its scroll state, goes away
			// (rect() reports ok=false, as begin_popup documents).
			if old, ok := g.instances[id]; ok {
				append(&g.damage, old.paint)
				delete_key(&g.instances, id)
				purge_scroll_state(id)
			}
			continue
		}
		new := Rect{g.lay[i].pos, g.lay[i].size}
		ugen := store.units[unit_index(nd.unit)].gen
		stamp := i < len(g.state_stamp) ? g.state_stamp[i] : 0
		tr_now := len(g.transients) > 0 && id in g.transients
		paint := node_paint(i)
		rec := Inst_Rec{rect = new, gen = ugen, digest = nd.digest, stamp = stamp, unit = nd.unit, paint = paint, last_seen = g.frame_index}
		// The one map op per node: an existing record is updated in
		// place through its pointer; a new one is inserted.
		old, ok := &g.instances[id]
		if !ok {
			append(&g.damage, paint)
			g.instances[id] = rec
		} else {
			when NIELLO_DEBUG {
				if nd.static_values {
					assert(old.digest == nd.digest,
						"niello: With.static_values promise broken — a static instance's presented values changed")
				}
			}
			if old.rect != new || old.gen != ugen || old.stamp != stamp ||
			   tr_now || (!nd.static_values && old.digest != nd.digest) {
				// Union of BOTH paint rects: covering only the new
				// one leaves a shrinking spill's (or ink's) old
				// outermost pixels undamaged forever.
				append(&g.damage, rect_union(old.paint, paint))
			}
			// A static_values instance freezes its baseline digest:
			// the promise is for the instance's lifetime, so if
			// detection is ever re-armed (the flag dropped), drift
			// since birth is what it compares against.
			if nd.static_values {
				rec.digest = old.digest
			}
			old^ = rec
		}
		commits += 1
	}
	// Recycle: an instance that was committed before but not declared
	// this frame is gone, and its last rect is damage — otherwise its
	// pixels linger until something unrelated repaints (the form demo's
	// Clear: the placeholder returning with its settle-frame rect+hash
	// looked "unchanged" while the dead text label was never damaged).
	// The trigger is exact arithmetic, not the old map-outgrew-the-tree
	// heuristic: every live instance committed exactly
	// once this frame, so a map larger than the commit count holds a
	// stale record — including the swap case the heuristic missed (a
	// death and a birth in one frame, balanced in the node count by
	// nodes that are not presented). A steady-state frame pays one
	// size comparison.
	if len(g.instances) > commits {
		clear(&g.dead_ids)
		for id, rec in g.instances {
			if rec.last_seen != g.frame_index {
				append(&g.dead_ids, id)
				append(&g.damage, rec.paint)
			}
		}
		for id in g.dead_ids {
			delete_key(&g.instances, id)
			purge_scroll_state(id)
		}
	}
}


// ---------------------------------------------------------------------------

layout_pass :: proc(viewport: Vec2) {
	n := len(g.nodes)
	build_child_lists()
	measure_text_range(0, n) // 0
	accumulate(X_AXIS, 0, n) // A
	distribute(X_AXIS, viewport.x, -1, 0, n) // B
	wrap_text() // C
	accumulate(Y_AXIS, 0, n) // D
	distribute(Y_AXIS, viewport.y, -1, 0, n) // E
	position_range(-1, 0, n) // F: positions
	if len(g.sections) > 0 {
		run_sections(viewport)
		reorder_tree()
	}
	pick_clips_and_commit() // F: commits, damage
}

// ---------------------------------------------------------------------------
// Deferred sections (begin_section)

// run_sections builds every queued section, in queue order, and lays out
// what each build declared inside its host. A build may queue further
// sections (a section inside a section's item); they run after it. The
// new nodes are appended to the node array: tree order is restored by
// reorder_tree once the queue is drained.
@(private)
run_sections :: proc(viewport: Vec2) {
	for k := 0; k < len(g.sections); k += 1 {
		rec := g.sections[k]
		host := rec.host
		lo := len(g.nodes)

		// The build declares into the host, as if inside its block.
		g.section_host = host
		g.section_lo = lo
		append(&g.stack, host)
		open_site_region()
		rec.build(rec.data, section_of(host))
		close_site_region()
		assert(len(g.stack) > 0 && g.stack[len(g.stack) - 1] == host,
			"niello: a section build left a container open")
		pop(&g.stack)
		g.section_host = -1
		hi := len(g.nodes)

		// Lay out the new nodes inside the host, whose size is final.
		resolve_styles_range(lo, hi)
		link_section_range(host, lo, hi)
		measure_text_range(lo, hi)
		accumulate(X_AXIS, lo, hi)
		distribute(X_AXIS, viewport.x, host, lo, hi)
		wrap_text()
		accumulate(Y_AXIS, lo, hi)
		distribute(Y_AXIS, viewport.y, host, lo, hi)
		position_range(host, lo, hi)
	}
}

// section_of reports a host's bounds for its build.
@(private)
section_of :: proc(host: int) -> Section {
	s := node_style(host)
	r := Rect{g.lay[host].pos, g.lay[host].size}
	content := Rect{
		r.pos + Vec2{f32(s.padding[0]), f32(s.padding[1])},
		{max(0, r.size.x - padding_sum(s, X_AXIS)), max(0, r.size.y - padding_sum(s, Y_AXIS))},
	}
	// What can be on screen: the host's rect (it clips its content
	// when it scrolls), narrowed by every clipping ancestor and the
	// window.
	vis := rect_intersect(r, Rect{{0, 0}, g.viewport})
	for p := g.nodes[host].parent; p >= 0; p = g.nodes[p].parent {
		ps := node_style(p)
		if ps.overflow == .Clip || scrollable_axis(ps, X_AXIS) || scrollable_axis(ps, Y_AXIS) {
			vis = rect_intersect(vis, Rect{g.lay[p].pos, g.lay[p].size})
		}
	}
	return Section{
		host = g.nodes[host].identity, unit = g.nodes[host].unit, rect = r, content = content,
		visible = vis, offset = g.lay[host].scroll,
	}
}

// link_section_range threads a section's new nodes [lo, hi) into the
// child lists: the build's top-level children go first in the host's
// list, before the chrome its block declared; everything else links
// under its own parent (in the range) or is a popup root.
@(private)
link_section_range :: proc(host, lo, hi: int) {
	n := len(g.nodes)
	resize(&g.first_child, n)
	resize(&g.next_sibling, n)
	resize(&g.subtree_end, n)
	resize(&g.scratch_ints, n)
	last_child := g.scratch_ints[:]
	for i in lo ..< hi {
		g.first_child[i] = -1
		g.next_sibling[i] = -1
		g.subtree_end[i] = i
		last_child[i] = -1
	}
	head, tail := -1, -1
	for i in lo ..< hi {
		p := g.nodes[i].parent
		if p < 0 {
			continue // a popup root declared in the build
		}
		if p == host {
			if head == -1 {
				head = i
			} else {
				g.next_sibling[tail] = i
			}
			tail = i
			continue
		}
		assert(p >= lo, "niello: a section build declared under a container outside it")
		if g.first_child[p] == -1 {
			g.first_child[p] = i
		} else {
			g.next_sibling[last_child[p]] = i
		}
		last_child[p] = i
	}
	if head != -1 {
		g.next_sibling[tail] = g.first_child[host]
		g.first_child[host] = head
	}
	for i := hi - 1; i >= lo; i -= 1 {
		p := g.nodes[i].parent
		if p >= lo {
			g.subtree_end[p] = max(g.subtree_end[p], g.subtree_end[i])
		}
	}
}

// reorder_tree restores tree order after sections appended their nodes:
// a pre-order walk of the child lists, roots in index order, gives every
// node its new index; the node-indexed arrays are permuted into the
// reorder buffers and swapped in, parents and popup roots remapped, and
// the child lists rebuilt. Everything after layout (pick clips, commit,
// draw_list's contiguous scopes, Tab order, popup and modal ranges, the
// a11y mirror, debug) then sees an ordinary flat tree.
@(private)
reorder_tree :: proc() {
	n := len(g.nodes)
	resize(&g.reorder_new_idx, n)
	order := make([]int, n, context.temp_allocator)
	k := 0
	for r in 0 ..< n {
		if g.nodes[r].parent != -1 {
			continue
		}
		i := r
		for {
			order[k] = i
			g.reorder_new_idx[i] = k
			k += 1
			if g.first_child[i] != -1 {
				i = g.first_child[i]
				continue
			}
			for i != r && g.next_sibling[i] == -1 {
				i = g.nodes[i].parent
			}
			if i == r {
				break
			}
			i = g.next_sibling[i]
		}
	}
	assert(k == n, "niello: reorder_tree did not reach every node")
	resize(&g.reorder_nodes, n)
	resize(&g.reorder_lay, n)
	resize(&g.reorder_eff, n)
	resize(&g.reorder_dis, n)
	resize(&g.reorder_stamp, n)
	for j in 0 ..< n {
		o := order[j]
		nd := g.nodes[o]
		if nd.parent >= 0 {
			nd.parent = g.reorder_new_idx[nd.parent]
		}
		g.reorder_nodes[j] = nd
		g.reorder_lay[j] = g.lay[o]
		if nd.has_eff {
			g.reorder_eff[j] = g.eff[o]
		}
		g.reorder_dis[j] = g.disabled_flags[o]
		g.reorder_stamp[j] = g.state_stamp[o]
	}
	g.nodes, g.reorder_nodes = g.reorder_nodes, g.nodes
	g.lay, g.reorder_lay = g.reorder_lay, g.lay
	g.eff, g.reorder_eff = g.reorder_eff, g.eff
	g.disabled_flags, g.reorder_dis = g.reorder_dis, g.disabled_flags
	g.state_stamp, g.reorder_stamp = g.reorder_stamp, g.state_stamp
	for &rec in g.popups {
		rec.root_idx = g.reorder_new_idx[rec.root_idx]
	}
	build_child_lists()
}

// ---------------------------------------------------------------------------
// Focus reveal (§3.17): keyboard focus scrolls into view

// focus_reveal scrolls the scrollers around a keyboard-focused instance
// just far enough to show it — with the focus ring's margin — after the
// move set g.reveal_id (set_focus_id). It runs at the end of frame_end,
// when this frame's rects are known, innermost scroller first; each
// scroller's move shifts the rect the next one out tests. The offsets
// land next frame (a wake is scheduled), the same lag as a declare-time
// scroll_to; a smooth_scroll scroller glides there like the wheel.
// Pointer focus never reveals: the instance is under the pointer.
@(private)
focus_reveal :: proc() {
	id := g.reveal_id
	if id == 0 {
		return
	}
	g.reveal_id = 0
	if id != g.focus_id {
		return
	}
	idx := -1
	for k in 0 ..< len(g.nodes) {
		if g.nodes[k].identity == id {
			idx = k
			break
		}
	}
	if idx < 0 || g.nodes[idx].culled {
		return
	}
	cfg := store.focus_ring.? or_else DEFAULT_FOCUS_RING
	m := cfg.width > 0 ? max(0, f32(cfg.offset) + f32(cfg.width)) : 0
	target := Rect{g.lay[idx].pos - {m, m}, g.lay[idx].size + {2 * m, 2 * m}}
	moved := false
	child := idx
	for p := g.nodes[idx].parent; p >= 0; child, p = p, g.nodes[p].parent {
		if g.nodes[child].anchored {
			// An anchored child ignores its parent's scroll offset.
			continue
		}
		s := node_style(p)
		if !scrollable_axis(s, X_AXIS) && !scrollable_axis(s, Y_AXIS) {
			continue
		}
		pid := g.nodes[p].identity
		mx := g.scroll_max[pid] or_else Vec2{0, 0}
		off := g.scroll_off[pid] or_else Vec2{0, 0}
		view_pos := g.lay[p].pos + Vec2{f32(s.padding[0]), f32(s.padding[1])}
		view_size := Vec2{max(0, g.lay[p].size.x - padding_sum(s, X_AXIS)), max(0, g.lay[p].size.y - padding_sum(s, Y_AXIS))}
		smooth := s.smooth_scroll && s.smooth_ms > 0
		gl, has_gl := g.scroll_glides[pid]
		delta := Vec2{0, 0}
		for axis in 0 ..< 2 {
			if !scrollable_axis(s, axis) || mx[axis] <= 0 {
				continue
			}
			lo, hi := view_pos[axis], view_pos[axis] + view_size[axis]
			a, b := target.pos[axis], target.pos[axis] + target.size[axis]
			d: f32
			if a < lo || b - a > hi - lo {
				d = a - lo // above, or too big to fit: show its start
			} else if b > hi {
				d = b - hi
			}
			if d == 0 {
				continue
			}
			// The rect sits where off rendered it; a glide in flight
			// keeps moving toward its own target, which the new one
			// replaces.
			to := clamp(off[axis] + d, 0, mx[axis])
			if to == off[axis] {
				continue
			}
			delta[axis] = to - off[axis]
			if smooth {
				gl.axis[axis] = Axis_Glide{from = off[axis], to = to, dur = f32(s.smooth_ms)}
				gl.active[axis] = true
				has_gl = true
			} else {
				if has_gl {
					gl.active[axis] = false
				}
				off[axis] = to
			}
		}
		if delta == {0, 0} {
			continue
		}
		moved = true
		target.pos -= delta
		if !smooth {
			g.scroll_off[pid] = off
		}
		if has_gl {
			if gl.active[0] || gl.active[1] {
				g.scroll_glides[pid] = gl
			} else {
				delete_key(&g.scroll_glides, pid)
			}
		}
	}
	if moved {
		schedule_wake_in(0)
	}
}

// measure_item lays out a section build's top-level child idx on its
// own, now (public measure): its subtree is the run of nodes after it
// whose parents lie inside it (a build's nodes are in declaration
// order). The child is a temporary root inside the host's content box:
// the cross axis resolves by the ordinary cross rules (Grow fills the
// content box), the main axis to its intrinsic size (Fixed, or Percent
// of the content box; Fit and Grow take the content). The section pass
// lays the child out again with the rest of the build, by the same
// rules, so the measured size is the size it gets (Grow on the main
// axis aside: in a host whose content falls short of its box, the final
// layout hands growers the leftover).
@(private)
measure_item :: proc(idx: int, viewport: Vec2) -> Vec2 {
	host := g.section_host
	n := len(g.nodes)
	e := idx + 1
	// A popup declared inside the item is a root (parent -1) in the
	// middle of the run: keep going past it and its subtree.
	for e < n && (g.nodes[e].parent >= idx || g.nodes[e].parent == -1) {
		e += 1
	}
	resolve_styles_range(idx, e)
	link_range(idx, e)
	measure_text_range(idx, e)
	hs := node_style(host)
	inner := Vec2{
		max(0, g.lay[host].size.x - padding_sum(hs, X_AXIS)),
		max(0, g.lay[host].size.y - padding_sum(hs, Y_AXIS)),
	}
	main := hs.layout == .Stack ? -1 : main_axis(hs.layout)
	size_root :: proc(idx, axis, main: int, inner: Vec2, hs: ^Style) {
		if axis != main {
			resolve_cross(idx, axis, inner[axis], scrollable_axis(hs, axis))
			return
		}
		sz := node_style(idx).size[axis]
		v := g.lay[idx].content[axis]
		#partial switch sz.kind {
		case .Fixed:
			v = sz.value
		case .Percent:
			v = sz.value * inner[axis]
		}
		g.lay[idx].size[axis] = clamp(v, sz.min, sz.max)
	}
	accumulate(X_AXIS, idx, e)
	size_root(idx, X_AXIS, main, inner, hs)
	distribute(X_AXIS, viewport.x, -1, idx, e)
	wrap_text()
	accumulate(Y_AXIS, idx, e)
	size_root(idx, Y_AXIS, main, inner, hs)
	distribute(Y_AXIS, viewport.y, -1, idx, e)
	return g.lay[idx].size
}

// link_range builds the child lists of the nodes [lo, hi) among
// themselves (measure_item's private subtree; the section pass links
// the whole build afterwards).
@(private)
link_range :: proc(lo, hi: int) {
	n := len(g.nodes)
	resize(&g.first_child, n)
	resize(&g.next_sibling, n)
	resize(&g.subtree_end, n)
	resize(&g.scratch_ints, n)
	last_child := g.scratch_ints[:]
	for i in lo ..< hi {
		g.first_child[i] = -1
		g.next_sibling[i] = -1
		g.subtree_end[i] = i
		last_child[i] = -1
	}
	for i in lo ..< hi {
		p := g.nodes[i].parent
		if p < lo {
			continue
		}
		if g.first_child[p] == -1 {
			g.first_child[p] = i
		} else {
			g.next_sibling[last_child[p]] = i
		}
		last_child[p] = i
	}
}
