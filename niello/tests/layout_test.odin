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
	defer niello.test_teardown()
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
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(window, out = &i_win) {
		if niello.begin(toolbar, out = &i_tb) {
			i_open = niello.show(open_b)
			i_save = niello.show(save_b)
			i_title = niello.show(title, niello.With{text = "Notes"})
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
	defer niello.test_teardown()
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
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		if niello.begin(row) {
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
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(150), niello.fit()}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fixed(20)}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}, wrap = .Word})

	ia, ib: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		if niello.begin(row) {
			ia = niello.show(a)
			ib = niello.show(b, niello.With{text = "aa bb cc dd ee"}) // 5x16 + 4x8 = 112
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
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.fixed(20)}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(20)}})

	irow, ib: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		if niello.begin(row, out = &irow) {
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
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	card: niello.Unit
	niello.mint(&card, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.fit(), niello.fit()}, padding = [4]u16{8, 8, 8, 8}})
	desc: niello.Unit
	niello.mint(&desc, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fit()}, wrap = .Word})

	idesc, icard: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		if niello.begin(card, out = &icard) {
			idesc = niello.show(desc, niello.With{text = "The quick brown fox jumps high"})
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
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	label: niello.Unit
	niello.mint(&label, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fit()}})

	ilabel: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		ilabel = niello.show(label, niello.With{text = "Hello world this is long"}) // 24ch = 192px
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
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(120), niello.fit()}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fixed(20)}})

	ia, irow: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		if niello.begin(row, out = &irow) {
			ia = niello.show(a, niello.With{text = "Hello world foo bar"}) // 19ch = 152px
			_ = niello.show(b)
		}
	}
	niello.frame_end()

	ra, _ := niello.rect(ia)
	testing.expect(t, abs(ra.size.x-80) < EPS, fmt.tprintf("ellipsis text shrank to 80, got %v", ra.size.x))

	// Without ellipsis the floor is the full width: it holds, row overflows.
	niello.test_reset()
	defer niello.test_teardown()
	root2: niello.Unit
	niello.mint(&root2, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	row2: niello.Unit
	niello.mint(&row2, niello.NO_UNIT, {size = niello.Size{niello.fixed(120), niello.fit()}})
	a2: niello.Unit
	niello.mint(&a2, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}, ellipsis = false})
	b2: niello.Unit
	niello.mint(&b2, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fixed(20)}})

	ia2, irow2: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root2) {
		if niello.begin(row2, out = &irow2) {
			ia2 = niello.show(a2, niello.With{text = "Hello world foo bar"}) // 19ch = 152px
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
	defer niello.test_teardown()
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
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		if niello.begin(st) {
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
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Left_To_Right})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.percent(0.5), niello.fixed(20)}})

	ia: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
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
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	title: niello.Unit
	niello.mint(&title, niello.NO_UNIT, {size = niello.Size{niello.fit(), niello.fit()}})

	declare :: proc(root, title: niello.Unit, text: string) {
		if niello.begin(root) {
			_ = niello.show(title, niello.With{text = text})
		}
	}

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	declare(root, title, "Hi")
	res := niello.frame_end()
	testing.expect(t, len(res.damage) > 0, "frame 1 (new instances) produces damage")

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	declare(root, title, "Hello")
	res = niello.frame_end()
	testing.expect(t, len(res.damage) > 0, "frame 2 (wider text) produces damage")

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	declare(root, title, "Hello")
	res = niello.frame_end()
	testing.expect(t, len(res.damage) == 0, "frame 3 (identical) is silent")
}

// ---------------------------------------------------------------------------
// Identity: the same declaration across frames yields the same instance ids.

@(test)
test_identity_stable_across_frames :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {size = niello.Size{niello.fixed(800), niello.fixed(600)}, layout = .Top_To_Bottom})
	item: niello.Unit
	niello.mint(&item, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.fixed(20)}})

	declare :: proc(root, item: niello.Unit) -> (ids: [3]niello.Instance) {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
		if niello.begin(root) {
			ids[0] = niello.show(item, key = 7)
			ids[1] = niello.show(item, key = 8)
			ids[2] = niello.show(item) // no key: named by its call site
		}
		niello.frame_end()
		return
	}
	ids1 := declare(root, item)
	ids2 := declare(root, item)

	testing.expect(t, ids1 == ids2, "identities stable across frames")
	testing.expect(t, ids1[0] != ids1[1] && ids1[1] != ids1[2], "distinct keys give distinct ids")
}

// ---------------------------------------------------------------------------
// Culling protocol: open=false still pops (stack stays balanced).

@(test)
test_cull_protocol :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	u: niello.Unit
	niello.mint(&u, niello.NO_UNIT, {size = niello.Size{niello.fixed(100), niello.fixed(100)}})
	v: niello.Unit
	niello.mint(&v, niello.NO_UNIT, {size = niello.Size{niello.fixed(10), niello.fixed(10)}})

	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	niello.test_force_cull_next()
	culled_ok := false
	if niello.begin(u) {
		_ = niello.show(v)
	} else {
		culled_ok = true // open == false observed
	}
	// Stack must be balanced: a second container still works.
	second_ok := false
	if niello.begin(u) {
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
	defer niello.test_teardown()

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

	// niello.set writes one field and bumps the visual generation.
	gen_before := niello.test_visual_gen(child)
	niello.set(child, .Gap, u16(4))
	testing.expect(t, niello.style_of(child).gap == 4, "niello.set writes the field")
	testing.expect(t, niello.test_visual_gen(child) == gen_before+1, "niello.set bumps the visual generation")

	// niello.key() gives stable, distinct identities.
	testing.expect(t, niello.key(7) == niello.key(7), "int keys stable")
	testing.expect(t, niello.key("a") == niello.key("a"), "string keys stable")
	testing.expect(t, niello.key(7) != niello.key(8), "distinct keys distinct")
	testing.expect(t, niello.key(0) == 0, "zero niello.key means the call site names the instance")

	// The write damages exactly the frame that commits it; the
	// next frame, with no writes, settles.
	child_frame :: proc(child: niello.Unit) -> niello.Frame_Result {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
		if niello.begin(child) {}
		return niello.frame_end()
	}
	res := child_frame(child)
	testing.expect(t, res.changed, "the write damages the frame that commits it")
	res = child_frame(child)
	testing.expect(t, !res.changed, "a frame with no writes is unchanged")
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
	if niello.begin(window) {
		for s in 0 ..< N_SECTIONS {
			if niello.begin(sections[s]) {
				for c in 0 ..< N_CARDS {
					if niello.begin(cards[s][c]) {
						for l in 0 ..< N_LEAVES {
							if leaf_text[s][c][l] {
								_ = niello.show(leaves[s][c][l], {text = texts[ti % len(texts)]})
								ti += 1
							} else {
								_ = niello.show(leaves[s][c][l])
							}
						}
					}
				}
			}
		}
		if niello.begin(stack_sec) {
			for k in 0 ..< N_STACK {
				_ = niello.show(stack_kids[k])
			}
		}
		if niello.begin(scroll_sec) {
			for k in 0 ..< N_SCROLL {
				_ = niello.show(scroll_kids[k])
			}
		}
	}
}

@(test)
test_layout_perf :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

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
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {1200, 800}}, 1.0 / 60.0)
		perf_declare(window, &sections, &cards, &leaves, &leaf_text,
			stack_sec, &stack_kids, scroll_sec, &scroll_kids, texts[:])
		_ = niello.frame_end()
	}

	N_FRAMES :: 50
	total := time.Duration(0)
	worst := time.Duration(0)
	for _ in 0 ..< N_FRAMES {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {1200, 800}}, 1.0 / 60.0)
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
	defer niello.test_teardown()

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

	// set() path, including the visual-generation bump.
	gen0 := niello.test_visual_gen(v)
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
		niello.test_visual_gen(v) == gen0 + 4,
		"each set bumps the visual generation",
	)
}

@(test)
test_grow_under_fit_root_column :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	// The hello shape: the root unit has NO size (FIT style), but a root
	// resolves against the viewport, so it is NOT content-sized — GROW
	// children must grow. (Regression: parent_fit read the style kind, so
	// the root's FIT style triggered the GROW-in-FIT fallback and the card
	// below only grew horizontally, via the cross axis.)
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		padding = [4]u16{24, 24, 24, 24},
		gap     = 16,
	})
	toolbar: niello.Unit
	niello.mint(&toolbar, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(48)}})
	card: niello.Unit
	niello.mint(&card, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.grow(), niello.grow()}})
	filler: niello.Unit
	niello.mint(&filler, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(40)}})

	icard: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {800, 600}}, 0)
	if niello.begin(root) {
		if niello.begin(toolbar) {
		}
		if niello.begin(card, out = &icard) {
			_ = niello.show(filler) // content-bearing card: grow must land exact, not content + leftover
		}
	}
	niello.frame_end()

	rc, _ := niello.rect(icard)
	// Inner box: 800-48 x 600-48; card height = 552 - 48 (toolbar) - 16 (gap).
	testing.expect(t, abs(rc.size.x-752) < EPS, fmt.tprintf("card width grows: %v", rc.size.x))
	testing.expect(t, abs(rc.size.y-488) < EPS, fmt.tprintf("card height grows: %v", rc.size.y))
}

@(test)
test_grow_under_fit_root_row :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {layout = .Left_To_Right})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.grow()}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.grow()}})

	ib: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if niello.begin(root) {
		_ = niello.show(a)
		ib = niello.show(b)
	}
	niello.frame_end()

	rb, _ := niello.rect(ib)
	testing.expect(t, abs(rb.size.x-350) < EPS, fmt.tprintf("B width grows: %v", rb.size.x))
	testing.expect(t, abs(rb.size.y-300) < EPS, fmt.tprintf("B height grows: %v", rb.size.y))
}

@(test)
test_grow_with_content_split :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	// Two GROW containers with real content split the TRUE leftover:
	// contents 30 + 50 in a 300-tall root leave 220, so each grows by 110.
	root: niello.Unit
	niello.mint(&root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.fixed(400), niello.fixed(300)}})
	a: niello.Unit
	niello.mint(&a, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.grow(), niello.grow()}})
	b: niello.Unit
	niello.mint(&b, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.grow(), niello.grow()}})
	fa: niello.Unit
	niello.mint(&fa, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(30)}})
	fb: niello.Unit
	niello.mint(&fb, niello.NO_UNIT, {size = niello.Size{niello.grow(), niello.fixed(50)}})

	ia, ib: niello.Instance
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0)
	if niello.begin(root) {
		if niello.begin(a, out = &ia) {
			_ = niello.show(fa)
		}
		if niello.begin(b, out = &ib) {
			_ = niello.show(fb)
		}
	}
	niello.frame_end()

	ra, _ := niello.rect(ia)
	rb, _ := niello.rect(ib)
	testing.expect(t, abs(ra.size.y-140) < EPS, fmt.tprintf("A height: %v", ra.size.y))
	testing.expect(t, abs(rb.size.y-160) < EPS, fmt.tprintf("B height: %v", rb.size.y))
}

// A FIT container shrunk by ITS parent must pass the deficit through
// to its own shrinkable children: parent_fit used to skip the take
// entirely (FIT was assumed to mean content-sized), so a squeezed
// button's label kept its full content width and spilled, untruncated.
// (Regression from the animate demo's buttons in a narrow row.)
sqz_root, sqz_btn, sqz_lbl: niello.Unit
sqz_btn_i, sqz_lbl_i: niello.Instance

@(test)
test_fit_container_passes_deficit_to_children :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	niello.mint(&sqz_root, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.fixed(200), niello.fixed(60)},
		gap = 8,
	})
	niello.mint(&sqz_btn, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.fit(), niello.fixed(40)},
		padding = [4]u16{16, 0, 16, 0},
		align = [2]niello.Align_Kind{.Center, .Center},
	})
	niello.mint(&sqz_lbl, niello.NO_UNIT, {font_size = 14})

	finish(proc() {
		if niello.begin(sqz_root) {
			if niello.begin(sqz_btn, key = niello.key_int(0), out = &sqz_btn_i) {
				sqz_lbl_i = niello.show(sqz_lbl, {text = "Cycle accent + propagate"})
			}
			if niello.begin(sqz_btn, key = niello.key_int(1)) {
				niello.show(sqz_lbl, {text = "Crossfade theme"})
			}
		}
	})
	br, _ := niello.rect(sqz_btn_i)
	testing.expect(t, br.size.x < 200, "the first button was squeezed by its parent")
	lr, _ := niello.rect(sqz_lbl_i)
	testing.expect(t, abs(lr.size.x - (br.size.x - 32)) < EPS,
		"the label shrank to the button's inner width")
	found := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Text && cmd.bounds.pos == lr.pos {
			found = true
			testing.expect(t, cmd.truncated, "the squeezed text is marked truncated")
			testing.expect(t, abs(cmd.max_width - lr.size.x) < EPS,
				"and its max_width is the resolved width, so the backend ellipsizes")
		}
	}
	testing.expect(t, found, "the label's text command exists")
}

// ---------------------------------------------------------------------------
// Real culling (BL-3): a container whose last-frame rect misses the
// accumulated ancestor clip is culled — open=false, no instance
// (rect() reports ok=false), its disappearance damages its old rect
// exactly once, and Begin_Flags.No_Cull opts out of the rect test.

@(test)
test_culling_real :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	scroller: niello.Unit
	niello.mint(&scroller, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}, layout = .Top_To_Bottom, scroll = .Vertical})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(30)}, layout = .Top_To_Bottom})
	leaf: niello.Unit
	niello.mint(&leaf, niello.NO_UNIT, {size = niello.Size{niello.fixed(50), niello.fixed(20)}})

	// Six 30px rows in a 100px scroller: rows 0..3 intersect the
	// clip (row 3 only partially), rows 4 and 5 sit fully below it.
	ids: [6]niello.Instance
	opens: [6]bool
	declare_frame :: proc(scroller, row, leaf: niello.Unit, ids: ^[6]niello.Instance, opens: ^[6]bool, no_cull_last: bool) {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {200, 100}}, 0)
		if niello.begin(scroller) {
			for k in 0 ..< 6 {
				flags: niello.Begin_Flags = {}
				if no_cull_last && k == 5 {
					flags = {.No_Cull}
				}
				if niello.begin(row, {}, niello.key_int(k + 1), flags, out = &ids[k]) {
					opens[k] = true
					niello.show(leaf)
				} else {
					opens[k] = false
				}
			}
		}
	}

	// Frame 1: nothing has a committed rect, so nothing culls.
	declare_frame(scroller, row, leaf, &ids, &opens, false)
	niello.frame_end()
	for k in 0 ..< 6 {
		_, ok := niello.rect(ids[k])
		testing.expect(t, ok, "frame 1: every row committed")
	}
	row4_rect, _ := niello.rect(ids[4])
	testing.expect(t, row4_rect == niello.Rect{{0, 120}, {200, 30}}, "frame 1: row 4 sits below the clip")

	// Frame 2: rows 4 and 5 cull by rect; the rest stay open.
	declare_frame(scroller, row, leaf, &ids, &opens, false)
	res2 := niello.frame_end()
	testing.expect(t, opens[0] && opens[1] && opens[2] && opens[3], "frame 2: intersecting rows stay open")
	testing.expect(t, !opens[4] && !opens[5], "frame 2: fully-clipped rows are culled")
	_, ok4 := niello.rect(ids[4])
	_, ok5 := niello.rect(ids[5])
	_, ok0 := niello.rect(ids[0])
	testing.expect(t, !ok4 && !ok5, "frame 2: culled rows have no instance")
	testing.expect(t, ok0, "frame 2: visible rows keep their instance")
	damaged := false
	for d in res2.damage {
		if d == row4_rect {
			damaged = true
		}
	}
	testing.expect(t, damaged, "frame 2: the vanished row's old rect is damage")

	// Frame 3: steady state — still culled, but no repeated damage.
	declare_frame(scroller, row, leaf, &ids, &opens, false)
	res3 := niello.frame_end()
	testing.expect(t, !opens[4] && !opens[5], "frame 3: rows stay culled")
	damaged = false
	for d in res3.damage {
		if d == row4_rect {
			damaged = true
		}
	}
	testing.expect(t, !damaged, "frame 3: a culled row adds no further damage")

	// Frame 4: No_Cull opts row 5 out of the rect test.
	declare_frame(scroller, row, leaf, &ids, &opens, true)
	niello.frame_end()
	testing.expect(t, opens[5], "frame 4: No_Cull row declares despite sitting outside the clip")
	_, ok5b := niello.rect(ids[5])
	testing.expect(t, ok5b, "frame 4: No_Cull row commits an instance again")
}

@(test)
test_recycle_swap_with_culled_node :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	clip: niello.Unit
	niello.mint(&clip, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}, layout = .Top_To_Bottom, overflow = .Clip})
	row: niello.Unit
	niello.mint(&row, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(30)}})

	ids: [5]niello.Instance // keys 1..4 -> slots 1..4
	declare :: proc(clip, row: niello.Unit, ids: ^[5]niello.Instance, keys: []int) {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {200, 200}}, 0)
		if niello.begin(clip) {
			for k in keys {
				if niello.begin(row, key = niello.key_int(k), out = &ids[k]) {
				}
			}
		}
		niello.frame_end()
	}

	// Frame 1: clip is 100 tall; rows 1..3 (y 0, 30, 60) all commit.
	declare(clip, row, &ids, []int{1, 2, 3})
	count1 := niello.instance_count(niello.test_context())
	_, ok_b1 := niello.rect(ids[2])
	testing.expect(t, ok_b1, "frame 1: row 2 committed")

	// Frame 2: clip shrinks to 45. The culler tests last-frame rects,
	// so row 3 is culled one frame later, when the shrink has settled.
	niello.set(clip, .Size, niello.Size{niello.fixed(200), niello.fixed(45)})
	declare(clip, row, &ids, []int{1, 2, 3})
	declare(clip, row, &ids, []int{1, 2, 3})
	count2 := niello.instance_count(niello.test_context())
	testing.expect(t, count2 == count1 - 1, "frame 2: culled row's instance is gone")

	// Frame 3 — the swap the old sweep missed (audit core-H4): row 2
	// dies, row 4 is born in its place, and row 3 stays declared but
	// culled. Declared-node count (4) equals the instance-map size
	// (clip, 1, 2, 4), so the map-outgrew-the-tree signal never fired
	// and row 2's record leaked: rect() kept answering for a dead id.
	declare(clip, row, &ids, []int{1, 4, 3})
	_, ok_b3 := niello.rect(ids[2])
	testing.expect(t, !ok_b3, "frame 3: swapped-out row 2 is recycled despite the culled bystander")
	count3 := niello.instance_count(niello.test_context())
	testing.expect(t, count3 == count2, "frame 3: a swap keeps the instance count (one death, one birth)")
	_, ok_d3 := niello.rect(ids[4])
	testing.expect(t, ok_d3, "frame 3: row 4 committed")
}

@(test)
test_overflow_propagates_and_damage_covers_old_spill :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	// (a) Propagation (audit core-H7): a grandchild spilling past a
	// non-clipping child extends the grandparent's scroll range.
	gp: niello.Unit
	niello.mint(&gp, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}, layout = .Top_To_Bottom, scroll = .Vertical})
	mid: niello.Unit
	niello.mint(&mid, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}, layout = .Top_To_Bottom})
	leaf: niello.Unit
	niello.mint(&leaf, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(300)}})

	gp_inst: niello.Instance
	declare_gp :: proc(gp, mid, leaf: niello.Unit, gp_inst: ^niello.Instance) {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {200, 100}}, 0)
		if niello.begin(gp, out = gp_inst) {
			if niello.begin(mid) {
				niello.show(leaf)
			}
		}
		niello.frame_end()
	}
	declare_gp(gp, mid, leaf, &gp_inst)
	niello.scroll_to(gp_inst, {0, 150})
	declare_gp(gp, mid, leaf, &gp_inst)
	off := niello.scroll_offset(gp_inst)
	testing.expect(t, off.y == 150, "grandchild spill extends the grandparent's scroll range to 200")

	// (b) Shrinking spill: the frame that shrinks the child must
	// damage the OLD spill's extent, not just the new rect.
	niello.test_reset()
	parent: niello.Unit
	niello.mint(&parent, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(100)}, layout = .Top_To_Bottom})
	child: niello.Unit
	niello.mint(&child, niello.NO_UNIT, {size = niello.Size{niello.fixed(200), niello.fixed(200)}})
	declare_p :: proc(parent, child: niello.Unit) -> niello.Frame_Result {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {200, 300}}, 0)
		if niello.begin(parent) {
			niello.show(child)
		}
		return niello.frame_end()
	}
	declare_p(parent, child)
	niello.set(child, .Size, niello.Size{niello.fixed(200), niello.fixed(50)})
	res := declare_p(parent, child)
	covered := false
	for d in res.damage {
		if d.pos.y + d.size.y >= 200 {
			covered = true
		}
	}
	testing.expect(t, covered, "shrinking the spill damages the old spill's full extent (bottom reaches 200)")
}
