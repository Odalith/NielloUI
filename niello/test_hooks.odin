// test_hooks.odin — test-only introspection for the test suite in tests/.
//
// These are NOT part of the stable public API (see public.odin). They exist
// so black-box tests can assert on white-box state: generations, dirty sets,
// prototypes, culling. Do not call them from application code.
package niello

// test_generation returns the global mutation generation (§8).
test_generation :: proc() -> u64 {
	return store.gen
}

// test_dirty returns the unit's dirty field set (§8).
test_dirty :: proc(u: Unit) -> Fields {
	return store.units[int(u)].dirty
}

// test_proto returns the unit's prototype (NO_UNIT if none).
test_proto :: proc(u: Unit) -> Unit {
	return store.units[int(u)].proto
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
	return store.units[int(u)].style
}

// test_context returns the harness's context (test_reset creates and
// binds a fresh one per test). Tests pass it to frame_begin, whose
// context parameter is explicit since M1.
test_context :: proc() -> ^Context {
	return test_ctx
}
