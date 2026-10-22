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
// Popups (§3.19)

// popup_containing returns the index into g.popups of the popup
// whose subtree holds node idx, or -1. Popup subtrees are disjoint
// node ranges (overlay roots are siblings in the array), so at
// most one matches. Reads the tree g.popups was recorded against —
// at dispatch time, last frame's.
@(private)
popup_containing :: proc(idx: int) -> int {
	if idx < 0 {
		return -1
	}
	for rec, k in g.popups {
		if idx >= rec.root_idx && idx <= g.subtree_end[rec.root_idx] {
			return k
		}
	}
	return -1
}

// topmost_modal returns the g.popups index of the highest modal
// popup, or -1.
@(private)
topmost_modal :: proc() -> int {
	for k := len(g.popups) - 1; k >= 0; k -= 1 {
		if g.popups[k].modal {
			return k
		}
	}
	return -1
}

// flag_dismiss records a dismissal request for one popup root; the
// app reads it back with dismiss_requested during this declare.
@(private)
flag_dismiss :: proc(rec_idx: int) {
	if g.dismiss_flags == nil {
		g.dismiss_flags = make(map[Instance]bool)
	}
	g.dismiss_flags[g.popups[rec_idx].id] = true
}

// ---------------------------------------------------------------------------
// Keyboard focus (§3.17)

// set_focus_id is the one focus writer: it notes the transition for
// damage and cancels any pending key-press capture (a Space/Enter
// press belongs to the instance that held focus when it began).
@(private)
set_focus_id :: proc(i: Instance) {
	if i == g.focus_id {
		return
	}
	note_affected(g.focus_id)
	g.focus_id = i
	note_affected(i)
	if g.key_press_id != 0 && g.key_press_id != i {
		note_affected(g.key_press_id)
		g.key_press_id = 0
		clear(&g.key_press_chain)
	}
}

// focus_candidate: can this node of the last completed tree hold
// focus right now? Focusable (resolved at declare), not culled, not
// effectively disabled (last frame's flags, node-indexed like the
// tree they describe).
@(private)
focus_candidate :: proc(idx: int) -> bool {
	nd := &g.nodes[idx]
	if nd.culled || !nd.focusable {
		return false
	}
	if idx < len(g.disabled_flags) && g.disabled_flags[idx] {
		return false
	}
	return true
}

// traverse_focus moves focus one step along the tab order:
// declaration order (the node array IS declaration order) over the
// focusable instances of the last completed tree, wrapping at the
// ends. From no focus, forward lands on the first candidate and
// reverse on the last. No candidates: focus is left alone. While a
// modal popup is open (§3.19) the walk is scoped to its subtree —
// the range restriction the flat array makes trivial.
@(private)
traverse_focus :: proc(dir: int) {
	n := len(g.nodes)
	if n == 0 {
		return
	}
	lo, hi := 0, n - 1
	if mk := topmost_modal(); mk >= 0 {
		lo = g.popups[mk].root_idx
		hi = g.subtree_end[lo]
	}
	span := hi - lo + 1
	cur := -1
	for i in lo ..= hi {
		if g.nodes[i].identity == g.focus_id {
			cur = i
			break
		}
	}
	origin := cur
	if origin < 0 {
		origin = dir > 0 ? lo - 1 : hi + 1
	}
	for step in 1 ..= span {
		idx := lo + (origin - lo + dir * step) %% span
		if focus_candidate(idx) {
			set_focus_id(g.nodes[idx].identity)
			return
		}
	}
}

// key_press_target: can the focused instance take a key press?
// Weaker than focus_candidate on purpose: focusable gates
// traversal, not focus itself — a programmatically focused instance
// activates too. Only absence and disabled (which absorbs) refuse.
@(private)
key_press_target :: proc(idx: int) -> bool {
	if g.nodes[idx].culled {
		return false
	}
	if idx < len(g.disabled_flags) && g.disabled_flags[idx] {
		return false
	}
	return true
}

// key_press_begin starts a Space/Enter capture on the focused
// instance: its press overlay shows (the chain snapshot feeds
// resolve_styles and pressed()) until the key comes up.
@(private)
key_press_begin :: proc(code: u32) {
	if g.focus_id == 0 || g.key_press_id != 0 {
		return
	}
	for idx in 0 ..< len(g.nodes) {
		if g.nodes[idx].identity != g.focus_id {
			continue
		}
		if !key_press_target(idx) {
			return
		}
		g.key_press_id = g.focus_id
		g.key_press_code = code
		clear(&g.key_press_chain)
		depth := 0
		for c := idx; c != -1; c = g.nodes[c].parent {
			depth += 1
		}
		resize(&g.key_press_chain, depth)
		k := depth - 1
		for c := idx; c != -1; c = g.nodes[c].parent {
			g.key_press_chain[k] = g.nodes[c].identity
			k -= 1
		}
		note_affected(g.key_press_id)
		return
	}
}

// key_press_end completes a capture: the click fires (for exactly
// one declare, like a pointer click) only if focus never moved and
// the target is still a live candidate.
@(private)
key_press_end :: proc(code: u32) {
	if g.key_press_id == 0 || code != g.key_press_code {
		return
	}
	id := g.key_press_id
	note_affected(id)
	g.key_press_id = 0
	if g.focus_id == id {
		for idx in 0 ..< len(g.nodes) {
			if g.nodes[idx].identity == id && key_press_target(idx) {
				g.clicked_id = id
				clear(&g.clicked_chain)
				append(&g.clicked_chain, ..g.key_press_chain[:])
				break
			}
		}
	}
	clear(&g.key_press_chain)
}

// dispatch_keys snapshots the frame's keyboard input and runs the
// core's own key semantics: traversal and activation. Routing
// targets freeze here — a declare-time focus() call does not
// retro-route this frame's keys or text.
@(private)
dispatch_keys :: proc(input: Input) {
	g.frame_key_count = min(input.key_count, 16)
	for k in 0 ..< g.frame_key_count {
		g.frame_keys[k] = input.keys[k]
	}
	g.key_consumed = {}
	clear(&g.frame_text)
	if len(input.text) > 0 {
		bytes := transmute([]u8)input.text
		append(&g.frame_text, ..bytes)
	}

	if !input.window_focused {
		// No key semantics without window focus (the host delivers
		// none anyway), and a held key-press cannot complete across
		// the loss.
		if g.key_press_id != 0 {
			note_affected(g.key_press_id)
			g.key_press_id = 0
			clear(&g.key_press_chain)
		}
		g.keys_target = 0
		g.text_target = 0
		return
	}

	for k in 0 ..< g.frame_key_count {
		ev := g.frame_keys[k]
		if ev.scancode == SCANCODE_ESCAPE && ev.down && !ev.repeat {
			// Esc light-dismisses the topmost dismissible popup
			// (§3.19) and is consumed, like Tab; with no popup to
			// dismiss it routes to the focused instance normally.
			consumed := false
			for j := len(g.popups) - 1; j >= 0; j -= 1 {
				if !g.popups[j].stay {
					flag_dismiss(j)
					consumed = true
					break
				}
			}
			if consumed {
				g.key_consumed[k] = true
				continue
			}
		}
		if ev.scancode == SCANCODE_TAB && ev.down {
			// Traversal consumes Tab outright (repeats included:
			// holding Tab keeps cycling, as everywhere else).
			g.key_consumed[k] = true
			traverse_focus((ev.mods & MOD_SHIFT) != 0 ? -1 : 1)
			continue
		}
		if ev.scancode == SCANCODE_SPACE || ev.scancode == SCANCODE_RETURN ||
		   ev.scancode == SCANCODE_KP_ENTER {
			if ev.down && !ev.repeat {
				key_press_begin(ev.scancode)
			} else if !ev.down {
				key_press_end(ev.scancode)
			}
		}
	}
	g.keys_target = g.focus_id
	g.text_target = g.focus_id
}

// ---------------------------------------------------------------------------
// Dispatch (frame_begin, before the frame store is cleared)

// dispatch_input converts one frame of host input into interaction state.
// It reads last frame's nodes/lay/pick_clip exactly as frame_end left them.
@(private)
dispatch_input :: proc(input: Input, dt: f32) {
	g.pointer_pos = input.mouse
	g.pointer_valid = input.mouse_valid
	// clicked answers for exactly one declare: the one following the
	// dispatch that produced it. Consumed or not, it ends here.
	g.clicked_id = 0
	clear(&g.clicked_chain)
	clear(&g.affected)
	// Dismissal requests (§3.19) live for one declare, like clicks.
	if g.dismiss_flags != nil {
		clear(&g.dismiss_flags)
	}

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

	// Keyboard dispatch runs even when the cursor has left the
	// window: keys belong to the window's focus, not the pointer.
	dispatch_keys(input)

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

	// Popup rules (§3.19), against last frame's popup list:
	//   - A modal popup makes its subtree the whole press surface:
	//     a pick outside it is absorbed exactly like a disabled hit
	//     (no hover, no press, no focus change, no wheel) — and,
	//     unless the modal stays, the press also light-dismisses
	//     the modal itself: absorbed AND flagged, so a backdrop
	//     click cancels without ever reaching what is underneath.
	//     A press inside a popup above the modal (a menu the modal
	//     opened) follows the ordinary chain rule below.
	//   - Otherwise a left press light-dismisses: inside popup k it
	//     flags every dismissible popup above k (a submenu chain
	//     collapses toward the press); outside all popups it flags
	//     the topmost dismissible one and CONSUMES the press, so
	//     closing a menu never clicks what was underneath it.
	press_consumed := false
	if len(g.popups) > 0 {
		if mk := topmost_modal(); mk >= 0 {
			cont := popup_containing(pick)
			if cont > mk {
				if .Left in input.buttons_pressed {
					for j := len(g.popups) - 1; j > cont; j -= 1 {
						if !g.popups[j].stay {
							flag_dismiss(j)
						}
					}
				}
			} else if cont != mk {
				if .Left in input.buttons_pressed && !g.popups[mk].stay {
					flag_dismiss(mk)
				}
				pick = -1
				clear(&chain_idx)
				hover_len = 0
				blocked = true
			}
		} else if .Left in input.buttons_pressed {
			if k := popup_containing(pick); k >= 0 {
				for j := len(g.popups) - 1; j > k; j -= 1 {
					if !g.popups[j].stay {
						flag_dismiss(j)
					}
				}
			} else {
				for j := len(g.popups) - 1; j >= 0; j -= 1 {
					if !g.popups[j].stay {
						flag_dismiss(j)
						press_consumed = true
						break
					}
				}
			}
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

	// Click-to-focus: a left press focuses the deepest focusable
	// instance on the pick's chain (a label inside a button focuses
	// the button). No focusable on the chain — the press landed on
	// unfocusable ground and focus clears, like clicking out of a
	// text field anywhere else. (First cut left focus in place; in
	// use that read as focus getting stuck, so the rule flipped —
	// §3.17.) A blocked press is absorbed before any of this.
	if .Left in input.buttons_pressed && pick >= 0 && !blocked && !press_consumed {
		found := false
		for j := len(chain_idx) - 1; j >= 0; j -= 1 {
			if focus_candidate(chain_idx[j]) {
				set_focus_id(g.nodes[chain_idx[j]].identity)
				found = true
				break
			}
		}
		if !found {
			set_focus_id(0)
		}
	}

	// Press capture and click completion, per button.
	for b in Mouse_Button {
		if b in input.buttons_pressed && pick >= 0 && !blocked &&
		   !(press_consumed && b == .Left) {
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
			range_ := g.scroll_max[id][axis]
			// Accumulation base: a wheel glide's TARGET (where the
			// scroll is heading — §3.21), but the RENDERED offset
			// while an overscroll spring is in flight: a spring's
			// target is the range end, which is not where the
			// gesture is (§3.22).
			target := off[axis]
			if gl, ok := g.scroll_glides[id]; ok && !gl.spring {
				target = gl.to[axis]
			}
			raw := target + rem
			banded := false
			if s.overscroll && s.overscroll_px > 0 && (raw > range_ || raw < 0) {
				// The band: convert through the resistance curve
				// in RAW space (past-the-end distance before
				// resistance), so continued wheeling deepens the
				// pull smoothly and the displayed overshoot
				// asymptotes at overscroll_px.
				allow := f32(s.overscroll_px)
				raw_pos := target
				if target > range_ {
					raw_pos = range_ + overscroll_raw(target - range_, allow)
				} else if target < 0 {
					raw_pos = -overscroll_raw(-target, allow)
				}
				raw = raw_pos + rem
				disp := raw
				if raw > range_ {
					disp = range_ + overscroll_resist(raw - range_, allow)
				} else if raw < 0 {
					disp = -overscroll_resist(-raw, allow)
				}
				if disp > range_ || disp < 0 {
					// The gesture went into the band: this
					// container consumes the whole remainder,
					// lands on the resisted position instantly,
					// and springs back to the violated end.
					apply_overscroll(id, off, axis, disp, s)
					banded = true
					rem = 0
				} else {
					raw = disp // pulled back inside: normal path
				}
			}
			if !banded {
				clamped := clamp(raw, 0, range_)
				used := clamped - target
				if used != 0 {
					if s.smooth_scroll && s.smooth_ms > 0 {
						if g.scroll_glides == nil {
							g.scroll_glides = make(map[Instance]Scroll_Glide)
						}
						gl := g.scroll_glides[id]
						gl.from = off
						gl.to = off
						gl.to[axis] = clamped
						gl.t = 0
						gl.dur = f32(s.smooth_ms)
						gl.spring = false
						g.scroll_glides[id] = gl
					} else {
						// A direct landing kills any spring in
						// flight on this scroller.
						if g.scroll_glides != nil {
							delete_key(&g.scroll_glides, id)
						}
						off[axis] = clamped
						g.scroll_off[id] = off
					}
				}
				rem -= used
			}
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
		if !prs && chain_contains(g.key_press_chain[:], id) {
			prs = true
		}
		foc := g.focus_id != 0 && id == g.focus_id
		has_tr := false
		if len(g.transients) > 0 {
			_, has_tr = g.transients[id]
		}
		if !hov && !prs && !foc && !dis && nd.with.variant == NO_UNIT && !has_tr {
			continue
		}
		rec := &store.units[int(nd.unit)]
		eff := rec.style
		apply_overlay(&eff, nd.with.variant) // persistent per-instance overlay
		if foc { apply_overlay(&eff, rec.focus) }
		if hov { apply_overlay(&eff, rec.hover) }
		if prs { apply_overlay(&eff, rec.press) }
		if dis { apply_overlay(&eff, rec.disabled) }
		if has_tr { apply_transient(&eff, id) } // the pulse rides on top (§3.16)
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
	rec := &store.units[int(overlay)]
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
	case .Whitespace:    dst.whitespace    = src.whitespace
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
	case .Smooth_Scroll: dst.smooth_scroll = src.smooth_scroll
	case .Smooth_Ms: dst.smooth_ms = src.smooth_ms
	case .Overscroll: dst.overscroll = src.overscroll
	case .Overscroll_Px: dst.overscroll_px = src.overscroll_px
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
				rec := &store.units[int(g.nodes[i].unit)]
				if rec.disabled != NO_UNIT {
					drec := &store.units[int(rec.disabled)]
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

// step_scroll_glides advances every wheel glide by this frame's dt,
// writing the eased offset scroll_off holds (pass F renders it like
// any other offset). Runs at frame_end after step_tweens, before
// layout. A completed glide lands exactly on its target and removes
// itself; update_animation_wake keeps frames coming while any exist.
@(private)
step_scroll_glides :: proc() {
	if len(g.scroll_glides) == 0 {
		return
	}
	if g.scroll_off == nil {
		g.scroll_off = make(map[Instance]Vec2)
	}
	done: [dynamic]Instance
	defer delete(done)
	for id, &gl in g.scroll_glides {
		gl.t += g.dt * 1000
		eff := gl.t - gl.delay
		if eff < 0 {
			// Holding (a spring's quiet window): the offset stays
			// exactly at `from`; the glide outlives the window or
			// a fresh tick re-arms it.
			g.scroll_off[id] = gl.from
			continue
		}
		p := gl.dur <= 0 ? f32(1) : min(eff / gl.dur, 1)
		e := ease_out_cubic(p)
		// Re-clamp the target against the live range every step:
		// content may have shrunk since the tick that set it.
		to := gl.to
		if mx, ok := g.scroll_max[id]; ok {
			to.x = clamp(to.x, 0, mx.x)
			to.y = clamp(to.y, 0, mx.y)
		}
		g.scroll_off[id] = gl.from + (to - gl.from) * e
		if p >= 1 {
			g.scroll_off[id] = to
			append(&done, id)
		}
	}
	for id in done {
		delete_key(&g.scroll_glides, id)
	}
}

// ---------------------------------------------------------------------------
// Overscroll (§3.22)

// overscroll_resist maps a raw past-the-end distance to the displayed
// overshoot: resist(r) = allow*r/(allow+r) — 1:1 at the end itself,
// asymptoting at the configured max distance.
@(private)
overscroll_resist :: proc(raw, allow: f32) -> f32 {
	if raw <= 0 {
		return 0
	}
	return allow * raw / (allow + raw)
}

// overscroll_raw inverts resist, recovering the raw distance a
// displayed overshoot accumulated from (so the next tick adds onto the
// pull, not onto the compressed display value). The inverse explodes
// near the asymptote; cap it — past that, more wheel changes nothing
// visible anyway.
@(private)
overscroll_raw :: proc(disp, allow: f32) -> f32 {
	if disp <= 0 {
		return 0
	}
	if disp >= allow * 0.99 {
		return 4 * allow
	}
	return allow * disp / (allow - disp)
}

// OVERSCROLL_QUIET_MS: the spring holds the banded position until
// the wheel has been quiet this long. Without the hold, slow ticking
// at the end restarted the spring on every tick and the offset
// sawtoothed — out on the tick, partway back, out again (his bug
// report, 2026-10-21). A gesture is a stream; the spring belongs to
// its end, not to each tick. 250ms bridges slow notch gaps.
OVERSCROLL_QUIET_MS :: f32(250)

// apply_overscroll lands the offset on the resisted position NOW (the
// band is direct manipulation, even on a smoothing scroller) and arms
// the spring: a glide back to the violated range end, timed by
// smooth_ms, starting once the wheel goes quiet (each banded tick
// re-arms it). The other axis keeps any wheel-glide target it had.
@(private)
apply_overscroll :: proc(id: Instance, off: Vec2, axis: int, disp: f32, s: ^Style) {
	if g.scroll_glides == nil {
		g.scroll_glides = make(map[Instance]Scroll_Glide)
	}
	from := off
	from[axis] = disp
	to := off
	to[axis] = clamp(disp, 0, g.scroll_max[id][axis])
	if gl, ok := g.scroll_glides[id]; ok && !gl.spring {
		to[1 - axis] = gl.to[1 - axis]
	}
	g.scroll_glides[id] = Scroll_Glide{
		from = from, to = to, t = 0,
		dur = f32(s.smooth_ms), spring = true,
		delay = OVERSCROLL_QUIET_MS,
	}
	g.scroll_off[id] = from
}
