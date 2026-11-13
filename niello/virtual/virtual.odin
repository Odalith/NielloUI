// Package virtual declares only the visible window of a long list, on
// niello's deferred sections (begin_section). It uses nothing but
// niello's public API: a list that needs other rules is written the same
// way (see "Writing your own" below).
//
// Two kinds of list, both driven from a section build:
//
//   - fixed: every item has the same main-axis extent. The window is
//     arithmetic; nothing is measured.
//   - estimated: items differ. Unmeasured items count at an estimate;
//     each declared item is measured on the spot (niello.measure), so the
//     window fills the viewport exactly, and a size learned above the
//     viewport is cancelled with niello.scroll_shift so nothing on screen
//     moves.
//
//	App :: struct { rows: []string, list: virtual.List, list_i: niello.Instance }
//
//	build_rows :: proc(app: ^App, s: niello.Section) {
//		it := virtual.fixed(&app.list, s, len(app.rows), 30)
//		for i in virtual.next(&it) {
//			virtual.item(&it, niello.show(row_u, {text = app.rows[i]}, key = niello.key_int(i)))
//		}
//		virtual.finish(&it)
//	}
//
//	if niello.begin_section(list_u, niello.builder(build_rows, &app), out = &app.list_i) {
//		scrollbar(&app.bar, app.list_i)
//	}
//
// The contract:
//   - The host scrolls on its layout direction (Top_To_Bottom: vertical).
//     Its gap separates items as usual.
//   - Key every item by its index (or a stable id): the window slides, so
//     call-site identity would hand an item's hover, press and focus to
//     whichever item takes its slot.
//   - Hand every declared item to item(), its block closed: it measures
//     it (estimated) and tracks focus.
//   - Items outside the window are not declared: they have no instance,
//     no focus target and no accessibility node. Two things keep a list
//     usable anyway. The window reaches List.overscan items past each edge,
//     so Tab always finds the next item; focus reveal then scrolls to it
//     and the window follows. And the item holding focus stays declared
//     (pinned at its true position) when it is scrolled out of view, so
//     focus survives scrolling.
//
// The space of undeclared items is held by spacers, so the host's scroll
// range is the whole list's extent and its scrollbar is stable.
//
// Writing your own: a build receives the host's exact bounds and scroll
// offset (niello.Section), declares whatever it likes as the host's
// children, can niello.measure what it declared and niello.scroll_shift
// the host to cancel a correction. This package is one such build; a
// grid choosing its column count from s.content would be another.
package virtual

import niello ".."

// DEFAULT_OVERSCAN is the overscan a zero List.overscan means: the items
// declared past each edge of the viewport.
DEFAULT_OVERSCAN :: 2

// List is a virtual list's persistent state, app-owned, one per list.
// The zero value is ready; an estimated list's cache is freed by
// destroy.
List :: struct {
	overscan: int, // items declared past each viewport edge (0: DEFAULT_OVERSCAN)

	pinned:   int, // index + 1 of the item holding focus, 0 none

	// estimated lists: measured main-axis extents (< 0 unmeasured),
	// and a Fenwick tree over each item's slot (extent or estimate,
	// plus the gap).
	sizes:    [dynamic]f32,
	tree:     [dynamic]f32,
	estimate: f32,

	// The last build's configuration, for scroll_to_index.
	count:    int,
	extent:   f32, // fixed lists
	gap:      f32,
	axis:     int,
	fixed:    bool,
}

// destroy frees an estimated list's cache.
destroy :: proc(l: ^List) {
	delete(l.sizes)
	delete(l.tree)
	l.sizes, l.tree = nil, nil
}

// Iter walks one build's window: next yields the item indices to declare,
// in order, and declares the spacers between them.
Iter :: struct {
	list:      ^List,
	host:      niello.Instance,
	count:     int,
	overscan:  int,
	view_lo:   f32, // the viewport along the main axis, in list space
	view_hi:   f32, // (0 = the first item's leading edge)

	first:     int, // the window's first index
	last:      int, // fixed: the window's end; estimated: grows as it fills
	i:         int, // the next window index
	past:      int, // estimated: window items yielded at or past view_hi
	spacers:   int, // spacers declared so far (their keys)
	covered:   int, // items before this index are declared or spaced
	phase:     int, // 0 pinned-before, 1 window, 2 pinned-after, 3 done
	pin_lo:    int, // the pinned run [pin_lo, pin_hi) declared outside
	pin_hi:    int, // the window (empty: none)
	pi:        int, // the next pinned index
	current:   int, // the index last yielded
	anchor:    int, // estimated: the item at the viewport's leading edge
	anchor_at: f32, // its position before this build measured anything
	anchored:  bool,
}

// fixed starts a uniform list's window: count items of main-axis extent
// each.
fixed :: proc(l: ^List, s: niello.Section, count: int, extent: f32) -> Iter {
	setup(l, s, count)
	l.fixed = true
	l.extent = extent
	it := begin_iter(l, s, count)
	slot := extent + l.gap
	if count > 0 && slot > 0 {
		vis_first := clamp(int(it.view_lo / slot), 0, count - 1)
		vis_last := clamp(int(it.view_hi / slot) + 1, 0, count)
		it.first = max(0, vis_first - it.overscan)
		it.last = min(count, vis_last + it.overscan)
	}
	finish_setup(&it)
	return it
}

// estimated starts a list whose items differ: unmeasured items count as
// estimate; declared items are measured by item().
estimated :: proc(l: ^List, s: niello.Section, count: int, estimate: f32) -> Iter {
	setup(l, s, count)
	l.fixed = false
	if estimate != l.estimate || len(l.sizes) != count {
		l.estimate = estimate
		resize_cache(l, count)
	}
	it := begin_iter(l, s, count)
	if count > 0 {
		it.anchor = clamp(index_at(l, it.view_lo), 0, count - 1)
		it.anchor_at = pos(l, it.anchor)
		it.first = max(0, it.anchor - it.overscan)
		it.last = count
	}
	finish_setup(&it)
	return it
}

// next yields the next item index to declare (see the package example).
next :: proc(it: ^Iter) -> (i: int, ok: bool) {
	l := it.list
	for {
		switch it.phase {
		case 0:
			// The pinned run, when it lies wholly before the window.
			if it.pin_hi > it.pin_lo && it.pin_hi < it.first && it.pi < it.pin_hi {
				if it.pi == it.pin_lo {
					spacer(it, it.covered, it.pin_lo)
				}
				i := it.pi
				it.pi += 1
				return yield(it, i)
			}
			it.phase = 1
		case 1:
			if it.i == it.first {
				spacer(it, it.covered, it.first)
			}
			if !l.fixed && !it.anchored && it.i >= it.anchor {
				// Everything before the anchor that this build
				// measured is final now: cancel its change, so the
				// item at the viewport's edge does not move.
				it.anchored = true
				if it.count > 0 {
					d := pos(l, it.anchor) - it.anchor_at
					if d != 0 {
						delta: niello.Vec2
						delta[l.axis] = d
						niello.scroll_shift(it.host, delta)
						it.view_lo += d
						it.view_hi += d
					}
				}
			}
			if window_continues(it) {
				i := it.i
				it.i += 1
				if !l.fixed && pos(l, i) >= it.view_hi {
					it.past += 1
				}
				return yield(it, i)
			}
			it.phase = 2
		case 2:
			// The pinned run, or what the window did not reach of it.
			if it.pin_hi > it.covered {
				start := max(it.pin_lo, it.covered)
				spacer(it, it.covered, start)
				return yield(it, start)
			}
			it.phase = 3
		case:
			return 0, false
		}
	}
}

// item hands item() the instance just declared for the index next
// yielded, its block closed: an estimated list measures it, and focus is
// tracked for pinning.
item :: proc(it: ^Iter, inst: niello.Instance) {
	l := it.list
	i := it.current
	if niello.focused(inst) {
		l.pinned = i + 1
	} else if l.pinned == i + 1 {
		l.pinned = 0
	}
	if !l.fixed {
		sz := niello.measure(inst)
		set_size(l, i, sz[l.axis])
	}
}

// finish declares the space after the last declared item.
finish :: proc(it: ^Iter) {
	spacer(it, it.covered, it.count)
	if it.list.pinned > it.count {
		it.list.pinned = 0
	}
}

// scroll_to_index scrolls host so item i's leading edge sits at the
// viewport's leading edge, by the list's last build (estimated lists:
// at the current best estimate).
scroll_to_index :: proc(l: ^List, host: niello.Instance, i: int) {
	if l.count == 0 {
		return
	}
	off := niello.scroll_offset(host)
	off[l.axis] = pos(l, clamp(i, 0, l.count - 1))
	niello.scroll_to(host, off)
}

// item_pos is item i's leading edge along the list (0 = the first item's).
item_pos :: proc(l: ^List, i: int) -> f32 {
	return pos(l, i)
}

// ---- internals ----------------------------------------------------------

@(private)
setup :: proc(l: ^List, s: niello.Section, count: int) {
	st := niello.style_of(s.unit)
	l.axis = st.layout == .Left_To_Right ? 0 : 1
	if l.gap != f32(st.gap) {
		l.gap = f32(st.gap)
		if !l.fixed && len(l.tree) > 0 {
			rebuild_tree(l)
		}
	}
	l.count = count
}

@(private)
begin_iter :: proc(l: ^List, s: niello.Section, count: int) -> Iter {
	a := l.axis
	it := Iter{list = l, host = s.host, count = count, current = -1}
	it.overscan = l.overscan > 0 ? l.overscan : DEFAULT_OVERSCAN
	// List space: the content box's leading edge, scrolled.
	it.view_lo = s.visible.pos[a] - s.content.pos[a] + s.offset[a]
	it.view_hi = it.view_lo + s.visible.size[a]
	return it
}

@(private)
finish_setup :: proc(it: ^Iter) {
	l := it.list
	if l.pinned > 0 {
		p := l.pinned - 1
		if p >= it.count {
			l.pinned = 0
		} else {
			// The focused item and a neighbor each side: Tab and
			// Shift+Tab from it reach its neighbors (and reveal brings
			// the list back to them), not the far-away window.
			lo, hi := max(0, p - 1), min(it.count, p + 2)
			if hi >= it.first && (!l.fixed || lo <= it.last) && lo < it.first {
				it.first = lo // touches the window from before: one run
			}
			if l.fixed && lo <= it.last && hi >= it.first {
				it.first = min(it.first, lo)
				it.last = max(it.last, hi) // inside or touching: merged
			} else {
				it.pin_lo, it.pin_hi = lo, hi
				it.pi = lo
			}
		}
	}
	it.i = it.first
}

@(private)
window_continues :: proc(it: ^Iter) -> bool {
	l := it.list
	if it.i >= it.count {
		return false
	}
	if l.fixed {
		return it.i < it.last
	}
	// Every item that starts inside the viewport, then overscan more.
	return pos(l, it.i) < it.view_hi || it.past < it.overscan
}

@(private)
yield :: proc(it: ^Iter, i: int) -> (int, bool) {
	it.current = i
	it.covered = i + 1
	return i, true
}

// spacer declares the extent of items [a, b), if any.
@(private)
spacer :: proc(it: ^Iter, a, b: int) {
	l := it.list
	if b <= a {
		return
	}
	ext := pos(l, b) - pos(l, a) - l.gap
	sz := niello.size(niello.fixed(0), niello.fixed(max(0, ext)))
	if l.axis == 0 {
		sz = niello.size(niello.fixed(max(0, ext)), niello.fixed(0))
	}
	// Keyed by role (the build's first, second, third spacer), not by
	// index: the window slides every scroll step, and the spacers keep
	// their instances.
	niello.show(spacer_unit(), {size = sz}, key = niello.key_int(SPACER_KEY + it.spacers))
	it.spacers += 1
	it.covered = b
}

// Spacer keys sit far from item indices (key_int(i)) so the two never
// meet.
@(private)
SPACER_KEY :: 0x5ace_0000_0000_0000

@(private)
spacer_u: niello.Unit

@(private)
spacer_unit :: proc() -> niello.Unit {
	if !niello.unit_live(spacer_u) {
		niello.mint(&spacer_u, niello.NO_UNIT, {})
	}
	return spacer_u
}

// slot_of is item i's extent plus the gap after it.
@(private)
slot_of :: proc(l: ^List, i: int) -> f32 {
	if l.fixed {
		return l.extent + l.gap
	}
	sz := l.sizes[i]
	if sz < 0 {
		sz = l.estimate
	}
	return sz + l.gap
}

// pos is item i's leading edge: the slots before it.
@(private)
pos :: proc(l: ^List, i: int) -> f32 {
	if l.fixed {
		return f32(i) * (l.extent + l.gap)
	}
	return prefix(l, i)
}

// index_at is the item whose slot holds list position y.
@(private)
index_at :: proc(l: ^List, y: f32) -> int {
	if l.fixed {
		slot := l.extent + l.gap
		return slot > 0 ? int(y / slot) : 0
	}
	// Fenwick descent: the largest k with prefix(k) <= y.
	n := len(l.tree) - 1
	k := 0
	rem := y
	step := 1
	for step * 2 <= n {
		step *= 2
	}
	for ; step > 0; step /= 2 {
		if k + step <= n && l.tree[k + step] <= rem {
			k += step
			rem -= l.tree[k]
		}
	}
	return min(k, max(0, l.count - 1))
}

// ---- the estimated cache: a Fenwick tree over slots ----

@(private)
resize_cache :: proc(l: ^List, count: int) {
	old := len(l.sizes)
	resize(&l.sizes, count)
	for i in old ..< count {
		l.sizes[i] = -1
	}
	rebuild_tree(l)
}

@(private)
rebuild_tree :: proc(l: ^List) {
	n := len(l.sizes)
	resize(&l.tree, n + 1)
	l.tree[0] = 0
	for i in 0 ..< n {
		l.tree[i + 1] = slot_of(l, i)
	}
	for i in 1 ..= n {
		j := i + (i & -i)
		if j <= n {
			l.tree[j] += l.tree[i]
		}
	}
}

@(private)
set_size :: proc(l: ^List, i: int, sz: f32) {
	before := slot_of(l, i)
	l.sizes[i] = sz
	d := slot_of(l, i) - before
	if d == 0 {
		return
	}
	n := len(l.tree) - 1
	for j := i + 1; j <= n; j += j & -j {
		l.tree[j] += d
	}
}

@(private)
prefix :: proc(l: ^List, i: int) -> f32 {
	t := f32(0)
	for j := min(i, len(l.tree) - 1); j > 0; j -= j & -j {
		t += l.tree[j]
	}
	return t
}

// ---- keeping an estimated cache aligned with the data ----

// invalidate forgets item i's measured size (its content changed); it
// is measured again the next time it is declared.
invalidate :: proc(l: ^List, i: int) {
	if i >= 0 && i < len(l.sizes) {
		set_size(l, i, -1)
	}
}

// insert makes room for n new items at index at (measured sizes move
// with their items).
insert :: proc(l: ^List, at, n: int) {
	if n <= 0 {
		return
	}
	at := clamp(at, 0, len(l.sizes))
	old := len(l.sizes)
	resize(&l.sizes, old + n)
	copy(l.sizes[at + n:], l.sizes[at:old])
	for k in at ..< at + n {
		l.sizes[k] = -1
	}
	if l.pinned > at {
		l.pinned += n
	}
	l.count = len(l.sizes)
	rebuild_tree(l)
}

// remove drops n items at index at.
remove :: proc(l: ^List, at, n: int) {
	if n <= 0 || at < 0 || at >= len(l.sizes) {
		return
	}
	n := min(n, len(l.sizes) - at)
	copy(l.sizes[at:], l.sizes[at + n:])
	resize(&l.sizes, len(l.sizes) - n)
	if l.pinned > at + n {
		l.pinned -= n
	} else if l.pinned > at {
		l.pinned = 0
	}
	l.count = len(l.sizes)
	rebuild_tree(l)
}
