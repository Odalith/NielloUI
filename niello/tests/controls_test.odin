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
