// Headless tests for shrink priority: when a row runs short, lower
// Sizing.priority gives way first; fair share within a tier; floors win.
// Mock metrics: 8 px per byte at the default 16 px, so a 10-letter label
// is 80 wide and its ellipsis floor ("…", 3 bytes) is 24.
package tests

import niello ".."
import "core:testing"

sp_row: niello.Unit
sp_kids: [3]niello.Unit
sp_kid_i: [3]niello.Instance
sp_texts: [3]string
sp_count: int

sp_declare :: proc() {
	if niello.begin(sp_row) {
		for k in 0 ..< sp_count {
			sp_kid_i[k] = niello.show(sp_kids[k], {text = sp_texts[k]})
		}
	}
}

// sp_layout lays out one row of labels and returns their widths.
sp_layout :: proc(row_w: f32, sizes: []niello.Sizing, texts: []string, decls: []niello.Style_Decl = nil, gap: u16 = 0) -> [3]f32 {
	niello.test_reset()
	niello.mint(&sp_row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = niello.size(niello.fixed(row_w), niello.fit()), gap = gap,
	})
	for s, k in sizes {
		d := decls != nil ? decls[k] : niello.Style_Decl{}
		d.size = niello.size(s, niello.fit())
		niello.mint(&sp_kids[k], niello.NO_UNIT, d)
		sp_texts[k] = texts[k]
	}
	sp_count = len(sizes)
	for _ in 0 ..< 2 {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {1000, 400}}, 0.016)
		sp_declare()
		niello.frame_end()
	}
	out: [3]f32
	for k in 0 ..< sp_count {
		r, _ := niello.rect(sp_kid_i[k])
		out[k] = r.size.x
	}
	niello.test_teardown()
	return out
}

TEN :: "abcdefghij" // 80 px

@(test)
test_shrink_priority_low_tier_gives_way_first :: proc(t: ^testing.T) {
	// 3 x 80 in 200: a deficit of 40, all taken from the low tier.
	w := sp_layout(200, {niello.fit(priority = -1), niello.fit(), niello.fit()}, {TEN, TEN, TEN})
	testing.expectf(t, abs(w[0] - 40) < EPS && abs(w[1] - 80) < EPS && abs(w[2] - 80) < EPS,
		"the lower priority absorbs the whole deficit (got %v)", w)
	// Same row, equal priorities: fair share, as before.
	w = sp_layout(200, {niello.fit(), niello.fit(), niello.fit()}, {TEN, TEN, TEN})
	testing.expectf(t, abs(w[0] - w[1]) < EPS && abs(w[1] - w[2]) < EPS, "equal priorities share fairly (got %v)", w)
}

@(test)
test_shrink_priority_floors_win :: proc(t: ^testing.T) {
	// A deficit of 140: the low tier stops at its floor (24), and the
	// rest (84) is shared by the next tier (80 - 42 = 38 each).
	w := sp_layout(100, {niello.fit(priority = -1), niello.fit(), niello.fit()}, {TEN, TEN, TEN})
	testing.expectf(t, abs(w[0] - 24) < EPS, "the low tier stops at its floor (got %v)", w)
	testing.expectf(t, abs(w[1] - 38) < EPS && abs(w[2] - 38) < EPS, "the next tier shares what is left (got %v)", w)
	// Three tiers: the middle one is only touched once the lowest is
	// exhausted, and the top one not at all here.
	w = sp_layout(160, {niello.fit(priority = -2), niello.fit(priority = -1), niello.fit(priority = 3)}, {TEN, TEN, TEN})
	testing.expectf(t, abs(w[0] - 24) < EPS && abs(w[1] - 56) < EPS && abs(w[2] - 80) < EPS,
		"tiers are taken in order (got %v)", w)
}

@(test)
test_shrink_priority_paragraph_beside_button :: proc(t: ^testing.T) {
	// TODO #56: a wrappable paragraph beside a button. With the paragraph
	// at a lower priority the button keeps its full width and the
	// paragraph narrows (and wraps).
	para := "the quick brown fox jumps over the lazy dog and keeps on running"
	decls := []niello.Style_Decl{{wrap = .Word}, {}}
	w := sp_layout(400, {niello.fit(priority = -1), niello.fit()}, {para, "Button"}, decls, gap = 10)
	testing.expectf(t, abs(w[1] - 48) < EPS, "the button keeps its natural width (got %v)", w)
	testing.expectf(t, abs(w[0] - 342) < EPS, "the paragraph takes the rest (got %v)", w)
	// Without priorities both shrink fairly and the button truncates.
	w = sp_layout(400, {niello.fit(), niello.fit()}, {para, "Button"}, decls, gap = 10)
	testing.expectf(t, w[1] < 48, "fair share squeezes the button (got %v)", w)
}

@(test)
test_shrink_priority_applies_to_grow :: proc(t: ^testing.T) {
	// Grow children are shrinkable too: a low-priority grower gives way
	// before a Fit sibling.
	w := sp_layout(120, {niello.grow(priority = -1), niello.fit()}, {TEN, TEN})
	testing.expectf(t, abs(w[0] - 40) < EPS && abs(w[1] - 80) < EPS, "the low-priority grower shrinks first (got %v)", w)
}
