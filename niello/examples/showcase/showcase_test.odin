// showcase_test.odin — a headless smoke test of the whole showcase:
// the real declare procs, driven through synthetic input frames with
// mock text metrics and a fake image decoder (no window, no GPU).
//
//	odin test niello/examples/showcase -define:ODIN_TEST_THREADS=1
//	odin test niello/examples/showcase -define:ODIN_TEST_THREADS=1 -define:NIELLO_DEBUG=true
//
// Every page must settle: after a few idle frames nothing may still be
// changing (a page that changes every frame keeps the loop awake).
// Debug builds also check that no child draws outside its parent,
// except in the two boxes that demonstrate exactly that.
package main

import "core:fmt"
import "core:testing"
import "core:time"
import niello "../.."
import controls "../../controls"

@(private = "file")
VIEW :: niello.Vec2{1180, 780}

@(private = "file")
fake_decode :: proc(data: []byte, max_w, max_h: int) -> (backend: u32, w, h: f32, ok: bool) {
	if max_w > 0 {
		return 2, f32(max_w), f32(max_w) * 2 / 3, true
	}
	return 1, 480, 320, true
}

@(private = "file")
fake_release :: proc(backend: u32) {}

@(private = "file")
frame :: proc(app: ^App, inp: niello.Input = {}) -> niello.Frame_Result {
	inp := inp
	inp.viewport = VIEW
	inp.window_focused = true
	niello.frame_begin(app.ctx, inp, 0.016)
	declare(app)
	res := niello.frame_end()
	// Every frame of the walk: a host repainting only res.repaint must
	// end up with the same pixels as one repainting everything.
	when ODIN_TEST {
		if bad := niello.test_repaint_check(res); bad > 0 {
			repaint_mismatch_frames += 1
			repaint_mismatch_cells += bad
		}
	}
	return res
}

@(private = "file")
repaint_mismatch_frames, repaint_mismatch_cells: int

@(private = "file")
idle :: proc(app: ^App, n: int) -> niello.Frame_Result {
	res: niello.Frame_Result
	for _ in 0 ..< n {
		res = frame(app)
	}
	return res
}

@(private = "file")
center :: proc(i: niello.Instance) -> (niello.Vec2, bool) {
	r, ok := niello.rect(i)
	return r.pos + r.size / 2, ok
}

@(private = "file")
click :: proc(app: ^App, i: niello.Instance) -> bool {
	p, ok := center(i)
	if !ok {
		return false
	}
	frame(app, {mouse = p, mouse_valid = true})
	frame(app, {mouse = p, mouse_valid = true, buttons_down = {.Left}, buttons_pressed = {.Left}})
	frame(app, {mouse = p, mouse_valid = true, buttons_released = {.Left}})
	return true
}

@(private = "file")
key :: proc(app: ^App, k: niello.Key_Code) {
	inp: niello.Input
	inp.keys = {niello.Key_Event{key = k, physical = k, down = true}}
	frame(app, inp)
}

// settles checks the current screen goes quiet, and (debug builds)
// that nothing draws outside its parent except the overflow demo.
@(private = "file")
settles :: proc(t: ^testing.T, app: ^App, label: string) {
	res := idle(app, 30)
	testing.expectf(t, !res.changed, "%s: still changing after 30 idle frames", label)
	testing.expectf(t, res.next_wake_ms == max(u32), "%s: a deadline is pending while idle", label)
	when niello.NIELLO_DEBUG {
		// Every declared node has its own identity: a hash collision
		// would merge two nodes into one committed record.
		seen := make(map[niello.Instance]bool, context.temp_allocator)
		for n in niello.debug_tree(app.ctx) {
			testing.expectf(t, n.instance not_in seen, "%s: two nodes share identity %v (%s)",
				label, n.instance, niello.debug_unit_name(n.unit))
			seen[n.instance] = true
		}
		for n in niello.debug_tree(app.ctx) {
			// The spill demo overflows on purpose; a clipping box cuts its
			// excess by design (.Clip), so neither draws outside by mistake.
			if n.unit == layout_units.spill_box || .Clip in n.flags {
				continue
			}
			ox := n.overfl.x > 0.5 && .Scroll_X not_in n.flags
			oy := n.overfl.y > 0.5 && .Scroll_Y not_in n.flags
			testing.expectf(t, !ox && !oy, "%s: children draw outside %s by %v",
				label, niello.debug_unit_name(n.unit), n.overfl)
		}
	}
}

@(test)
showcase_smoke :: proc(t: ^testing.T) {
	niello.measure_word_hook = nil // mock metrics
	niello.line_height_hook = nil
	niello.decode_image_hook = fake_decode
	niello.release_image_hook = fake_release

	app: App
	app_init(&app)
	defer app_destroy(&app)
	testing.expect(t, app.images.loaded, "images load")
	idle(&app, 3)

	// Every page, both themes.
	for dark in ([]bool{true, false}) {
		if !dark {
			app.dark = false
			controls.apply_theme(LIGHT_THEME, 0)
		}
		for p in Page {
			testing.expectf(t, click(&app, app.nav_i[p]), "nav item %v has a rect", p)
			testing.expectf(t, app.page == p, "clicking nav %v selects it", p)
			settles(t, &app, PAGE_NAMES[p])
		}
	}
	when niello.NIELLO_DEBUG {
		for n in niello.debug_tree(app.ctx) {
			if n.unit == shell.sidebar {
				st, _ := niello.debug_style_in(app.ctx, n.instance)
				testing.expect(t, st.color == LIGHT_THEME.panel, "the theme broadcast reaches the sidebar")
			}
		}
	}

	// The header's text-size and spacing sliders: keyboard to the top of
	// each range, and the whole UI follows through its roles. Every page
	// still settles (debug builds: nothing draws outside its parent).
	// A slider stays where it is while its value resizes everything else:
	// at the bottom of the sidebar, in fixed geometry.
	text_r, _ := niello.rect(app.text_scale.inst)
	spacing_r, _ := niello.rect(app.spacing.inst)
	niello.focus(app.text_scale.inst)
	key(&app, .End)
	idle(&app, 2)
	testing.expect_value(t, app.text_scale.value, f32(1.75))
	text_r2, _ := niello.rect(app.text_scale.inst)
	testing.expect_value(t, text_r2, text_r)
	testing.expect_value(t, niello.style_of(ui.title).font_size, controls.DEFAULT_TYPE.title * 1.75)
	testing.expect_value(t, niello.style_of(controls.parts.button.label).font_size, controls.DEFAULT_TYPE.body * 1.75)
	niello.focus(app.spacing.inst)
	key(&app, .End)
	idle(&app, 2)
	testing.expect_value(t, app.spacing.value, f32(2))
	spacing_r2, _ := niello.rect(app.spacing.inst)
	testing.expect_value(t, spacing_r2, spacing_r)
	testing.expect_value(t, niello.style_of(ui.card).padding, niello.pad(controls.DEFAULT_SPACING.panel_pad * 2))
	testing.expect_value(t, niello.style_of(ui.card_row).gap, controls.DEFAULT_SPACING.gap * 2)
	testing.expect_value(t, niello.style_of(shell.nav_list).gap, NAV_GAP * 2)
	testing.expect_value(t, niello.style_of(shell.nav_item).padding, niello.style_of(controls.parts.button.root).padding)
	for p in Page {
		click(&app, app.nav_i[p])
		settles(t, &app, fmt.tprintf("%s, large text and spacing", PAGE_NAMES[p]))
	}
	niello.focus(app.text_scale.inst)
	key(&app, .Home)
	niello.focus(app.spacing.inst)
	key(&app, .Home)
	testing.expect_value(t, niello.style_of(ui.body).font_size, controls.DEFAULT_TYPE.body * 0.75)
	click(&app, app.nav_i[.Controls])

	// Controls: the counter button.
	click(&app, app.nav_i[.Controls])
	before := app.controls.clicks
	click(&app, app.controls.count_i)
	testing.expect_value(t, app.controls.clicks, before + 1)

	// Keyboard: focus by click, type, edit, Tab onward.
	// Layout's Wrap demo: the chips wrap onto several lines, and the
	// align buttons cycle (each click relayouts; the repaint check in
	// frame covers it).
	click(&app, app.nav_i[.Layout])
	idle(&app, 2)
	first, _ := niello.rect(app.layout.wrap_x_i)
	testing.expect(t, first.size.x > 0, "the Wrap demo is on the Layout page")
	click(&app, app.layout.wrap_x_i)
	click(&app, app.layout.wrap_x_i)
	click(&app, app.layout.wrap_y_i)
	testing.expect(t, app.layout.wrap_align == [2]niello.Align_Kind{.End, .Center}, "the align buttons cycle")

	click(&app, app.nav_i[.Input])
	click(&app, app.input.name.inst)
	testing.expect(t, niello.focused(app.input.name.inst), "a click focuses the field")
	frame(&app, {text = "Ada"})
	key(&app, .Backspace)
	testing.expect_value(t, string(app.input.name.buf[:]), "Ad")
	key(&app, .Tab)
	testing.expect(t, niello.focused(app.input.email.inst), "Tab moves to the next field")
	settles(t, &app, "input after typing")

	// Popups: menu + light dismiss, modal + Esc, toast + wake_in.
	click(&app, app.nav_i[.Popups])
	click(&app, app.popups.menu_btn_i)
	idle(&app, 2)
	testing.expect(t, app.popups.menu_open, "the menu opens")
	_, menu_ok := niello.rect(app.popups.menu_i)
	testing.expect(t, menu_ok, "the menu popup lays out")
	settles(t, &app, "menu open")
	click(&app, app.content_i)
	testing.expect(t, !app.popups.menu_open, "a click outside dismisses the menu")
	app.popups.dlg_open = true
	idle(&app, 2)
	_, dlg_ok := niello.rect(app.popups.dlg_i)
	testing.expect(t, dlg_ok, "the dialog lays out")
	settles(t, &app, "dialog open")
	key(&app, .Escape)
	idle(&app, 2)
	testing.expect(t, !app.popups.dlg_open, "Esc dismisses the dialog")
	app.popups.toast = "t"
	app.popups.toast_until = time.tick_add(time.tick_now(), 300 * time.Millisecond)
	res := frame(&app)
	testing.expect(t, res.next_wake_ms > 0 && res.next_wake_ms <= 301, "a toast schedules the frame that hides it")
	time.sleep(320 * time.Millisecond)
	idle(&app, 2)
	testing.expect(t, app.popups.toast == "", "the toast hides itself")

	// Scrolling: wheel the nested scroller to its end, then chain out.
	click(&app, app.nav_i[.Scrolling])
	niello.scroll_to(app.scrolling.list_i, {0, 150}) // bring the nested scroller into view
	idle(&app, 2)
	ir, _ := niello.rect(app.scrolling.inner_i)
	lr, _ := niello.rect(app.scrolling.list_i)
	at := niello.Vec2{ir.pos.x + 40, max(ir.pos.y, lr.pos.y) + 20}
	list_before := niello.scroll_offset(app.scrolling.list_i).y
	inner_range := niello.scroll_range(app.scrolling.inner_i).y
	inner_peak := f32(0)
	frame(&app, {mouse = at, mouse_valid = true})
	for _ in 0 ..< 12 {
		frame(&app, {mouse = at, mouse_valid = true, wheel = {0, -1}})
		inner_peak = max(inner_peak, niello.scroll_offset(app.scrolling.inner_i).y)
	}
	testing.expect(t, inner_range > 0 && inner_peak == inner_range, "the nested scroller scrolls to its end")
	testing.expect(t, niello.scroll_offset(app.scrolling.list_i).y > list_before, "leftover wheel chains to the list")
	_, thumb_ok := niello.rect(app.scrolling.list_bar.thumb_i)
	testing.expect(t, thumb_ok, "the list's scrollbar is declared")

	// Virtual lists: only the window is declared, the scroll range is
	// the whole list, the wheel moves the window, and the estimated
	// list fills its viewport.
	click(&app, app.nav_i[.Virtual])
	idle(&app, 2)
	testing.expect(t, app.virt.fixed_declared > 0 && app.virt.fixed_declared < 30, "the fixed list declares only its window")
	testing.expect(t, app.virt.est_declared > 0 && app.virt.est_declared < 40, "the estimated list declares only its window")
	vr, vr_ok := niello.rect(app.virt.fixed_i)
	testing.expect(t, vr_ok, "the fixed list lays out")
	testing.expect(t, niello.scroll_range(app.virt.fixed_i).y > FIXED_ROWS * ROW_H - vr.size.y, "the range covers every row")
	vat := vr.pos + vr.size / 2
	frame(&app, {mouse = vat, mouse_valid = true})
	for _ in 0 ..< 10 {
		frame(&app, {mouse = vat, mouse_valid = true, wheel = {0, -1}})
	}
	idle(&app, 20) // let the smooth glide land
	testing.expect(t, niello.scroll_offset(app.virt.fixed_i).y > 400, "the wheel scrolls the fixed list")
	testing.expect(t, app.virt.fixed_declared < 30, "and the window stays small")
	_, vthumb := niello.rect(app.virt.fixed_bar.thumb_i)
	testing.expect(t, vthumb, "the virtual list's scrollbar is declared")
	settles(t, &app, "virtual lists")

	// Drag: move the chip.
	click(&app, app.nav_i[.Drag])
	p0, chip_ok := center(app.drag.chip_i)
	testing.expect(t, chip_ok, "the chip lays out")
	start := app.drag.chip_pos
	frame(&app, {mouse = p0, mouse_valid = true})
	frame(&app, {mouse = p0, mouse_valid = true, buttons_down = {.Left}, buttons_pressed = {.Left}})
	for k in 1 ..= 10 {
		frame(&app, {mouse = p0 + {f32(k) * 8, f32(k) * 3}, mouse_valid = true, buttons_down = {.Left}})
	}
	frame(&app, {mouse = p0 + {80, 30}, mouse_valid = true, buttons_released = {.Left}})
	testing.expect(t, app.drag.chip_pos.x >= start.x + 60, "dragging moves the chip")
	settles(t, &app, "after a drag")

	// The slider: a click seeks, arrows step, and Space/Enter (key
	// activation presses it too) must not seek it back to the pointer.
	testing.expect(t, click(&app, app.drag.volume.inst), "the slider lays out")
	seeked := app.drag.volume.value
	key(&app, .Right)
	key(&app, .Right)
	stepped := app.drag.volume.value
	testing.expect(t, abs(stepped - (seeked + 0.1)) < 1e-4, "two Right presses step the slider")
	key(&app, .Space)
	frame(&app, {keys = {niello.Key_Event{key = .Space, physical = .Space, down = false}}})
	key(&app, .Enter)
	frame(&app, {keys = {niello.Key_Event{key = .Enter, physical = .Enter, down = false}}})
	testing.expect_value(t, app.drag.volume.value, stepped)

	// Async: a worker's progress arrives through the inbox.
	click(&app, app.nav_i[.Async_Windows])
	async_start(&app.async)
	for _ in 0 ..< 300 {
		frame(&app)
		if !app.async.running {
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, app.async.pct == 100 && app.async.last == "finished", "the job completes through the inbox")
	settles(t, &app, "async done")

	testing.expectf(t, repaint_mismatch_frames == 0,
		"partial repaint matches a full repaint on every frame (%d frames, %d cells differ)",
		repaint_mismatch_frames, repaint_mismatch_cells)
	when ODIN_TEST {
		niello.test_repaint_forget()
	}
}
