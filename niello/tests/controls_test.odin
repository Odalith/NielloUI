package tests

import "core:testing"
import niello ".."
import controls "../controls"

// niello/controls: the shipped control collection.

ct_root: niello.Unit

Ct_App :: struct {
	save, del, off:     niello.Instance,
	clicks_save:        int,
	clicks_off:         int,
	bold:               bool,
	wifi:               bool,
	bold_changed:       bool,
	wifi_changed:       bool,
	declare_extra:      proc(app: ^Ct_App),
}
ct_app: Ct_App

ct_setup :: proc() {
	ct_app = {}
	controls.init()
	niello.mint(&ct_root, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.percent(1), niello.percent(1)),
		padding = niello.pad(10), gap = 8,
	})
}

ct_declare_buttons :: proc() {
	app := &ct_app
	if niello.begin(ct_root) {
		app.save = controls.button("Save", .Primary)
		app.del = controls.button("Delete", .Danger)
		app.off = controls.button("Off", disabled = true)
		app.bold_changed = controls.toggle_button("Bold", &app.bold)
		app.wifi_changed = controls.toggle_switch("Wi-Fi", &app.wifi)
		if niello.clicked(app.save) {
			app.clicks_save += 1
		}
		if niello.clicked(app.off) {
			app.clicks_off += 1
		}
		if app.declare_extra != nil {
			app.declare_extra(app)
		}
	}
}

ct_frame :: proc(declare: proc(), mouse: Maybe(niello.Vec2) = nil, press := false, release := false, keys: []niello.Key_Event = nil, text := "", clicks: u8 = 0) {
	inp := niello.Input{viewport = {500, 400}, window_focused = true, clicks = clicks, text = text}
	if p, ok := mouse.?; ok {
		inp.mouse = p
		inp.mouse_valid = true
	}
	if press {
		inp.buttons_pressed = {.Left}
		inp.buttons_down = {.Left}
	}
	if release {
		inp.buttons_released = {.Left}
	}
	for ev, k in keys {
		inp.keys[k] = ev
	}
	inp.key_count = len(keys)
	niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
	declare()
	niello.frame_end()
}

ct_center :: proc(i: niello.Instance) -> niello.Vec2 {
	r, _ := niello.rect(i)
	return r.pos + r.size / 2
}

ct_click :: proc(declare: proc(), i: niello.Instance, clicks: u8 = 1) {
	p := ct_center(i)
	ct_frame(declare, mouse = p)
	ct_frame(declare, mouse = p, press = true, clicks = clicks)
	ct_frame(declare, mouse = p, release = true)
}

ct_a11y :: proc(i: niello.Instance) -> (niello.A11y_Node, bool) {
	for n in niello.a11y_tree(niello.test_context()) {
		if n.instance == i {
			return n, true
		}
	}
	return {}, false
}

ct_fill_at :: proc(i: niello.Instance) -> niello.Color {
	r, _ := niello.rect(i)
	for cmd in niello.draw_list() {
		if cmd.tag == .Rect && cmd.bounds == r {
			return cmd.color
		}
	}
	return {}
}

@(test)
test_controls_buttons :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ct_setup()
	ct_frame(ct_declare_buttons)
	ct_frame(ct_declare_buttons)
	// Kinds are surfaces from the theme.
	testing.expect_value(t, ct_fill_at(ct_app.save), controls.DARK.accent)
	testing.expect_value(t, ct_fill_at(ct_app.del), controls.DARK.danger)
	// A click counts once.
	ct_click(ct_declare_buttons, ct_app.save)
	testing.expect_value(t, ct_app.clicks_save, 1)
	// Hovering the primary button lights it with accent_hot.
	ct_frame(ct_declare_buttons, mouse = ct_center(ct_app.save))
	ct_frame(ct_declare_buttons, mouse = ct_center(ct_app.save))
	testing.expect_value(t, ct_fill_at(ct_app.save), controls.DARK.accent_hot)
	// Space activates the focused button.
	niello.focus(ct_app.save)
	ct_frame(ct_declare_buttons, keys = []niello.Key_Event{kev(.Space, true)})
	ct_frame(ct_declare_buttons, keys = []niello.Key_Event{kev(.Space, false)})
	testing.expect_value(t, ct_app.clicks_save, 2)
	// A disabled button does not click and is not a Tab stop.
	ct_click(ct_declare_buttons, ct_app.off)
	testing.expect_value(t, ct_app.clicks_off, 0)
	// a11y: role and name.
	n, ok := ct_a11y(ct_app.save)
	testing.expect(t, ok && n.role == .Button && n.name == "Save", "a button reports Button and its text")
}

@(test)
test_controls_toggle_and_switch :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ct_setup()
	ct_frame(ct_declare_buttons)
	ct_frame(ct_declare_buttons)
	// Tab order: Save, Delete, Bold, Wi-Fi (Off is disabled).
	stops := 0
	for k in 0 ..< 3 {
		ct_frame(ct_declare_buttons, keys = []niello.Key_Event{kev(.Tab, true), kev(.Tab, false)})
		_ = k
		stops += 1
	}
	// Focus is on Bold now (third stop): Space toggles it.
	ct_frame(ct_declare_buttons, keys = []niello.Key_Event{kev(.Space, true)})
	ct_frame(ct_declare_buttons, keys = []niello.Key_Event{kev(.Space, false)})
	testing.expect(t, ct_app.bold, "Space flips the focused toggle button on")
	testing.expect(t, ct_app.bold_changed, "and reports the change")
	// The switch flips by pointer, and reports Checked.
	sw: niello.Instance
	for n in niello.a11y_tree(niello.test_context()) {
		if n.name == "Wi-Fi" {
			sw = n.instance
		}
	}
	testing.expect(t, sw != 0, "the switch is in the a11y tree")
	ct_click(ct_declare_buttons, sw)
	testing.expect(t, ct_app.wifi, "a click turns the switch on")
	ct_frame(ct_declare_buttons)
	n, _ := ct_a11y(sw)
	testing.expect(t, n.role == .CheckBox && .Checked in n.flags, "the switch reports CheckBox, Checked")
	ct_click(ct_declare_buttons, sw)
	testing.expect(t, !ct_app.wifi, "and off again")
	_ = stops
}

@(test)
test_controls_switch_knob_and_theme :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	ct_setup()
	ct_frame(ct_declare_buttons)
	ct_frame(ct_declare_buttons)
	// The knob: the 16x16 on_accent rect.
	knob_rect :: proc() -> (niello.Rect, bool) {
		for cmd in niello.draw_list() {
			if cmd.tag == .Rect && cmd.color == controls.DARK.on_accent && cmd.bounds.size == {16, 16} {
				return cmd.bounds, true
			}
		}
		return {}, false
	}
	off_r, ok := knob_rect()
	testing.expect(t, ok, "the knob paints")
	ct_app.wifi = true
	ct_frame(ct_declare_buttons)
	on_r, _ := knob_rect()
	testing.expect_value(t, on_r.pos.x - off_r.pos.x, f32(controls.SWITCH_W - 4 - 16))
	// apply_theme re-themes every control through the role groups.
	controls.apply_theme(controls.LIGHT)
	ct_frame(ct_declare_buttons)
	testing.expect_value(t, ct_fill_at(ct_app.save), controls.LIGHT.accent)
	testing.expect_value(t, ct_fill_at(ct_app.del), controls.LIGHT.danger)
}

// ---- text box ---------------------------------------------------------------
// Mock metrics: 7 DIP per byte at the box's 14 px. The root is 500 wide
// with padding 10, so a box is 480 wide; its padding is 10 (text starts
// 10 in).

Tb_App :: struct {
	tb, ro:    controls.Text_Box,
	submitted: bool,
	changed:   bool,
}
tb_app: Tb_App

tb_declare :: proc() {
	app := &tb_app
	if niello.begin(ct_root) {
		r := controls.text_box(&app.tb, "Name")
		app.submitted |= r.submitted
		app.changed |= r.changed
		controls.text_box(&app.ro, "Read only")
	}
}

tb_setup :: proc() {
	ct_setup()
	tb_app = {}
	tb_app.ro.read_only = true
	controls.text_box_set(&tb_app.ro, "fixed text")
	ct_frame(tb_declare)
	ct_frame(tb_declare)
}

tb_teardown :: proc() {
	controls.text_box_destroy(&tb_app.tb)
	controls.text_box_destroy(&tb_app.ro)
	niello.test_teardown()
}

tb_text :: proc() -> string {
	return controls.text_box_text(&tb_app.tb)
}

tb_type :: proc(s: string) {
	ct_frame(tb_declare, text = s)
}

tb_key :: proc(k: niello.Key_Code, mods: niello.Modifiers = {}) {
	ct_frame(tb_declare, keys = []niello.Key_Event{kev(k, true, mods), kev(k, false, mods)})
}

CMD :: niello.Modifiers{controls.CMD_MOD}
WORD :: niello.Modifiers{controls.WORD_MOD}

// tb_point is the window point at text-space x in box b.
tb_point :: proc(b: niello.Instance, x: f32) -> niello.Vec2 {
	r, _ := niello.rect(b)
	return {r.pos.x + 10 + x - niello.scroll_offset(b).x, r.pos.y + r.size.y / 2}
}

@(test)
test_text_box_typing_and_keys :: proc(t: ^testing.T) {
	niello.test_reset()
	defer tb_teardown()
	tb_setup()
	ct_click(tb_declare, tb_app.tb.inst)
	testing.expect(t, niello.focused(tb_app.tb.inst), "a click focuses the box")
	tb_type("hello world")
	testing.expect_value(t, tb_text(), "hello world")
	testing.expect(t, tb_app.changed, "typing reports a change")
	testing.expect_value(t, tb_app.tb.caret, 11)
	tb_key(.Left, WORD)
	testing.expect_value(t, tb_app.tb.caret, 6)
	tb_key(.Left)
	testing.expect_value(t, tb_app.tb.caret, 5)
	tb_key(.Home, {.Shift})
	testing.expect(t, tb_app.tb.anchor == 5 && tb_app.tb.caret == 0, "Shift+Home selects to the start")
	tb_type("HELLO")
	testing.expect_value(t, tb_text(), "HELLO world")
	tb_key(.End)
	tb_key(.Backspace, WORD)
	testing.expect_value(t, tb_text(), "HELLO ")
	tb_key(.Backspace)
	testing.expect_value(t, tb_text(), "HELLO")
	tb_key(.Home)
	tb_key(.Delete)
	testing.expect_value(t, tb_text(), "ELLO")
	tb_type("a\nb\tc") // one line: breaks and tabs fold to spaces
	testing.expect_value(t, tb_text(), "a b cELLO")
	tb_key(.Enter)
	testing.expect(t, tb_app.submitted, "Enter submits")
	n, _ := ct_a11y(tb_app.tb.inst)
	testing.expect(t, n.role == .Edit && n.name == "Name" && n.value.text == "a b cELLO", "a11y: Edit, named by the placeholder, valued by the text")
}

@(test)
test_text_box_clipboard :: proc(t: ^testing.T) {
	niello.test_reset()
	defer tb_teardown()
	tb_setup()
	ct_click(tb_declare, tb_app.tb.inst)
	tb_type("copy me")
	tb_key(.A, CMD)
	tb_key(.C, CMD)
	testing.expect_value(t, niello.clipboard_text(), "copy me")
	tb_key(.End)
	tb_type(" ")
	tb_key(.V, CMD)
	testing.expect_value(t, tb_text(), "copy me copy me")
	tb_key(.Left, WORD)
	tb_key(.Right, {.Shift} | WORD) // select the last word
	tb_key(.X, CMD)
	testing.expect_value(t, tb_text(), "copy me copy ")
	testing.expect_value(t, niello.clipboard_text(), "me")
	niello.set_clipboard_text("line one\nline two")
	tb_key(.V, CMD)
	testing.expect_value(t, tb_text(), "copy me copy line one line two")
}

@(test)
test_text_box_mouse :: proc(t: ^testing.T) {
	niello.test_reset()
	defer tb_teardown()
	tb_setup()
	ct_click(tb_declare, tb_app.tb.inst)
	tb_type("hello world")
	b := tb_app.tb.inst
	// A press between characters places the caret at the nearer boundary.
	p := tb_point(b, 3 * 7 + 2)
	ct_frame(tb_declare, mouse = p, press = true, clicks = 1)
	ct_frame(tb_declare, mouse = p, release = true)
	testing.expect_value(t, tb_app.tb.caret, 3)
	testing.expect_value(t, tb_app.tb.anchor, 3)
	// A double click selects the word under it.
	p = tb_point(b, 8 * 7 + 3)
	ct_frame(tb_declare, mouse = p, press = true, clicks = 2)
	ct_frame(tb_declare, mouse = p, release = true)
	lo, hi := min(tb_app.tb.caret, tb_app.tb.anchor), max(tb_app.tb.caret, tb_app.tb.anchor)
	testing.expect(t, lo == 6 && hi == 11, "a double click selects \"world\"")
	// A double click at a word's first letter selects that word only.
	p = tb_point(b, 6 * 7 + 1)
	ct_frame(tb_declare, mouse = p, press = true, clicks = 2)
	ct_frame(tb_declare, mouse = p, release = true)
	lo, hi = min(tb_app.tb.caret, tb_app.tb.anchor), max(tb_app.tb.caret, tb_app.tb.anchor)
	testing.expect(t, lo == 6 && hi == 11, "a double click at a word's start selects that word")
	// A triple click selects everything.
	ct_frame(tb_declare, mouse = p, press = true, clicks = 3)
	ct_frame(tb_declare, mouse = p, release = true)
	testing.expect(t, tb_app.tb.anchor == 0 && tb_app.tb.caret == 11, "a triple click selects all")
	// The selection paints: one rect of the selection color, its width.
	ct_frame(tb_declare)
	found := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Rect && cmd.color == controls.DARK.selection {
			found = cmd.bounds.size.x == 11 * 7
		}
	}
	testing.expect(t, found, "the selection highlight spans the selected text")
	// A drag selects from the press to the pointer.
	p0 := tb_point(b, 0)
	ct_frame(tb_declare, mouse = p0, press = true, clicks = 1)
	for k in 1 ..= 5 {
		ct_frame(tb_declare, mouse = tb_point(b, f32(k * 7)), press = false)
	}
	inp := niello.Input{viewport = {500, 400}, window_focused = true, mouse = tb_point(b, 5 * 7), mouse_valid = true, buttons_down = {.Left}}
	niello.frame_begin(niello.test_context(), inp, 1.0 / 60.0)
	tb_declare()
	niello.frame_end()
	ct_frame(tb_declare, mouse = tb_point(b, 5 * 7), release = true)
	testing.expect(t, tb_app.tb.anchor == 0 && tb_app.tb.caret == 5, "dragging selects \"hello\"")
}

@(test)
test_text_box_scrolls_to_caret :: proc(t: ^testing.T) {
	niello.test_reset()
	defer tb_teardown()
	tb_setup()
	ct_click(tb_declare, tb_app.tb.inst)
	tb_type("0123456789012345678901234567890123456789012345678901234567890123456789") // 70 chars: 490 DIP
	ct_frame(tb_declare)
	ct_frame(tb_declare)
	box, _ := niello.rect(tb_app.tb.inst)
	caret: niello.Rect
	for cmd in niello.draw_list() {
		if cmd.tag == .Rect && cmd.color == controls.DARK.accent && cmd.bounds.size.x == controls.CARET_W {
			caret = cmd.bounds
		}
	}
	testing.expect(t, niello.scroll_offset(tb_app.tb.inst).x > 0, "the box scrolled")
	testing.expect(t, caret.pos.x >= box.pos.x && caret.pos.x + caret.size.x <= box.pos.x + box.size.x, "the caret is inside the box")
	tb_key(.Home)
	ct_frame(tb_declare)
	testing.expect_value(t, niello.scroll_offset(tb_app.tb.inst).x, f32(0))
}

@(test)
test_text_box_undo_redo :: proc(t: ^testing.T) {
	niello.test_reset()
	defer tb_teardown()
	tb_setup()
	ct_click(tb_declare, tb_app.tb.inst)
	tb_type("abc")
	tb_type("def") // the same run of typing: one undo step
	tb_key(.Z, CMD)
	testing.expect_value(t, tb_text(), "")
	tb_key(.Z, CMD | {.Shift})
	testing.expect_value(t, tb_text(), "abcdef")
	tb_key(.Backspace)
	tb_key(.Backspace) // a run of deleting: one step
	testing.expect_value(t, tb_text(), "abcd")
	tb_key(.Left) // a caret move ends the run
	tb_type("X")
	testing.expect_value(t, tb_text(), "abcXd")
	tb_key(.Z, CMD)
	testing.expect_value(t, tb_text(), "abcd")
	tb_key(.Z, CMD)
	testing.expect_value(t, tb_text(), "abcdef")
	tb_key(.Y, CMD)
	testing.expect_value(t, tb_text(), "abcd")
	// A new edit clears the redo history.
	tb_type("!")
	tb_key(.Y, CMD)
	testing.expect_value(t, tb_text(), "abc!d")
}

@(test)
test_text_box_read_only_and_disabled :: proc(t: ^testing.T) {
	niello.test_reset()
	defer tb_teardown()
	tb_setup()
	ct_click(tb_declare, tb_app.ro.inst)
	testing.expect(t, niello.focused(tb_app.ro.inst), "a read-only box takes focus")
	tb_type("nope")
	tb_key(.Backspace)
	tb_key(.V, CMD)
	testing.expect_value(t, controls.text_box_text(&tb_app.ro), "fixed text")
	tb_key(.A, CMD)
	tb_key(.C, CMD)
	testing.expect_value(t, niello.clipboard_text(), "fixed text")
	n, _ := ct_a11y(tb_app.ro.inst)
	testing.expect(t, .ReadOnly in n.flags, "a11y: ReadOnly")
	// A disabled box takes no focus.
	tb_app.tb.disabled = true
	ct_frame(tb_declare)
	ct_click(tb_declare, tb_app.tb.inst)
	testing.expect(t, !niello.focused(tb_app.tb.inst), "a disabled box takes no focus")
}
