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
}
