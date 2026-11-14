package tests

import "core:testing"
import niello ".."

// Deferred sections (begin_section): a host laid out with the tree,
// whose flow children a build declares after the main layout, with the
// host's exact bounds.

sec_root, sec_host, sec_row, sec_chrome, sec_btn, sec_inner_host, sec_leaf, sec_pop: niello.Unit

Sec_App :: struct {
	rows:       int,
	seen:       niello.Section,
	builds:     int,
	host_i:     niello.Instance,
	row_i:      [16]niello.Instance,
	chrome_i:   niello.Instance,
	before_i:   niello.Instance,
	after_i:    niello.Instance,
	clicked:    int,
	nested:     bool,
	nested_i:   niello.Instance,
	nested_leaf: niello.Instance,
	nested_seen: niello.Section,
	popup:      bool,
	popup_i:    niello.Instance,
	scroll_in_declare: Maybe(niello.Vec2),
}
sec_app: Sec_App

sec_mint :: proc() {
	sec_app = {}
	niello.mint(&sec_root, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.percent(1), niello.percent(1)),
		padding = niello.pad(20), gap = 10,
	})
	niello.mint(&sec_host, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fixed(200), niello.grow()),
		padding = niello.pad(5), scroll = .Vertical,
	})
	niello.mint(&sec_row, niello.NO_UNIT, {
		size = niello.size(niello.grow(), niello.fixed(30)), color = niello.rgb(0x334455), focusable = true,
	})
	niello.mint(&sec_chrome, niello.NO_UNIT, {
		size = niello.size(niello.fixed(8), niello.fixed(20)), color = niello.rgb(0xaa0000),
		align = niello.align(.End, .Start),
	})
	niello.mint(&sec_btn, niello.NO_UNIT, {size = niello.size(niello.fixed(80), niello.fixed(20)), focusable = true})
	niello.mint(&sec_inner_host, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.grow(), niello.fixed(40))})
	niello.mint(&sec_leaf, niello.NO_UNIT, {size = niello.size(niello.fixed(10), niello.fixed(10)), color = niello.rgb(0x00aa00)})
	niello.mint(&sec_pop, niello.NO_UNIT, {size = niello.size(niello.fixed(50), niello.fixed(50)), color = niello.rgb(0x0000aa)})
	sec_app.rows = 10
}

sec_build :: proc(app: ^Sec_App, s: niello.Section) {
	app.seen = s
	app.builds += 1
	for k in 0 ..< app.rows {
		app.row_i[k] = niello.show(sec_row, key = niello.key_int(k))
		if niello.clicked(app.row_i[k]) {
			app.clicked = k
		}
	}
	if app.nested {
		if niello.begin_section(sec_inner_host, niello.builder(sec_build_nested, app), out = &app.nested_i) {}
	}
	if app.popup {
		if niello.begin_popup(sec_pop, app.host_i, .Below, out = &app.popup_i) {}
	}
}

sec_build_nested :: proc(app: ^Sec_App, s: niello.Section) {
	app.nested_seen = s
	app.nested_leaf = niello.show(sec_leaf)
}

sec_declare :: proc() {
	app := &sec_app
	if niello.begin(sec_root) {
		app.before_i = niello.show(sec_btn)
		if off, ok := app.scroll_in_declare.?; ok {
			niello.scroll_to(app.host_i, off)
			app.scroll_in_declare = nil
		}
		if niello.begin_section(sec_host, niello.builder(sec_build, app), out = &app.host_i) {
			app.chrome_i = niello.show(sec_chrome, {anchored = true})
		}
		app.after_i = niello.show(sec_btn)
	}
}

sec_frame :: proc(view := niello.Vec2{400, 300}, keys: []niello.Key_Event = nil, mouse: Maybe(niello.Vec2) = nil, press := false) -> niello.Frame_Result {
	inp := niello.Input{viewport = view, window_focused = true}
	if p, ok := mouse.?; ok {
		inp.mouse = p
		inp.mouse_valid = true
		if press {
			inp.buttons_pressed = {.Left}
			inp.buttons_down = {.Left}
		}
	}
	inp.keys = keys
	niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
	sec_declare()
	return niello.frame_end()
}

@(test)
test_section_build_sees_exact_bounds :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sec_mint()
	sec_frame()
	testing.expect_value(t, sec_app.builds, 1)
	// The root is 400x300 with padding 20: before (20 tall) + gap 10, then
	// the host takes the rest of the column: 300 - 40 - 20 - 20 - 2*10 = 200.
	host_r := niello.Rect{{20, 50}, {200, 200}}
	testing.expect_value(t, sec_app.seen.rect, host_r)
	testing.expect_value(t, sec_app.seen.content, niello.Rect{{25, 55}, {190, 190}})
	testing.expect_value(t, sec_app.seen.visible, host_r)
	testing.expect_value(t, sec_app.seen.offset, niello.Vec2{0, 0})
	testing.expect_value(t, sec_app.seen.host, sec_app.host_i)
	r0, ok0 := niello.rect(sec_app.row_i[0])
	testing.expect(t, ok0 && r0 == niello.Rect{{25, 55}, {190, 30}}, "row 0 sits at the content origin, full width")
	// 10 rows of 30 in a 190 content box: range 110.
	testing.expect_value(t, niello.scroll_range(sec_app.host_i), niello.Vec2{0, 110})

	// A window resize reaches the build in the same frame: no lag.
	sec_frame({400, 250})
	testing.expect_value(t, sec_app.seen.rect.size, niello.Vec2{200, 150})
	testing.expect_value(t, niello.scroll_range(sec_app.host_i), niello.Vec2{0, 160})

	// So does a declare-time scroll_to: the build sees the offset the
	// frame renders with, and the rows move by it.
	sec_app.scroll_in_declare = niello.Vec2{0, 50}
	sec_frame({400, 250})
	testing.expect_value(t, sec_app.seen.offset, niello.Vec2{0, 50})
	r0b, _ := niello.rect(sec_app.row_i[0])
	testing.expect_value(t, r0b.pos.y, f32(55 - 50))
	// The stored offset survives steady frames (the empty host never
	// clamps it in the main layout).
	for _ in 0 ..< 3 {
		sec_frame({400, 250})
	}
	testing.expect_value(t, niello.scroll_offset(sec_app.host_i), niello.Vec2{0, 50})
	// A steady section damages nothing.
	res := sec_frame({400, 250})
	testing.expect(t, !res.changed, "a steady section frame is clean")
}

@(test)
test_section_children_in_tree_order :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sec_mint()
	sec_app.rows = 3
	sec_frame()
	sec_frame()
	// Paint: the rows (build) before the chrome (block), which paints above.
	rows_at, chrome_at := -1, -1
	r2, _ := niello.rect(sec_app.row_i[2])
	rc, _ := niello.rect(sec_app.chrome_i)
	for cmd, k in niello.draw_list() {
		if cmd.tag == .Rect && cmd.bounds == r2 { rows_at = k }
		if cmd.tag == .Rect && cmd.bounds == rc { chrome_at = k }
	}
	testing.expect(t, rows_at >= 0 && chrome_at > rows_at, "section content paints before the host's chrome")
	// The chrome is anchored by the host's align (start, start).
	testing.expect_value(t, rc.pos, niello.Vec2{20, 50})
	// Tab: before, the three rows, after — the build's children sit in
	// tree order between the host's siblings.
	want := []niello.Instance{sec_app.before_i, sec_app.row_i[0], sec_app.row_i[1], sec_app.row_i[2], sec_app.after_i}
	for w, k in want {
		sec_frame(keys = []niello.Key_Event{kev(.Tab, true), kev(.Tab, false)})
		testing.expectf(t, niello.focused(w), "Tab %d reaches stop %d", k, k)
	}
	// Hit testing and interaction queries reach section children; the
	// build reads clicked() like declare code does.
	r1, _ := niello.rect(sec_app.row_i[1])
	p := r1.pos + r1.size / 2
	sec_frame(mouse = p)
	testing.expect(t, niello.hovered(sec_app.row_i[1]), "a section row is hovered")
	sec_frame(mouse = p, press = true)
	inp := niello.Input{viewport = {400, 300}, window_focused = true, mouse = p, mouse_valid = true, buttons_released = {.Left}}
	niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
	sec_declare()
	niello.frame_end()
	testing.expect_value(t, sec_app.clicked, 1)
}

@(test)
test_section_identity_is_stable_and_salted :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sec_mint()
	sec_frame()
	first := sec_app.row_i
	sec_frame()
	sec_frame()
	testing.expect(t, first == sec_app.row_i, "section children keep their identities frame to frame")
	// A row in the build and a row in an ordinary container under the
	// same key differ: the build's parent hash is salted.
	for k in 0 ..< sec_app.rows {
		testing.expect(t, sec_app.row_i[k] != sec_app.chrome_i, "build and block children never collide")
	}
	seen := map[niello.Instance]bool{}
	defer delete(seen)
	for k in 0 ..< sec_app.rows {
		seen[sec_app.row_i[k]] = true
	}
	testing.expect_value(t, len(seen), sec_app.rows)
}

@(test)
test_section_nests_and_hosts_popups :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sec_mint()
	sec_app.rows = 2
	sec_app.nested = true
	sec_app.popup = true
	sec_frame()
	sec_frame()
	// The nested section is built after its parent's, inside its host.
	nr, ok := niello.rect(sec_app.nested_i)
	testing.expect(t, ok, "the nested host commits")
	testing.expect_value(t, sec_app.nested_seen.rect, nr)
	lr, lok := niello.rect(sec_app.nested_leaf)
	testing.expect(t, lok && lr.pos == nr.pos, "the nested build's leaf sits in the nested host")
	// Rows, then the nested host, in flow.
	r1, _ := niello.rect(sec_app.row_i[1])
	testing.expect_value(t, nr.pos.y, r1.pos.y + 30)
	// A popup declared in a build lays out against its anchor.
	pr, pok := niello.rect(sec_app.popup_i)
	hr, _ := niello.rect(sec_app.host_i)
	testing.expect(t, pok && pr.pos.y == hr.pos.y + hr.size.y, "the build's popup sits below its anchor")
}

// A section inside a popup that is not shown is never built.
secp_app: Sec_App
secp_declare :: proc() {
	if niello.begin_popup(sec_pop, niello.Instance(0xbad), .Below) {
		if niello.begin_section(sec_host, niello.builder(sec_build, &secp_app)) {}
	} else {
		if niello.begin_section(sec_host, niello.builder(sec_build, &secp_app)) {}
	}
}

@(test)
test_section_in_unshown_popup_never_builds :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	sec_mint()
	secp_app = {}
	for _ in 0 ..< 3 {
		niello.frame_begin(niello.test_context(), niello.Input{viewport = {400, 300}}, 1.0 / 60.0)
		secp_declare()
		niello.frame_end()
	}
	testing.expect_value(t, secp_app.builds, 0)
}

// ---- measure / scroll_shift -----------------------------------------------

ms_host, ms_para, ms_card, ms_line: niello.Unit

Ms_App :: struct {
	host_i:   niello.Instance,
	items:    [dynamic]niello.Instance,
	measured: [dynamic]niello.Vec2,
	fill:     bool, // declare until the visible height is filled
	filled:   int,
	shift:    f32,  // scroll_shift the host by this inside the build
	seen:     niello.Section,
	first_y:  f32,
}
ms_app: Ms_App

MS_TEXT := [3]string{
	"short",
	"a paragraph long enough to wrap onto several lines at this width, which is the point",
	"medium length text that wraps once or twice",
}

ms_build :: proc(app: ^Ms_App, s: niello.Section) {
	app.seen = s
	clear(&app.items)
	clear(&app.measured)
	used := f32(0)
	for k in 0 ..< 40 {
		inst: niello.Instance
		if k % 2 == 0 {
			inst = niello.show(ms_para, {text = MS_TEXT[k % 3]}, key = niello.key_int(k))
		} else {
			if niello.begin(ms_card, key = niello.key_int(k), out = &inst) {
				for _ in 0 ..< 1 + k % 3 {
					niello.show(ms_line)
				}
			}
		}
		sz := niello.measure(inst)
		append(&app.items, inst)
		append(&app.measured, sz)
		used += sz.y
		if app.fill && used >= s.visible.size.y {
			app.filled = k + 1
			break
		}
	}
	if app.shift != 0 {
		niello.scroll_shift(s.host, {0, app.shift})
		app.shift = 0
	}
}

ms_declare :: proc() {
	if niello.begin(sec_root) {
		if niello.begin_section(ms_host, niello.builder(ms_build, &ms_app), out = &ms_app.host_i) {}
	}
}

ms_mint :: proc() {
	ms_app = {}
	niello.mint(&sec_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.percent(1), niello.percent(1))})
	niello.mint(&ms_host, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fixed(200), niello.fixed(150)),
		padding = niello.pad(10), scroll = .Vertical, smooth_scroll = true, smooth_ms = u16(100),
	})
	niello.mint(&ms_para, niello.NO_UNIT, {size = niello.size(niello.grow(), niello.fit()), wrap = .Word, font_size = 14})
	// Grow on the main axis measures as Fit.
	niello.mint(&ms_card, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.grow(), niello.grow()), padding = niello.pad(4), gap = 2})
	niello.mint(&ms_line, niello.NO_UNIT, {size = niello.size(niello.grow(), niello.fixed(12))})
}

ms_frame :: proc(wheel := niello.Vec2{}) {
	inp := niello.Input{viewport = {400, 300}, window_focused = true, mouse = {50, 50}, mouse_valid = true, wheel = wheel}
	niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
	ms_declare()
	niello.frame_end()
}

@(test)
test_measure_is_the_final_size :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	defer delete(ms_app.items)
	defer delete(ms_app.measured)
	ms_mint()
	ms_frame()
	testing.expect_value(t, len(ms_app.items), 40)
	wrapped := false
	for inst, k in ms_app.items {
		r, ok := niello.rect(inst)
		testing.expectf(t, ok && r.size == ms_app.measured[k], "item %d: measured %v, laid out %v", k, ms_app.measured[k], r.size)
		testing.expectf(t, r.size.x == 180, "item %d fills the 180 content width", k)
		if k % 2 == 0 && r.size.y > 20 {
			wrapped = true
		}
	}
	testing.expect(t, wrapped, "the long paragraphs wrapped at the content width")
	// The card (Grow height) measured to its content: 4 + n*12 + (n-1)*2 + 4.
	testing.expect_value(t, ms_app.measured[1].y, f32(8 + 2 * 12 + 2))
}

@(test)
test_measure_fills_the_viewport :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	defer delete(ms_app.items)
	defer delete(ms_app.measured)
	ms_mint()
	ms_app.fill = true
	ms_frame()
	used := f32(0)
	for m in ms_app.measured[:ms_app.filled - 1] {
		used += m.y
	}
	testing.expect(t, ms_app.filled > 0 && used < 150 && used + ms_app.measured[ms_app.filled - 1].y >= 150,
		"the build stops exactly once the visible height is covered")
}

@(test)
test_scroll_shift_moves_offset_and_glide :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	defer delete(ms_app.items)
	defer delete(ms_app.measured)
	ms_mint()
	ms_frame()
	ms_frame()
	niello.scroll_to(ms_app.host_i, {0, 100})
	ms_frame()
	// Inside the build, the shift applies to this frame's layout.
	ms_app.shift = 20
	ms_frame()
	testing.expect_value(t, niello.scroll_offset(ms_app.host_i), niello.Vec2{0, 120})
	r0, _ := niello.rect(ms_app.items[0])
	testing.expect_value(t, r0.pos.y, f32(10 - 120))
	// A wheel glide in flight moves with the shift: it lands on its
	// target plus the shift.
	ms_frame(wheel = {0, -1}) // one notch down: target 120 + 48
	ms_frame()
	ms_app.shift = 30
	ms_frame()
	for _ in 0 ..< 20 {
		ms_frame()
	}
	testing.expect_value(t, niello.scroll_offset(ms_app.host_i), niello.Vec2{0, 120 + 48 + 30})
}
