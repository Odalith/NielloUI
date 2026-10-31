// Headless tests for the accessibility mirror (niello/a11y.odin,
// TODO #23 M1). The harness declares trees and asserts on the
// mirror exactly as an exporter or the #45 harness would read it.
package tests

import niello ".."
import "core:testing"

// ---- shared units

a11y_root, a11y_btn, a11y_lbl, a11y_slider, a11y_wrap: niello.Unit
a11y_btn_i: niello.Instance // package global: nested declare procs cannot capture locals

a11y_mint :: proc() {
	niello.mint(
		&a11y_root,
		niello.NO_UNIT,
		{
			layout = niello.Layout.Top_To_Bottom,
			size = niello.Size{niello.fixed(400), niello.fixed(300)},
		},
	)
	niello.mint(
		&a11y_btn,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(120), niello.fixed(40)}},
	)
	niello.mint(
		&a11y_lbl,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(120), niello.fixed(40)}},
	)
	niello.mint(
		&a11y_slider,
		niello.NO_UNIT,
		{size = niello.Size{niello.fixed(200), niello.fixed(30)}},
	)
	niello.mint(
		&a11y_wrap,
		niello.NO_UNIT,
		{
			layout = niello.Layout.Top_To_Bottom,
			size = niello.Size{niello.fixed(200), niello.fixed(100)},
			scroll = niello.Scroll.Vertical,
		},
	)
}

a11y_frame :: proc(declare: proc()) {
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 0.016)
	declare()
	niello.frame_end()
}

@(test)
test_a11y_role_label_description :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(
				a11y_btn,
				0,
				{
					role = .Button,
					label = "Play",
					description = "Start playback",
				},
			)
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree) == 1, "only the declared node is mirrored")
	if len(tree) != 1 {
		return
	}
	nd := tree[0]
	testing.expect(t, nd.role == .Button, "role is carried")
	testing.expect(t, nd.name == "Play", "label is the accessible name")
	testing.expect(t, nd.description == "Start playback", "description is carried")
	testing.expect(t, nd.parent == -1, "root of the mirror has no parent")
	testing.expect(t, nd.unit == a11y_btn, "unit is carried")
	testing.expect(
		t,
		abs(nd.rect.size.x-120) < EPS && abs(nd.rect.size.y-40) < EPS,
		"rect is the committed rect",
	)
}

@(test)
test_a11y_name_falls_back_to_text :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(a11y_btn, 0, {role = .Button, text = "Stop"})
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree) == 1, "one node mirrored")
	if len(tree) == 1 {
		testing.expect(t, tree[0].name == "Stop", "name falls back to node text")
	}
}

@(test)
test_a11y_name_falls_back_to_subtree_text :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			// Button is a container; its name lives on the label child.
			if _, ok2 := niello.begin(a11y_btn, 0, {role = .Button}); ok2 {
				niello.show(a11y_lbl, 0, {text = "Next"})
			}
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree) == 1, "label child has no semantics of its own")
	if len(tree) == 1 {
		testing.expect(t, tree[0].name == "Next", "name falls back to subtree text")
	}
}

@(test)
test_a11y_undeclared_nodes_absent :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			// Neither the wrap nor the plain child declares semantics;
			// only the button inside the wrap is mirrored, and its
			// mirror parent skips the undeclared wrap.
			if _, ok2 := niello.begin(a11y_wrap); ok2 {
				niello.show(a11y_btn, 0, {role = .Button, label = "In wrap"})
			}
			niello.show(a11y_lbl, 0, {text = "plain"})
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree) == 1, "only the declared node is mirrored")
	if len(tree) == 1 {
		testing.expect(t, tree[0].parent == -1, "parent skips undeclared ancestors")
		testing.expect(t, tree[0].name == "In wrap", "declared child keeps its name")
	}
}

@(test)
test_a11y_value_and_flags :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(
				a11y_slider,
				0,
				{
					role = .Slider,
					label = "Volume",
					value = niello.A11y_Value{num = 75, has_num = true, min = 0, max = 130},
					a11y_flags = {.Selected},
				},
			)
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree) == 1, "one node mirrored")
	if len(tree) != 1 {
		return
	}
	testing.expect(t, tree[0].value.has_num, "value carries has_num")
	testing.expect(t, abs(tree[0].value.num-75) < EPS, "value carries the number")
	testing.expect(t, abs(tree[0].value.min-0) < EPS, "value carries min")
	testing.expect(t, abs(tree[0].value.max-130) < EPS, "value carries max")
	testing.expect(t, .Selected in tree[0].flags, "flags carry Selected")
	testing.expect(t, !(.Checked in tree[0].flags), "unset flags stay unset")
}

@(test)
test_a11y_incremental_stability :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	// Frame 1: button "Alpha", slider "X".
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(a11y_btn, 0, {role = .Button, label = "Alpha"})
			niello.show(a11y_slider, 0, {role = .Slider, label = "X"})
		}
	})
	tree1 := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree1) == 2, "two nodes mirrored")
	if len(tree1) != 2 {
		return
	}
	btn_name_ptr := raw_data(tree1[0].name)
	// Frame 2: the button is unchanged, the slider's label moves.
	// The button's payload must not be rebuilt (F4): its name
	// storage pointer is stable across the frame.
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(a11y_btn, 0, {role = .Button, label = "Alpha"})
			niello.show(a11y_slider, 0, {role = .Slider, label = "Yankee"})
		}
	})
	tree2 := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree2) == 2, "two nodes mirrored after the change")
	if len(tree2) == 2 {
		testing.expect(
			t,
			raw_data(tree2[0].name) == btn_name_ptr,
			"unchanged node's name storage is not re-cloned (F4 incremental)",
		)
		testing.expect(t, tree2[1].name == "Yankee", "changed node is re-read")
	}
}

@(test)
test_a11y_states :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	// Frame 1: plain declared button — no engine state.
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(a11y_btn, 0, {role = .Button, label = "A"})
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	if len(tree) == 1 {
		testing.expect(t, tree[0].state == {}, "no state on a plain node")
	}
	// Frame 2: disabled — the Disabled state appears.
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(a11y_btn, 0, {role = .Button, label = "A", disabled = true})
		}
	})
	tree = niello.a11y_tree(niello.test_context())
	if len(tree) == 1 {
		testing.expect(t, .Disabled in tree[0].state, "disabled node reports Disabled")
	}
	// Frame 3: the node leaves the tree — the mirror empties.
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
		}
	})
	tree = niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree) == 0, "removed node leaves the mirror")
}

@(test)
test_a11y_focused_state :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			a11y_btn_i = niello.show(a11y_btn, 0, {role = .Button, label = "A", focusable = true})
		}
	})
	niello.focus(a11y_btn_i)
	a11y_frame(proc() {
		if _, ok := niello.begin(a11y_root); ok {
			niello.show(a11y_btn, 0, {role = .Button, label = "A", focusable = true})
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	if len(tree) == 1 {
		testing.expect(t, .Focused in tree[0].state, "focused node reports Focused")
		testing.expect(t, .Focusable in tree[0].state, "focusable node reports Focusable")
	}
}

@(test)
test_a11y_parent_links :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	a11y_mint()
	a11y_frame(proc() {
		// Group > Group > Button, all declared: parents chain.
		if _, ok := niello.begin(a11y_root, 0, {role = .Group, label = "outer"}); ok {
			if _, ok2 := niello.begin(a11y_wrap, 0, {role = .Group, label = "inner"}); ok2 {
				niello.show(a11y_btn, 0, {role = .Button, label = "Go"})
			}
		}
	})
	tree := niello.a11y_tree(niello.test_context())
	testing.expect(t, len(tree) == 3, "three declared nodes mirrored")
	if len(tree) == 3 {
		testing.expect(t, tree[0].parent == -1, "outer group is a root")
		testing.expect(t, tree[1].parent == 0, "inner group parents to outer")
		testing.expect(t, tree[2].parent == 1, "button parents to inner")
		testing.expect(t, tree[0].role == .Group && tree[2].role == .Button, "roles in order")
	}
}
