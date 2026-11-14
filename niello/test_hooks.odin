package niello

// test_hooks.odin — test-only introspection for the test suite in tests/.
//
// These are NOT part of the stable public API (see public.odin). They exist
// so black-box tests can assert on white-box state: generations,
// prototypes, culling. Do not call them from application code.
//
// They exist only in test builds (odin test): never in an application,
// never in the documentation.

when ODIN_TEST {
	// test_visual_gen returns the unit's visual generation — the
	// stamp pass F compares (§3.26). It advances on writes touching
	// a VISUAL_FIELDS field, and only then.
	test_visual_gen :: proc(u: Unit) -> u64 {
		return store.units[unit_index(u)].gen
	}

	// test_proto returns the unit's prototype (NO_UNIT if none).
	test_proto :: proc(u: Unit) -> Unit {
		return store.units[unit_index(u)].proto
	}

	// test_force_cull_next makes the next begin() report open = false.
	test_force_cull_next :: proc() {
		g.test_force_cull = true
	}

	// test_stack_depth returns the open-container stack depth (for asserting
	// end() pops symmetrically even when open == false).
	test_stack_depth :: proc() -> int {
		return len(g.stack)
	}

	// test_node_index finds a declared node's index by instance identity.
	// Returns -1 when the instance was not declared this frame.
	test_node_index :: proc(i: Instance) -> int {
		for nd, idx in g.nodes {
			if nd.identity == i {
				return idx
			}
		}
		return -1
	}

	// test_content returns the node's intrinsic content size (pass A/D).
	test_content :: proc(i: Instance) -> Vec2 {
		if idx := test_node_index(i); idx >= 0 {
			return g.lay[idx].content
		}
		return Vec2{0, 0}
	}

	// test_overflow returns the node's computed overflow extent (pass F).
	test_overflow :: proc(i: Instance) -> Vec2 {
		if idx := test_node_index(i); idx >= 0 {
			return g.lay[idx].overfl
		}
		return Vec2{0, 0}
	}

	// test_style returns a copy of a unit's live style (post any tween
	// steps / edit applies of the last frame_end).
	test_style :: proc(u: Unit) -> Style {
		return store.units[unit_index(u)].style
	}

	// test_context returns the harness's context (test_reset creates and
	// binds a fresh one per test). Tests pass it to frame_begin, whose
	// context parameter is explicit since M1.
	test_context :: proc() -> ^Context {
		return test_ctx
	}

	// test_overlay reads a unit's state-overlay slot.
	test_overlay :: proc(u: Unit, kind: Overlay_Kind) -> Unit {
		rec := &store.units[unit_index(u)]
		switch kind {
		case .Hover:    return rec.hover
		case .Press:    return rec.press
		case .Focus:    return rec.focus
		case .Disabled: return rec.disabled
		}
		return NO_UNIT
	}

	// test_focusable reads a unit's traversal flag.
	test_focusable :: proc(u: Unit) -> bool {
		return store.units[unit_index(u)].focusable
	}

	// test_text_cache_len reports how many measurements the text cache holds.
	test_text_cache_len :: proc() -> int {
		return len(store.text_cache)
	}

	// test_reset clears everything, including cold units, and re-seeds
	// the NO_UNIT sentinel: each test starts from a working empty engine.
	// test_teardown is its exit-side pair: it frees the same containers but
	// leaves NO sentinel behind, so a test ends with zero engine allocations
	// live. Tests open with test_reset() and defer test_teardown(). The
	// pairing is what keeps the runner's per-test tracking allocator honest:
	// engine state is global by design, so without it the NEXT test's reset
	// frees this test's allocations under the wrong tracker and they report
	// as leaks (still live at test end) and bad frees (freed by a tracker
	// that never allocated them).
	test_reset :: proc() {
		test_repaint_forget()
		if test_ctx != nil {
			context_destroy(test_ctx)
			test_ctx = nil
		}
		free_store()
		store = Store{}
		test_ctx = context_create()
		g = test_ctx
		append(&store.units, Unit_Rec{name = "NO_UNIT"}) // §8 sentinel at index 0
		append(&store.groups, Group_Rec{name = "NO_GROUP"})
	}

	test_teardown :: proc() {
		test_repaint_forget()
		shutdown() // destroys test_ctx with every other live context
		test_ctx = nil
	}

	// test_unit_index is a unit handle's slot index.
	test_unit_index :: proc(u: Unit) -> int {
		return unit_index(u)
	}

	// The text cache's sweep tuning, for tests that wait it out.
	TEST_TEXT_KEEP_FRAMES :: TEXT_KEEP_FRAMES
	TEST_TEXT_SWEEP_EVERY :: TEXT_SWEEP_EVERY

	// Test_Field_Row is one row of the style field table, for the test
	// that checks the table against Style and Style_Decl.
	Test_Field_Row :: struct {
		style_off, decl_off: uintptr,
		size:                int,
		id, decl_id:         typeid,
	}

	// ---- partial repaint check ----
	//
	// test_repaint_check renders this frame twice on a coarse software
	// canvas (one cell per DIP), the way a host does: once in full, and
	// once as a cache that only repaints res.repaint, clearing each rect
	// and replaying draw_list(res.repaint) clipped to it, on top of what
	// it held. It returns how many cells differ: anything but 0 means a
	// partial repaint would leave stale or missing pixels. Each rect,
	// text run and image fills its bounds with one color; clips apply;
	// opacity is ignored. Call it after frame_end. Frames that report no
	// change are skipped: no host renders them.
	test_repaint_check :: proc(res: Frame_Result) -> (mismatches: int) {
		w, h := int(g.viewport.x), int(g.viewport.y)
		if !res.changed || w <= 0 || h <= 0 {
			return 0
		}
		st, ok := test_repaint_caches[g]
		if !ok {
			st = new(Test_Repaint_Cache)
			test_repaint_caches[g] = st
		}
		full := make([]u32, w * h, context.temp_allocator)
		whole := Rect{{0, 0}, {f32(w), f32(h)}}
		test_raster(full, w, h, draw_list(), whole)
		// A first frame, or a new size, repaints in full (as the host's
		// force_render does).
		if g.frame_index <= 1 || st.w != w || st.h != h || len(res.repaint) == 0 {
			resize(&st.cells, w * h)
			copy(st.cells[:], full)
			st.w, st.h = w, h
			return 0
		}
		part := draw_list(res.repaint)
		for r in res.repaint {
			x0, x1, y0, y1 := test_cell_span(r, w, h)
			for y in y0 ..< y1 {
				for x in x0 ..< x1 {
					st.cells[y * w + x] = 0
				}
			}
			test_raster(st.cells[:], w, h, part, r)
		}
		for c, k in full {
			if st.cells[k] != c {
				mismatches += 1
			}
		}
		return
	}

	Test_Repaint_Cache :: struct {
		w, h:  int,
		cells: [dynamic]u32,
	}

	test_repaint_caches: map[^Context]^Test_Repaint_Cache

	// test_repaint_forget drops the check's caches (test_reset and
	// test_teardown call it; a test with its own contexts calls it when
	// done).
	test_repaint_forget :: proc() {
		for _, st in test_repaint_caches {
			delete(st.cells)
			free(st)
		}
		delete(test_repaint_caches)
		test_repaint_caches = nil
	}

	// test_cell_span is the cells whose centers lie in r, clamped.
	test_cell_span :: proc(r: Rect, w, h: int) -> (x0, x1, y0, y1: int) {
		first :: proc(v: f32) -> int {
			t := v - 0.5
			i := int(t)
			if f32(i) < t {
				i += 1
			}
			return i
		}
		x0 = clamp(first(r.pos.x), 0, w)
		x1 = clamp(first(r.pos.x + r.size.x), 0, w)
		y0 = clamp(first(r.pos.y), 0, h)
		y1 = clamp(first(r.pos.y + r.size.y), 0, h)
		return
	}

	test_raster :: proc(cells: []u32, w, h: int, cmds: []Draw_Cmd, region: Rect) {
		clips := make([dynamic]Rect, context.temp_allocator)
		cur := region
		pack :: proc(c: Color) -> u32 {
			return u32(c[0]) | u32(c[1]) << 8 | u32(c[2]) << 16 | u32(c[3]) << 24
		}
		for c in cmds {
			col: u32
			switch c.tag {
			case .Push_Clip:
				append(&clips, cur)
				cur = rect_intersect(cur, c.bounds)
				continue
			case .Pop_Clip:
				cur = pop(&clips)
				continue
			case .Push_Opacity, .Pop_Opacity:
				continue
			case .Rect, .Overlay:
				if c.color.a > 0 {
					col = pack(c.color)
				} else if c.border_width > 0 {
					col = pack(c.border_color)
				} else {
					continue
				}
			case .Text:
				col = pack(c.color) | 1
			case .Image:
				col = c.image * 2654435761 | 1
			}
			r := rect_intersect(c.bounds, cur)
			if r.size.x <= 0 || r.size.y <= 0 {
				continue
			}
			x0, x1, y0, y1 := test_cell_span(r, w, h)
			for y in y0 ..< y1 {
				for x in x0 ..< x1 {
					cells[y * w + x] = col
				}
			}
		}
	}

	test_field_rows :: proc() -> (rows: [Field]Test_Field_Row) {
		for m, f in FIELD_META {
			rows[f] = {m.style_off, m.decl_off, m.size, m.id, m.decl_id}
		}
		return
	}
}
