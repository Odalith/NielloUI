// layout_test.odin — white-box tests for the layout engine.
// Mock font metrics: every char is 8px wide, lines are 16px tall.
// Run: odin test tests -define:ODIN_TEST_THREADS=1
package tests

import niello ".."

import "core:fmt"
import "core:testing"
import "core:time"

EPS :: 0.01

expect_rect :: proc(t: ^testing.T, inst: niello.Instance, want: niello.Rect, loc := #caller_location) {
	r, ok := niello.rect(inst)
	testing.expect(t, ok, "instance has no committed niello.rect", loc = loc)
	if !ok {
		return
	}
	good :=
		abs(r.pos.x - want.pos.x) < EPS &&
		abs(r.pos.y - want.pos.y) < EPS &&
		abs(r.size.x - want.size.x) < EPS &&
		abs(r.size.y - want.size.y) < EPS
	testing.expect(t, good, fmt.tprintf("want %v, got %v", want, r), loc = loc)
}

// ---------------------------------------------------------------------------
// The lab rat: window 800x600 (TTB) > toolbar (LTR, pad 8, gap 4) >
// open FIXED 60x24, save GROW x / FIXED 28, title FIT text "Notes" (5ch = 40px).
// Toolbar content.x = 16 + (60+0+40) + 8 = 124; inner = 784; save = 676.

@(test)
test_toolbar_layout :: proc(t: ^testing.T) {
	niello.test_reset()
	window: niello.Unit
	niello.mint(&window, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	toolbar: niello.Unit
	niello.mint(&toolbar, niello.NO_UNIT, {layout = .Left_To_Right, size = niello.Size{niello.grow(), niello.fit()}, padding = [4]u16{8, 8, 8, 8}, gap = 4})
	open_b: niello.Unit
	niello.mint(&open_b, niello.NO_UNIT, {size = niello.Size{niello.fixed(60), niello.fixed(24)}})
	save_b: niello.Unit
	niello.mint(&save_b, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(28)}})
	title: niello.Unit
	niello.mint(&title, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})

	i_win, i_tb, i_open, i_save, i_title: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if w, ok := niello.begin(window); ok {
		i_win = w
		if tb, ok2 := niello.begin(toolbar); ok2 {
			i_tb = tb
			i_open = niello.show(open_b)
			i_save = niello.show(save_b)
			i_title = niello.show(title, 0, niello.With{text = "Notes"})
		}
	}
	niello.frame_end()

	expect_rect(t, i_win, niello.Rect{{0, 0}, {800, 600}})
	expect_rect(t, i_tb, niello.Rect{{0, 0}, {800, 44}})
	expect_rect(t, i_open, niello.Rect{{8, 8}, {60, 24}})
	expect_rect(t, i_save, niello.Rect{{72, 8}, {676, 28}})
	expect_rect(t, i_title, niello.Rect{{752, 8}, {40, 16}})
}

// ---------------------------------------------------------------------------
// Waterfill with ceilings: inner 600, gap 10 ->
// A FIXED 200, B GROW max 150, C GROW  =>  200 / 150 / 230.

@(test)
test_waterfill_ceilings :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(600), niello.fit()}, gap = 10})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(20)}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.grow(0, 150), niello.fixed(20)}})
	c: niello.Unit
	niello.mint(&c, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(20)}})

	ia, ib, ic: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		if _, ok2 := niello.begin(row); ok2 {
			ia = niello.show(a)
			ib = niello.show(b)
			ic = niello.show(c)
		}
	}
	niello.frame_end()

	ra, _ := niello.rect(ia)
	rb, _ := niello.rect(ib)
	rc, _ := niello.rect(ic)
	testing.expect(t, abs(ra.size.x-200) < EPS, fmt.tprintf("A width: %v", ra.size.x))
	testing.expect(t, abs(rb.size.x-150) < EPS, fmt.tprintf("B width: %v", rb.size.x))
	testing.expect(t, abs(rc.size.x-230) < EPS, fmt.tprintf("C width: %v", rc.size.x))
	// positions: 0, 210, 370
	testing.expect(t, abs(ra.pos.x-0) < EPS, "A x")
	testing.expect(t, abs(rb.pos.x-210) < EPS, fmt.tprintf("B x: %v", rb.pos.x))
	testing.expect(t, abs(rc.pos.x-370) < EPS, fmt.tprintf("C x: %v", rc.pos.x))
}

// ---------------------------------------------------------------------------
// Shrink: row FIXED 150, A FIXED 100 (holds), B wrap-text FIT content 112.
// Deficit 62 drains B to 50 (floor 16 = widest word); A never shrinks.

@(test)
test_shrink_to_floors :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(150), niello.fit()}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fixed(20)}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}, wrap = .Word})

	ia, ib: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		if _, ok2 := niello.begin(row); ok2 {
			ia = niello.show(a)
			ib = niello.show(b, 0, niello.With{text = "aa bb cc dd ee"}) // 5x16 + 4x8 = 112
		}
	}
	niello.frame_end()

	ra, _ := niello.rect(ia)
	rb, _ := niello.rect(ib)
	testing.expect(t, abs(ra.size.x-100) < EPS, fmt.tprintf("A held at 100, got %v", ra.size.x))
	testing.expect(t, abs(rb.size.x-50) < EPS, fmt.tprintf("B shrank to 50, got %v", rb.size.x))
}

// ---------------------------------------------------------------------------
// GROW inside a FIT parent is degenerate -> documented fallback: behaves as FIT.

@(test)
test_grow_in_fit_fallback :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.fixed(20)}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(20)}})

	irow, ib: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		if r, ok2 := niello.begin(row); ok2 {
			irow = r
			_ = niello.show(a)
			ib = niello.show(b)
		}
	}
	niello.frame_end()

	rr, _ := niello.rect(irow)
	rb, _ := niello.rect(ib)
	testing.expect(t, abs(rr.size.x-50) < EPS, fmt.tprintf("row niello.fit to 50, got %v", rr.size.x))
	testing.expect(t, abs(rb.size.x-0) < EPS, fmt.tprintf("B fell back to FIT (0), got %v", rb.size.x))
}

// ---------------------------------------------------------------------------
// Wrap: FIXED-200 wrap-text "The quick brown fox jumps high" (unwrapped 240)
// packs into 2 lines -> height 32; card grows to 48.

@(test)
test_word_wrap :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	card: niello.Unit
	niello.mint(&card, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.fit(), niello.fit()}, padding = [4]u16{8, 8, 8, 8}})
	desc: niello.Unit
	niello.mint(&desc, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fit()}, wrap = .Word})

	idesc, icard: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		if c, ok2 := niello.begin(card); ok2 {
			icard = c
			idesc = niello.show(desc, 0, niello.With{text = "The quick brown fox jumps high"})
		}
	}
	niello.frame_end()

	rd, _ := niello.rect(idesc)
	rc, _ := niello.rect(icard)
	testing.expect(t, abs(rd.size.y-32) < EPS, fmt.tprintf("desc wrapped to 32, got %v", rd.size.y))
	testing.expect(t, abs(rc.size.x-216) < EPS, fmt.tprintf("card width 216, got %v", rc.size.x))
	testing.expect(t, abs(rc.size.y-48) < EPS, fmt.tprintf("card height 48, got %v", rc.size.y))
}

// ---------------------------------------------------------------------------
// No-wrap is the default: 192px text in a 100px box never wraps (height stays 16).

@(test)
test_no_wrap_default :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	label: niello.Unit
	niello.mint(&label, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fit()}})

	ilabel: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		ilabel = niello.show(label, 0, niello.With{text = "Hello world this is long"}) // 24ch = 192px
	}
	niello.frame_end()

	rl, _ := niello.rect(ilabel)
	testing.expect(t, abs(rl.size.x-100) < EPS, "box is 100 wide")
	lay_content := niello.test_content(ilabel)
	testing.expect(t, abs(lay_content.y-16) < EPS, fmt.tprintf("never wrapped (h=16), got %v", lay_content.y))
	testing.expect(
	t,
	abs(lay_content.x-192) < EPS,
	fmt.tprintf("intrinsic width untouched: %v", lay_content.x),
	)
}

// ---------------------------------------------------------------------------
// Ellipsis floor: no-wrap ellipsis text shrinks to the "…" width under pressure;
// without ellipsis it holds full width and the row records overflow.

@(test)
test_ellipsis_shrink_floor :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(120), niello.fit()}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fixed(20)}})

	ia, irow: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		if r, ok2 := niello.begin(row); ok2 {
			irow = r
			ia = niello.show(a, 0, niello.With{text = "Hello world foo bar"}) // 19ch = 152px
			_ = niello.show(b)
		}
	}
	niello.frame_end()

	ra, _ := niello.rect(ia)
	testing.expect(t, abs(ra.size.x-80) < EPS, fmt.tprintf("ellipsis text shrank to 80, got %v", ra.size.x))

	// Without ellipsis the floor is the full width: it holds, row overflows.
	niello.test_reset()
	root2: niello.Unit
	niello.mint(&root2, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row2: niello.Unit
	niello.mint(&row2, niello.NO_UNIT, {size = niello.Size{niello.fixed(120), niello.fit()}})
	a2: niello.Unit
	niello.mint(&a2, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}, ellipsis = false})
	b2: niello.Unit
	niello.mint(&b2, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fixed(20)}})

	ia2, irow2: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root2); ok {
		if r, ok2 := niello.begin(row2); ok2 {
			irow2 = r
			ia2 = niello.show(a2, 0, niello.With{text = "Hello world foo bar"}) // 19ch = 152px
			_ = niello.show(b2)
		}
	}
	niello.frame_end()

	ra2, _ := niello.rect(ia2)
	testing.expect(t, abs(ra2.size.x-152) < EPS, fmt.tprintf("no-ellipsis held at 152, got %v", ra2.size.x))
	overfl := niello.test_overflow(irow2)
	testing.expect(t, abs(overfl.x-72) < EPS, fmt.tprintf("row overflow.x = 72, got %v", overfl.x))
}

// ---------------------------------------------------------------------------
// Stack: children resolve independently (excluded from waterfill). Two GROW
// children each fill the full 400px content box; they overlap at {0,0}.

@(test)
test_stack_excluded_from_waterfill :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	st: niello.Unit
	niello.mint(&st, niello.NO_UNIT, {layout = .Stack, size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fixed(50)}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(30)}})
	c: niello.Unit
	niello.mint(&c, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(30)}})

	ib, ic: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		if _, ok2 := niello.begin(st); ok2 {
			_ = niello.show(a)
			ib = niello.show(b)
			ic = niello.show(c)
		}
	}
	niello.frame_end()

	expect_rect(t, ib, niello.Rect{{0, 0}, {400, 30}})
	expect_rect(t, ic, niello.Rect{{0, 0}, {400, 30}})
}

// ---------------------------------------------------------------------------
// Percent: 0.5 of an 800px row = 400.

@(test)
test_percent_sizing :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Left_To_Right})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.percent(0.5), niello.fixed(20)}})

	ia: niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		ia = niello.show(a)
	}
	niello.frame_end()

	ra, _ := niello.rect(ia)
	testing.expect(t, abs(ra.size.x-400) < EPS, fmt.tprintf("niello.percent width 400, got %v", ra.size.x))
}

// ---------------------------------------------------------------------------
// Damage: new rects on frame 1, changed rects on frame 2, silence on frame 3.

@(test)
test_damage_tracks_changes :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	title: niello.Unit
	niello.mint(&title, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})

	declare :: proc(root, title: niello.Unit, text: string) {
		if _, ok := niello.begin(root); ok {
			_ = niello.show(title, 0, niello.With{text = text})
		}
	}

	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	declare(root, title, "Hi")
	res := niello.frame_end()
	testing.expect(t, len(res.damage) > 0, "frame 1 (new instances) produces damage")

	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	declare(root, title, "Hello")
	res = niello.frame_end()
	testing.expect(t, len(res.damage) > 0, "frame 2 (wider text) produces damage")

	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	declare(root, title, "Hello")
	res = niello.frame_end()
	testing.expect(t, len(res.damage) == 0, "frame 3 (identical) is silent")
}

// ---------------------------------------------------------------------------
// Identity: the same declaration across frames yields the same instance ids.

@(test)
test_identity_stable_across_frames :: proc(t: ^testing.T) {
	niello.test_reset()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	item: niello.Unit
	niello.mint(&item, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.fixed(20)}})

	ids1: [3]niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		ids1[0] = niello.show(item, 7)
		ids1[1] = niello.show(item, 8)
		ids1[2] = niello.show(item) // auto niello.key (sibling ordinal)
	}
	niello.frame_end()

	ids2: [3]niello.Instance
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(root); ok {
		ids2[0] = niello.show(item, 7)
		ids2[1] = niello.show(item, 8)
		ids2[2] = niello.show(item)
	}
	niello.frame_end()

	testing.expect(t, ids1 == ids2, "identities stable across frames")
	testing.expect(t, ids1[0] != ids1[1] && ids1[1] != ids1[2], "distinct keys give distinct ids")
}

// ---------------------------------------------------------------------------
// Culling protocol: open=false still pops (stack stays balanced).

@(test)
test_cull_protocol :: proc(t: ^testing.T) {
	niello.test_reset()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fixed(100)}})
	v: niello.Unit
	niello.mint(&v, niello.NO_UNIT, {size = niello.Size{niello.fixed(10), niello.fixed(10)}})

	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	niello.test_force_cull_next()
	culled_ok := false
	if _, ok := niello.begin(u); ok {
		_ = niello.show(v)
	} else {
		culled_ok = true // open == false observed
	}
	// Stack must be balanced: a second container still works.
	second_ok := false
	if _, ok2 := niello.begin(u); ok2 {
		second_ok = true
	}
	niello.frame_end()

	testing.expect(t, culled_ok, "forced cull reported open=false")
	testing.expect(t, second_ok, "stack balanced after culled container")
	testing.expect(t, niello.test_stack_depth() == 0, "stack empty at frame end")
}

// ---------------------------------------------------------------------------
// Public API: niello.mint prototypes (snapshot copy), niello.set, niello.key.

@(test)
test_mint_prototype_and_set :: proc(t: ^testing.T) {
	niello.test_reset()

	proto: niello.Unit
	niello.mint(&proto, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fixed(20)}, gap = 8})

	child: niello.Unit
	niello.mint(&child, proto) // snapshot-copies proto's style
	s := niello.style_of(child)
	testing.expect(t, s.size[niello.X_AXIS].value == 100, "prototype size.x copied")
	testing.expect(t, s.gap == 8, "prototype gap copied")
	testing.expect(t, niello.test_proto(child) == proto, "proto recorded")

	// Later writes to the prototype do NOT follow (snapshot, never live link).
	niello.set(proto, .Gap, u16(99))
	testing.expect(t, niello.style_of(child).gap == 8, "prototype write does not propagate")
	testing.expect(t, niello.style_of(proto).gap == 99, "prototype write lands")

	// niello.set writes one field and bumps the generation.
	gen_before := niello.test_generation()
	niello.set(child, .Gap, u16(4))
	testing.expect(t, niello.style_of(child).gap == 4, "niello.set writes the field")
	testing.expect(t, niello.test_generation() == gen_before+1, "niello.set bumps the generation")
	testing.expect(t, .Gap in niello.test_dirty(child), "niello.set marks the field dirty")

	// niello.key() gives stable, distinct identities.
	testing.expect(t, niello.key(7) == niello.key(7), "int keys stable")
	testing.expect(t, niello.key("a") == niello.key("a"), "string keys stable")
	testing.expect(t, niello.key(7) != niello.key(8), "distinct keys distinct")
	testing.expect(t, niello.key(0) == 0, "zero niello.key means sibling ordinal")

	// niello.frame_end clears dirty sets O(touched).
	niello.frame_begin(niello.Input{viewport = {800, 600}}, 0)
	if _, ok := niello.begin(child); ok {}
	_ = niello.frame_end()
	testing.expect(t, card(niello.test_dirty(child)) == 0, "dirty cleared at niello.frame_end")
}

// ---------------------------------------------------------------------------
// Perf: per-frame layout time on a representative tree.
//
// Measures ONLY the resolve pass (frame_end): the seven layout passes plus
// damage. Declaration is excluded on purpose — it scales with app code, not
// the engine. The 16 ms bound is one 60 fps frame budget; the engine should
// sit orders of magnitude under it, so the bound trips only on a genuine
// complexity regression, never on machine noise. The printed numbers are
// the real deliverable: watch the trend, not the threshold.

N_SECTIONS :: 16
N_CARDS    :: 10
N_LEAVES   :: 8
N_STACK    :: 10
N_SCROLL   :: 30
PERF_NODES :: 1 + N_SECTIONS + N_SECTIONS*N_CARDS + N_SECTIONS*N_CARDS*N_LEAVES + (1+N_STACK) + (1+N_SCROLL)

// perf_declare rebuilds the whole tree every frame, like a real app would.
perf_declare :: proc(
	window: niello.Unit,
	sections: ^[N_SECTIONS]niello.Unit,
	cards: ^[N_SECTIONS][N_CARDS]niello.Unit,
	leaves: ^[N_SECTIONS][N_CARDS][N_LEAVES]niello.Unit,
	leaf_text: ^[N_SECTIONS][N_CARDS][N_LEAVES]bool,
	stack_sec: niello.Unit, stack_kids: ^[N_STACK]niello.Unit,
	scroll_sec: niello.Unit, scroll_kids: ^[N_SCROLL]niello.Unit,
	texts: []string,
) {
	ti := 0
	if _, ok := niello.begin(window); ok {
		for s in 0 ..< N_SECTIONS {
			if _, ok := niello.begin(sections[s]); ok {
				for c in 0 ..< N_CARDS {
					if _, ok := niello.begin(cards[s][c]); ok {
						for l in 0 ..< N_LEAVES {
							if leaf_text[s][c][l] {
								_ = niello.show(leaves[s][c][l], 0, {text = texts[ti % len(texts)]})
								ti += 1
							} else {
								_ = niello.show(leaves[s][c][l])
							}
						}
					}
				}
			}
		}
		if _, ok := niello.begin(stack_sec); ok {
			for k in 0 ..< N_STACK {
				_ = niello.show(stack_kids[k])
			}
		}
		if _, ok := niello.begin(scroll_sec); ok {
			for k in 0 ..< N_SCROLL {
				_ = niello.show(scroll_kids[k])
			}
		}
	}
}

@(test)
test_layout_perf :: proc(t: ^testing.T) {
	niello.test_reset()

	window: niello.Unit
	niello.mint(&window, niello.NO_UNIT, {
		size   = niello.Size{niello.fixed(1200), niello.fixed(800)},
		layout = .Top_To_Bottom,
	})

	sections: [N_SECTIONS]niello.Unit
	for i in 0 ..< N_SECTIONS {
		lay_kind := niello.Layout.Left_To_Right
		if i % 2 != 0 {
			lay_kind = .Top_To_Bottom
		}
		niello.mint(&sections[i], niello.NO_UNIT, {
			layout = lay_kind,
			size   = niello.Size{niello.grow(), niello.fit()},
			gap    = 6,
		})
	}

	cards: [N_SECTIONS][N_CARDS]niello.Unit
	leaves: [N_SECTIONS][N_CARDS][N_LEAVES]niello.Unit
	leaf_text: [N_SECTIONS][N_CARDS][N_LEAVES]bool
	for s in 0 ..< N_SECTIONS {
		for c in 0 ..< N_CARDS {
			niello.mint(&cards[s][c], niello.NO_UNIT, {
				layout  = .Top_To_Bottom,
				size    = niello.Size{niello.fixed(140), niello.fit()},
				padding = [4]u16{4, 4, 4, 4},
				gap     = 2,
			})
			for l in 0 ..< N_LEAVES {
				decl := niello.Style_Decl{}
				text := false
				switch (s + c + l) % 4 {
				case 0:
					decl.size = niello.Size{niello.fixed(40), niello.fixed(20)}
				case 1:
					decl.size = niello.Size{niello.fit(), niello.fit()}
					text = true
				case 2:
					decl.size = niello.Size{niello.grow(), niello.fixed(20)}
				case 3:
					decl.size = niello.Size{niello.fit(), niello.fit()}
					decl.wrap = .Word
					text = true
				}
				niello.mint(&leaves[s][c][l], niello.NO_UNIT, decl)
				leaf_text[s][c][l] = text
			}
		}
	}

	// Stack: children resolve independently (excluded from waterfill).
	stack_sec: niello.Unit
	niello.mint(&stack_sec, niello.NO_UNIT, {
		layout = .Stack,
		size   = niello.Size{niello.fixed(400), niello.fixed(300)},
	})
	stack_kids: [N_STACK]niello.Unit
	for k in 0 ..< N_STACK {
		niello.mint(&stack_kids[k], niello.NO_UNIT, {size = niello.Size{niello.fixed(60), niello.fixed(40)}})
	}

	// Horizontal scroller: children overflow instead of shrinking.
	scroll_sec: niello.Unit
	niello.mint(&scroll_sec, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.fixed(600), niello.fit()},
		scroll = .Horizontal,
	})
	scroll_kids: [N_SCROLL]niello.Unit
	for k in 0 ..< N_SCROLL {
		niello.mint(&scroll_kids[k], niello.NO_UNIT, {size = niello.Size{niello.fixed(80), niello.fixed(20)}})
	}

	texts := [8]string{
		"Alpha", "Beta gamma", "Delta epsilon zeta", "Eta",
		"Theta iota kappa", "Lambda", "Mu nu xi omicron", "Pi rho sigma tau",
	}

	// Warmup: text cache, instance map, allocators.
	for _ in 0 ..< 5 {
		niello.frame_begin(niello.Input{viewport = {1200, 800}}, 1.0 / 60.0)
		perf_declare(window, &sections, &cards, &leaves, &leaf_text,
			stack_sec, &stack_kids, scroll_sec, &scroll_kids, texts[:])
		_ = niello.frame_end()
	}

	N_FRAMES :: 50
	total := time.Duration(0)
	worst := time.Duration(0)
	for _ in 0 ..< N_FRAMES {
		niello.frame_begin(niello.Input{viewport = {1200, 800}}, 1.0 / 60.0)
		perf_declare(window, &sections, &cards, &leaves, &leaf_text,
			stack_sec, &stack_kids, scroll_sec, &scroll_kids, texts[:])
		start := time.tick_now()
		_ = niello.frame_end()
		d := time.tick_diff(start, time.tick_now())
		total += d
		worst = max(worst, d)
	}

	avg_ms := time.duration_milliseconds(total) / f64(N_FRAMES)
	worst_ms := time.duration_milliseconds(worst)
	fmt.printf(
		"layout perf: %d nodes x %d frames: avg %.3f ms/frame, worst %.3f ms/frame\n",
		PERF_NODES, N_FRAMES, avg_ms, worst_ms,
	)
	testing.expect(
		t, avg_ms < 16.0,
		fmt.tprintf("avg frame time %.3f ms exceeds the 16 ms budget", avg_ms),
	)
}

@(test)
test_borders_and_overlays :: proc(t: ^testing.T) {
	niello.test_reset()

	// Defaults: everything off.
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {})
	s := niello.style_of(u)
	testing.expect(t, s.border_width == 0, "default border_width is 0")
	testing.expect(t, s.overlay_border_width == 0, "default overlay_border_width is 0")
	testing.expect(
		t,
		s.overlay_color == {0, 0, 0, 0},
		"default overlay_color is transparent (disabled)",
	)
	testing.expect(
		t,
		s.overlay_border_color == {0, 0, 0, 0},
		"default overlay_border_color is transparent",
	)

	// Mint path.
	v: niello.Unit
	niello.mint(
		&v,
		niello.NO_UNIT,
		{
			border_width = 2,
			overlay_color = [4]u8{255, 0, 0, 128},
			overlay_border_color = [4]u8{0, 255, 0, 255},
			overlay_border_width = 1,
		},
	)
	sv := niello.style_of(v)
	testing.expect(t, sv.border_width == 2, "minted border_width")
	testing.expect(t, sv.overlay_color == {255, 0, 0, 128}, "minted overlay_color")
	testing.expect(t, sv.overlay_border_color == {0, 255, 0, 255}, "minted overlay_border_color")
	testing.expect(t, sv.overlay_border_width == 1, "minted overlay_border_width")

	// set() path, including generation bump and dirty tracking.
	gen0 := niello.test_generation()
	niello.set(v, .Border_Width, u16(3))
	niello.set(v, .Overlay_Color, [4]u8{0, 0, 255, 200})
	niello.set(v, .Overlay_Border_Color, [4]u8{255, 255, 0, 255})
	niello.set(v, .Overlay_Border_Width, u16(4))
	sv = niello.style_of(v)
	testing.expect(t, sv.border_width == 3, "set border_width")
	testing.expect(t, sv.overlay_color == {0, 0, 255, 200}, "set overlay_color")
	testing.expect(t, sv.overlay_border_color == {255, 255, 0, 255}, "set overlay_border_color")
	testing.expect(t, sv.overlay_border_width == 4, "set overlay_border_width")
	testing.expect(
		t,
		niello.test_generation() == gen0 + 4,
		"each set bumps the generation",
	)
	dirty := niello.test_dirty(v)
	testing.expect(t, .Border_Width in dirty, "dirty tracks Border_Width")
	testing.expect(t, .Overlay_Color in dirty, "dirty tracks Overlay_Color")
	testing.expect(
		t,
		.Overlay_Border_Color in dirty,
		"dirty tracks Overlay_Border_Color",
	)
	testing.expect(
		t,
		.Overlay_Border_Width in dirty,
		"dirty tracks Overlay_Border_Width",
	)
}
