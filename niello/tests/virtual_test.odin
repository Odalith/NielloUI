package tests

import "core:testing"
import niello ".."
import virtual "../virtual"

// niello/virtual: fixed and estimated virtual lists on begin_section.

vl_root, vl_host, vl_row, vl_para: niello.Unit

Vl_Item :: struct {
	i:    int,
	inst: niello.Instance,
}

Vl_App :: struct {
	count:     int,
	estimated: bool,
	list:      virtual.List,
	host_i:    niello.Instance,
	declared:  [dynamic]Vl_Item,
}
vl_app: Vl_App

VL_TEXTS := [4]string{
	"one line",
	"a longer paragraph that wraps over two or three lines in this list",
	"x",
	"the longest of these paragraphs, written so that it wraps onto four or more lines at the list's width, which is narrow",
}

vl_build :: proc(app: ^Vl_App, s: niello.Section) {
	clear(&app.declared)
	it: virtual.Iter
	if app.estimated {
		it = virtual.estimated(&app.list, s, app.count, 100) // far off on purpose
	} else {
		it = virtual.fixed(&app.list, s, app.count, 30)
	}
	for i in virtual.next(&it) {
		inst: niello.Instance
		if app.estimated {
			inst = niello.show(vl_para, {text = VL_TEXTS[i % 4]}, key = niello.key_int(i))
		} else {
			inst = niello.show(vl_row, key = niello.key_int(i))
		}
		virtual.item(&it, inst)
		append(&app.declared, Vl_Item{i, inst})
	}
	virtual.finish(&it)
}

vl_declare :: proc() {
	if niello.begin(vl_root) {
		if niello.begin_section(vl_host, niello.builder(vl_build, &vl_app), out = &vl_app.host_i) {}
	}
}

vl_mint :: proc(gap: u16 = 0) {
	vl_app = {}
	niello.mint(&vl_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.percent(1), niello.percent(1))})
	niello.mint(&vl_host, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fixed(200), niello.fixed(300)),
		scroll = .Vertical, gap = gap,
	})
	niello.mint(&vl_row, niello.NO_UNIT, {size = niello.size(niello.grow(), niello.fixed(30)), focusable = true, color = niello.rgb(0x222222)})
	niello.mint(&vl_para, niello.NO_UNIT, {size = niello.size(niello.grow(), niello.fit()), wrap = .Word, font_size = 14, focusable = true})
}

vl_teardown :: proc() {
	delete(vl_app.declared)
	virtual.destroy(&vl_app.list)
	niello.test_teardown()
}

vl_frame :: proc(keys: []niello.Key_Event = nil, wheel := niello.Vec2{}) {
	inp := niello.Input{viewport = {400, 400}, window_focused = true, mouse = {100, 100}, mouse_valid = true, wheel = wheel}
	for ev, k in keys {
		inp.keys[k] = ev
	}
	inp.key_count = len(keys)
	niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
	vl_declare()
	niello.frame_end()
}

vl_tab :: proc(shift := false) {
	mods := shift ? niello.Modifiers{.Shift} : niello.Modifiers{}
	vl_frame([]niello.Key_Event{kev(.Tab, true, mods), kev(.Tab, false, mods)})
}

vl_inst_of :: proc(i: int) -> (niello.Instance, bool) {
	for d in vl_app.declared {
		if d.i == i {
			return d.inst, true
		}
	}
	return 0, false
}

vl_indices :: proc() -> [dynamic]int {
	out := make([dynamic]int, context.temp_allocator)
	for d in vl_app.declared {
		append(&out, d.i)
	}
	return out
}

@(test)
test_virtual_fixed_declares_the_window :: proc(t: ^testing.T) {
	niello.test_reset()
	defer vl_teardown()
	vl_mint()
	vl_app.count = 100_000
	vl_frame()
	// 300 / 30 = 10 rows in view (+1 partial edge), + 2 overscan.
	idx := vl_indices()
	testing.expect_value(t, len(idx), 13)
	for k in 0 ..< len(idx) {
		testing.expect_value(t, idx[k], k)
	}
	testing.expect(t, niello.instance_count(niello.test_context()) < 25, "only the window has instances")
	testing.expect_value(t, niello.scroll_range(vl_app.host_i), niello.Vec2{0, 100_000 * 30 - 300})
	// Far down: the window follows, and row 1000 sits at the top.
	niello.scroll_to(vl_app.host_i, {0, 30_000})
	vl_frame()
	idx = vl_indices()
	testing.expect_value(t, idx[0], 998)
	testing.expect_value(t, idx[len(idx) - 1], 1012)
	inst, ok := vl_inst_of(1000)
	r, _ := niello.rect(inst)
	testing.expect(t, ok && r.pos.y == 0, "row 1000 is at the viewport's top")
	testing.expect_value(t, niello.scroll_range(vl_app.host_i), niello.Vec2{0, 100_000 * 30 - 300})
	// scroll_to_index lands an item at the top.
	virtual.scroll_to_index(&vl_app.list, vl_app.host_i, 54_321)
	vl_frame()
	inst, ok = vl_inst_of(54_321)
	r, _ = niello.rect(inst)
	testing.expect(t, ok && r.pos.y == 0, "scroll_to_index puts the item at the top")
}

@(test)
test_virtual_fixed_with_gap :: proc(t: ^testing.T) {
	niello.test_reset()
	defer vl_teardown()
	vl_mint(gap = 10)
	vl_app.count = 1000
	niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 400}}, 1.0 / 60.0)
	vl_declare()
	niello.frame_end()
	testing.expect_value(t, niello.scroll_range(vl_app.host_i), niello.Vec2{0, 1000 * 30 + 999 * 10 - 300})
	niello.scroll_to(vl_app.host_i, {0, 400 * 40})
	vl_frame()
	inst, ok := vl_inst_of(400)
	r, _ := niello.rect(inst)
	testing.expect(t, ok && r.pos.y == 0, "with a gap, row 400 starts at 400 slots of 40")
	inst3, _ := vl_inst_of(401)
	r3, _ := niello.rect(inst3)
	testing.expect_value(t, r3.pos.y, f32(40))
}

@(test)
test_virtual_estimated_fills_and_anchors :: proc(t: ^testing.T) {
	niello.test_reset()
	defer vl_teardown()
	vl_mint()
	vl_app.count = 2000
	vl_app.estimated = true
	vl_frame()
	// The viewport is filled by real sizes in one frame: the declared
	// items' measured extents reach past the bottom, with overscan.
	last := vl_app.declared[len(vl_app.declared) - 1]
	lr, _ := niello.rect(last.inst)
	testing.expect(t, lr.pos.y >= 300, "the window reaches past the viewport")
	covered := false
	for d in vl_app.declared {
		r, _ := niello.rect(d.inst)
		if r.pos.y < 300 && r.pos.y + r.size.y >= 300 {
			covered = true
		}
	}
	testing.expect(t, covered, "an item spans the viewport's bottom edge: no gap")
	// Go deep (unmeasured territory), then wheel up a notch: the items
	// revealed above were estimated at 100 and measure far smaller, yet
	// what was on screen moves by exactly the wheel's 48.
	virtual.scroll_to_index(&vl_app.list, vl_app.host_i, 1000)
	vl_frame()
	vl_frame()
	top, ok := vl_inst_of(1000)
	before, _ := niello.rect(top)
	testing.expect(t, ok && abs(before.pos.y) < 0.01, "item 1000 at the top")
	vl_frame(wheel = {0, 1})
	after, ok2 := niello.rect(top)
	testing.expect(t, ok2, "the anchor item is still declared")
	testing.expectf(t, abs(after.pos.y - (before.pos.y + 48)) < 0.01, "the anchor moved by the wheel only: %v -> %v", before.pos.y, after.pos.y)
	// Every declared item's rect is its measured size (wrapped text at the list width).
	for d in vl_app.declared {
		r, _ := niello.rect(d.inst)
		testing.expect(t, r.size.x == 200, "items fill the list width")
	}
}

@(test)
test_virtual_focus_pins_and_tab_walks :: proc(t: ^testing.T) {
	niello.test_reset()
	defer vl_teardown()
	vl_mint()
	vl_app.count = 10_000
	vl_frame()
	// Tab walks into the list and past its window edge: each step
	// reveals the focused row, and the window follows.
	for k in 0 ..< 20 {
		vl_tab()
		vl_frame() // the reveal lands
		inst, ok := vl_inst_of(k)
		testing.expectf(t, ok && niello.focused(inst), "Tab %d focuses row %d", k, k)
	}
	// Scroll far away: row 19 keeps focus (pinned, still declared).
	niello.scroll_to(vl_app.host_i, {0, 5000 * 30})
	vl_frame()
	vl_frame()
	pinned, ok := vl_inst_of(19)
	testing.expect(t, ok && niello.focused(pinned), "the focused row stays declared and focused off-screen")
	_, far := vl_inst_of(5000)
	testing.expect(t, far, "the window is far away")
	// Tab from the pinned row goes to its neighbor, and the list comes back.
	vl_tab()
	vl_frame()
	vl_frame()
	n20, ok20 := vl_inst_of(20)
	testing.expect(t, ok20 && niello.focused(n20), "Tab reaches the pinned row's neighbor")
	r20, _ := niello.rect(n20)
	testing.expect(t, r20.pos.y >= 0 && r20.pos.y + r20.size.y <= 300, "and reveal scrolled the list back to it")
	// Shift+Tab walks back.
	vl_tab(shift = true)
	vl_frame()
	n19, _ := vl_inst_of(19)
	testing.expect(t, niello.focused(n19), "Shift+Tab goes back to row 19")
}
