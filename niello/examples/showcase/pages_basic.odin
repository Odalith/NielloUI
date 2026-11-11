// pages_basic.odin — Controls, Layout, Text, and Keyboard & focus.
package main

import "core:fmt"
import "core:strings"
import niello "../.."

// =====================================================================
// Controls
// =====================================================================

Controls_State :: struct {
	clicks:        int,
	notify, sound: bool,
	opt_a, opt_b:  bool,
	locked:        bool,
	count_i:       niello.Instance,
	hover_i:       niello.Instance,
	cursor_i:      [niello.Cursor_Kind]niello.Instance,
}

// One unit per cursor kind: Style.cursor is per unit.
cursor_units: [niello.Cursor_Kind]niello.Unit

page_controls :: proc(app: ^App) {
	s := &app.controls
	niello.show(ui.title, niello.key("t"), {text = "Controls"})
	note("n", "Every control is polled during declare — clicked(), hovered(), pressed() — against last frame's hit test. No callbacks anywhere. Hover, press and focus states are overlay units merged over the base style.")

	if niello.begin(ui.card, niello.key("buttons")) {
		heading("Buttons")
		if niello.begin(ui.row, niello.key("r1")) {
			s.count_i = button(niello.key("count"), fmt.tprintf("Clicked %d times", s.clicks))
			if niello.clicked(s.count_i) {
				s.clicks += 1
				status_set(&app.status, "Button clicked (%d)", s.clicks)
			}
			if niello.clicked(button(niello.key("primary"), "Primary", .Primary)) {
				status_set(&app.status, "Primary clicked")
			}
			if niello.clicked(button(niello.key("danger"), "Danger (pinned)", .Danger)) {
				status_set(&app.status, "Danger clicked — its color is pinned against theme broadcasts")
			}
			dis := button(niello.key("disabled"), "Disabled", .Normal, disabled = !s.locked)
			if niello.clicked(dis) {
				status_set(&app.status, "The unlocked button clicked")
			}
			if niello.hovered(dis) && !s.locked {
				status_set(&app.status, "Disabled: it is hovered (and shows the not-allowed cursor) but absorbs clicks")
			}
			if niello.clicked(button(niello.key("reset"), "Reset count")) {
				s.clicks = 0
			}
		}
		if niello.pressed(s.count_i) {
			note("press", "Pressed: the press captures — drag off the button and it stays pressed; release elsewhere cancels the click.")
		}
	}

	if niello.begin(ui.card, niello.key("toggles")) {
		heading("Toggles and checkboxes")
		if niello.begin(ui.row, niello.key("r1")) {
			if toggle(niello.key("notify"), "Notifications", &s.notify) {
				status_set(&app.status, "Notifications %s (a variant overlay)", s.notify ? "on" : "off")
			}
			toggle(niello.key("sound"), "Sound", &s.sound)
			checkbox(niello.key("a"), "Option A", &s.opt_a)
			checkbox(niello.key("b"), "Option B", &s.opt_b)
			if checkbox(niello.key("lock"), "Enable the disabled button", &s.locked) {
				status_set(&app.status, "Disabled button %s", s.locked ? "enabled" : "disabled")
			}
		}
	}

	if niello.begin(ui.card, niello.key("hover")) {
		heading("Hover, tooltips and cursors")
		s.hover_i = button(niello.key("hoverme"), "Hover me")
		tooltip(s.hover_i, "Tooltips are popups shown once hover_duration passes 0.5 s.")
		d := niello.hover_duration(s.hover_i)
		note("dur", d > 0 ? fmt.tprintf("hovered for %.1f s", d) : "not hovered")
		if niello.begin(ui.row, niello.key("cursors")) {
			for k in niello.Cursor_Kind {
				s.cursor_i[k] = niello.show(cursor_units[k], niello.key_int(int(k)), {text = fmt.tprintf("%v", k)})
			}
		}
		note("cur", "Each chip sets Style.cursor; the host applies the hovered instance's cursor from Frame_Result.")
	}
}

// =====================================================================
// Layout
// =====================================================================

Layout_State :: struct {
	squeeze: Slider,
}

layout_units: struct {
	box_row, sized, demo_label, align_cell, align_dot, clip_box, spill_box, wide: niello.Unit,
	squeeze_row, squeeze_label: niello.Unit,
	fixed_b, fit_b, grow_b, grow_max_b, percent_b: niello.Unit,
	align_cells: [9]niello.Unit,
}

page_layout :: proc(app: ^App) {
	s := &app.layout
	L := &layout_units
	niello.show(ui.title, niello.key("t"), {text = "Layout"})
	note("n", "Row, column and stack containers. Each axis sizes as Fixed, Fit (content), Grow (share the leftover) or Percent (of the parent), with min/max clamps. Resize the window to watch Grow and Percent react.")

	if niello.begin(ui.card, niello.key("sizing")) {
		heading("Sizing kinds")
		if niello.begin(L.box_row, niello.key("r1")) {
			niello.show(L.fixed_b, 0, {text = "fixed(140)"})
			niello.show(L.fit_b, 0, {text = "fit() — sized to this label"})
			niello.show(L.grow_b, 0, {text = "grow()"})
			niello.show(L.percent_b, 0, {text = "percent(0.2)"})
		}
		if niello.begin(L.box_row, niello.key("r2")) {
			niello.show(L.grow_max_b, 0, {text = "grow(max = 160)"})
			niello.show(L.grow_b, 0, {text = "grow()"})
			niello.show(L.grow_b, 0, {text = "grow()"})
		}
		note("g", "Growers split the leftover fairly; one clamped by its max gives the rest away.")
	}

	if niello.begin(ui.card, niello.key("align")) {
		heading("Alignment (stack layout, align = [x, y])")
		if niello.begin(ui.row, niello.key("cells")) {
			for k in 0 ..< 9 {
				if niello.begin(L.align_cells[k], niello.key_int(k)) {
					niello.show(L.align_dot)
				}
			}
		}
	}

	if niello.begin(ui.card, niello.key("squeeze")) {
		heading("Shrinking and ellipsis")
		note("n", "Drag the slider to squeeze the row. Fit children shrink fairly toward their floors; text past its box is trimmed with an ellipsis at paint time.")
		slider(&s.squeeze, niello.key("sl"), "Row width")
		w := 120 + s.squeeze.value * 520
		niello.set(L.squeeze_row, .Size, sz(fixed(w), fixed(34)))
		if niello.begin(L.squeeze_row, niello.key("row")) {
			niello.show(L.squeeze_label, 0, {text = "The first label is fairly long"})
			niello.show(L.squeeze_label, 0, {text = "Second label"})
			niello.show(L.squeeze_label, 0, {text = "Third, also somewhat long"})
		}
		note("w", fmt.tprintf("row width %.0f DIP", w))
	}

	if niello.begin(ui.card, niello.key("overflow")) {
		heading("Overflow: spill vs clip")
		if niello.begin(ui.row, niello.key("r")) {
			if niello.begin(L.spill_box, niello.key("spill")) {
				niello.show(L.wide, 0, {text = "Spill (default): I draw past my parent"})
			}
			if niello.begin(L.clip_box, niello.key("clip")) {
				niello.show(L.wide, 0, {text = "Clip: I am cut at my parent's edge"})
			}
		}
		note("d", "In debug builds the F12 debugger lists the spill as an overflow.")
	}
}

// =====================================================================
// Text
// =====================================================================

Text_State :: struct {
	width: Slider,
}

text_units: struct {
	sizes:   [5]niello.Unit,
	weights: [len(niello.Font_Weight)]niello.Unit,
	slants:  [len(niello.Font_Slant)]niello.Unit,
	spans, wrapped, collapse, preserve, ws_box, ellipsis, no_ellipsis, trim_box: niello.Unit,
}

TEXT_SIZES := [5]f32{11, 14, 18, 24, 32}

SPAN_TEXT :: "Spans style runs inside one string: bold, colored, italic, and BIG."
WRAP_TEXT :: "Word wrap packs words into lines at the box's width. Drag the slider to change the width; the paragraph re-wraps every frame without re-measuring a single word, because measurements are cached per word."

page_text :: proc(app: ^App) {
	s := &app.text
	T := &text_units
	niello.show(ui.title, niello.key("t"), {text = "Text"})

	if niello.begin(ui.card, niello.key("fonts")) {
		heading("Size, weight, slant")
		if niello.begin(ui.row, niello.key("sizes")) {
			for u, k in T.sizes {
				niello.show(u, niello.key_int(k), {text = fmt.tprintf("%.0f px", TEXT_SIZES[k])})
			}
		}
		if niello.begin(ui.row, niello.key("weights")) {
			k := 0
			for w in niello.Font_Weight {
				niello.show(T.weights[k], niello.key_int(k), {text = fmt.tprintf("%v", w)})
				k += 1
			}
		}
		if niello.begin(ui.row, niello.key("slants")) {
			k := 0
			for sl in niello.Font_Slant {
				niello.show(T.slants[k], niello.key_int(k), {text = fmt.tprintf("%v slant", sl)})
				k += 1
			}
		}
		niello.show(ui.body, niello.key("uni"), {text = "Unicode: Grüße, café, naïve, ½ → ✓"})
		niello.show(ui.body, niello.key("nl"), {text = "Explicit newlines\nalways break,\neven without wrap."})
	}

	if niello.begin(ui.card, niello.key("spans")) {
		heading("Rich text spans")
		niello.show(T.spans, 0, {text = SPAN_TEXT})
	}

	if niello.begin(ui.card, niello.key("wrap")) {
		heading("Wrapping")
		slider(&s.width, niello.key("sl"), "Paragraph width")
		w := 160 + s.width.value * 500
		niello.set(T.wrapped, .Size, sz(fixed(w), fit()))
		niello.show(T.wrapped, niello.key("p"), {text = WRAP_TEXT})
		note("w", fmt.tprintf("width %.0f DIP", w))
	}

	if niello.begin(ui.card, niello.key("ws")) {
		heading("Whitespace and trimming")
		if niello.begin(ui.row, niello.key("r")) {
			if niello.begin(T.ws_box, niello.key("c")) {
				niello.show(T.collapse, 0, {text = "  Collapse:   runs   fold  "})
			}
			if niello.begin(T.ws_box, niello.key("p")) {
				niello.show(T.preserve, 0, {text = "  Preserve:   runs   stay  "})
			}
		}
		if niello.begin(ui.row, niello.key("trim")) {
			if niello.begin(T.trim_box, niello.key("e")) {
				niello.show(T.ellipsis, 0, {text = "ellipsis on: this sentence is too long for the box"})
			}
			if niello.begin(T.trim_box, niello.key("n")) {
				niello.show(T.no_ellipsis, 0, {text = "ellipsis off: this sentence is too long for the box"})
			}
		}
	}
}

// =====================================================================
// Keyboard & focus
// =====================================================================

KEY_LOG :: 10

Input_State :: struct {
	name, email:  Text_Field,
	submitted:    string,
	key_box_i:    niello.Instance,
	key_log:      [KEY_LOG]niello.Key_Event,
	key_log_n:    int,
	typed:        [64]u8,
	typed_n:      int,
}

input_units: struct {
	key_box, key_box_focus: niello.Unit,
}

page_input :: proc(app: ^App) {
	s := &app.input
	niello.show(ui.title, niello.key("t"), {text = "Keyboard & focus"})
	note("n", "Tab / Shift+Tab walk the focusable instances in declaration order; clicking focuses. Text and keys route to the focused instance only: input_text for typed characters, input_keys for key events as Key_Codes.")

	if niello.begin(ui.card, niello.key("form")) {
		heading("Text fields")
		if text_field_input(&s.name) {
			niello.focus_next()
		}
		if text_field_input(&s.email) {
			niello.focus_next()
		}
		niello.show(ui.small, niello.key("l1"), {text = "NAME"})
		text_field(&s.name, niello.key("name"), "e.g. Ada Lovelace")
		niello.show(ui.small, niello.key("l2"), {text = "EMAIL"})
		text_field(&s.email, niello.key("email"), "ada@example.com")
		note("keys", "Backspace, Delete, Left/Right, Home/End; Ctrl+Backspace and Ctrl+Left jump by word; Enter moves on.")
		if niello.begin(ui.row, niello.key("btns")) {
			if niello.clicked(button(niello.key("submit"), "Submit", .Primary)) {
				delete(s.submitted)
				s.submitted = fmt.aprintf("Submitted: %q <%s>", string(s.name.buf[:]), string(s.email.buf[:]))
			}
			if niello.clicked(button(niello.key("clear"), "Clear")) {
				clear(&s.name.buf)
				clear(&s.email.buf)
				s.name.caret, s.email.caret = 0, 0
				niello.focus(s.name.inst)
			}
		}
		if s.submitted != "" {
			niello.show(ui.accent_text, niello.key("sub"), {text = s.submitted})
		}
	}

	if niello.begin(ui.card, niello.key("keys")) {
		heading("Key tester")
		note("n", "Click the box (or Tab to it) and press keys. Each event shows its logical key (what the layout produces), its physical key (the US-QWERTY position) and the held modifiers.")
		for ev in niello.input_keys(s.key_box_i) {
			copy(s.key_log[1:], s.key_log[:KEY_LOG - 1])
			s.key_log[0] = ev
			s.key_log_n = min(s.key_log_n + 1, KEY_LOG)
		}
		if t := niello.input_text(s.key_box_i); t != "" {
			for b in transmute([]u8)t {
				if s.typed_n == len(s.typed) {
					copy(s.typed[:], s.typed[1:])
					s.typed_n -= 1
				}
				s.typed[s.typed_n] = b
				s.typed_n += 1
			}
		}
		focused := niello.focused(s.key_box_i)
		if niello.begin(input_units.key_box, niello.key("box"), {role = .Pane, label = "Key tester"}, out = &s.key_box_i) {
			niello.show(ui.small, niello.key("hint"), {
				text = focused ? "focused — press keys (Tab leaves)" : "click to focus",
			})
			for k in 0 ..< s.key_log_n {
				ev := s.key_log[k]
				niello.show(ui.mono, niello.key_int(k), {text = fmt.tprintf(
					"%-4s key=%-12s physical=%-12s mods=%v%s",
					ev.down ? "down" : "up", fmt.tprint(ev.key), fmt.tprint(ev.physical), ev.mods, ev.repeat ? " (repeat)" : "",
				)})
			}
			niello.show(ui.mono, niello.key("typed"), {text = fmt.tprintf("typed: %s", string(s.typed[:s.typed_n]))})
		}
	}
}

// =====================================================================
// Minting the basic pages' units
// =====================================================================

mint_pages_basic :: proc(t: Theme) {
	label := niello.Style_Decl{font_size = 13, font_color = t.ink, groups = []niello.Group{groups.ink}}

	for k in niello.Cursor_Kind {
		niello.mint(&cursor_units[k], niello.NO_UNIT, {
			size = sz(fit(), fixed(28)), padding = pad_xy(10, 6), corner_radius = 6,
			color = t.raised, font_size = 12, font_color = t.ink, cursor = k,
			hover = ui.btn_hover,
			groups = []niello.Group{groups.raised, groups.ink},
		})
	}

	L := &layout_units
	niello.mint(&L.box_row, niello.NO_UNIT, {layout = .Left_To_Right, size = sz(grow(), fixed(44)), gap = 8})
	box := niello.Style_Decl{
		size = sz(fixed(140), grow()), padding = pad_xy(10, 13), corner_radius = 6,
		color = t.raised, font_size = 13, font_color = t.ink,
		groups = []niello.Group{groups.raised, groups.ink},
	}
	niello.mint(&L.fixed_b, niello.NO_UNIT, box)
	box.size = sz(fit(), grow())
	niello.mint(&L.fit_b, niello.NO_UNIT, box)
	box.size = sz(percent(0.2), grow())
	niello.mint(&L.percent_b, niello.NO_UNIT, box)
	box.groups = []niello.Group{groups.ink}
	box.size = sz(grow(), grow())
	box.color = rgb(0x3d5a8c)
	niello.mint(&L.grow_b, niello.NO_UNIT, box)
	box.size = sz(grow(max = 160), grow())
	box.color = rgb(0x5a3d8c)
	niello.mint(&L.grow_max_b, niello.NO_UNIT, box)

	niello.mint(&L.align_dot, niello.NO_UNIT, {size = sz(fixed(16), fixed(16)), corner_radius = 8, color = t.accent})
	kinds := [3]niello.Align_Kind{.Start, .Center, .End}
	for k in 0 ..< 9 {
		niello.mint(&L.align_cells[k], niello.NO_UNIT, {
			layout = .Stack, size = sz(fixed(64), fixed(64)), padding = pad(6),
			corner_radius = 6, color = t.raised,
			align = [2]niello.Align_Kind{kinds[k % 3], kinds[k / 3]},
			groups = []niello.Group{groups.raised},
		})
	}
	niello.mint(&L.squeeze_row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(fixed(400), fixed(34)), gap = 6,
		padding = pad(4), corner_radius = 6, color = t.bg,
		groups = []niello.Group{groups.bg},
	})
	niello.mint(&L.squeeze_label, niello.NO_UNIT, {
		size = sz(fit(), grow()), padding = pad_xy(8, 4), corner_radius = 4,
		color = t.raised, font_size = 13, font_color = t.ink,
		groups = []niello.Group{groups.raised, groups.ink},
	})
	niello.mint(&L.spill_box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(fixed(200), fixed(50)), padding = pad(8),
		corner_radius = 6, border_width = 1, border_color = t.dim,
	})
	niello.mint(&L.clip_box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(fixed(200), fixed(50)), padding = pad(8),
		corner_radius = 6, border_width = 1, border_color = t.dim, overflow = .Clip,
	})
	niello.mint(&L.wide, niello.NO_UNIT, {
		size = sz(fixed(320), fixed(30)), padding = pad_xy(8, 7), corner_radius = 4,
		color = rgb(0x8c5a3d), font_size = 13, font_color = rgb(0xffffff), ellipsis = false,
	})

	T := &text_units
	for k in 0 ..< 5 {
		d := label
		d.font_size = TEXT_SIZES[k]
		niello.mint(&T.sizes[k], niello.NO_UNIT, d)
	}
	k := 0
	for w in niello.Font_Weight {
		d := label
		d.font_size = 15
		d.font_weight = w
		niello.mint(&T.weights[k], niello.NO_UNIT, d)
		k += 1
	}
	k = 0
	for sl in niello.Font_Slant {
		d := label
		d.font_size = 15
		d.font_slant = sl
		niello.mint(&T.slants[k], niello.NO_UNIT, d)
		k += 1
	}
	b1, e1 := span_of(SPAN_TEXT, "bold")
	b2, e2 := span_of(SPAN_TEXT, "colored")
	b3, e3 := span_of(SPAN_TEXT, "italic")
	b4, e4 := span_of(SPAN_TEXT, "BIG")
	niello.mint(&T.spans, niello.NO_UNIT, {
		font_size = 16, font_color = t.ink, groups = []niello.Group{groups.ink},
		text_spans = []niello.Text_Span{
			{start = b1, end = e1, font_weight = .Bold},
			{start = b2, end = e2, font_color = WARM},
			{start = b3, end = e3, font_slant = .Italic},
			{start = b4, end = e4, font_size = 24, font_weight = .Black, font_color = t.accent},
		},
	})
	niello.mint(&T.wrapped, niello.NO_UNIT, {
		font_size = 14, font_color = t.ink, wrap = .Word,
		color = t.raised, padding = pad(10), corner_radius = 6,
		groups = []niello.Group{groups.ink, groups.raised},
	})
	niello.mint(&T.ws_box, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(fit(), fit()),
		color = t.bg, corner_radius = 4, groups = []niello.Group{groups.bg},
	})
	niello.mint(&T.collapse, niello.NO_UNIT, {font_size = 14, font_color = t.ink, color = rgb(0x3d5a8c, 160), groups = []niello.Group{groups.ink}})
	niello.mint(&T.preserve, niello.NO_UNIT, {font_size = 14, font_color = t.ink, whitespace = .Preserve, color = rgb(0x3d5a8c, 160), groups = []niello.Group{groups.ink}})
	niello.mint(&T.trim_box, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(fixed(240), fixed(30)), padding = pad_xy(8, 6),
		overflow = .Clip, corner_radius = 4, color = t.raised, groups = []niello.Group{groups.raised},
	})
	niello.mint(&T.ellipsis, niello.NO_UNIT, {font_size = 13, font_color = t.ink, groups = []niello.Group{groups.ink}})
	niello.mint(&T.no_ellipsis, niello.NO_UNIT, {font_size = 13, font_color = t.ink, ellipsis = false, groups = []niello.Group{groups.ink}})

	niello.mint(&input_units.key_box_focus, niello.NO_UNIT, {overlay_border_color = t.accent, overlay_border_width = 2})
	niello.mint(&input_units.key_box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(grow(), fixed(230)), padding = pad(12), gap = 2,
		color = t.bg, corner_radius = 8, focusable = true, cursor = .Text,
		focus = input_units.key_box_focus, overflow = .Clip,
		groups = []niello.Group{groups.bg},
	})
}

// span_of returns the byte range of the first occurrence of word in s.
span_of :: proc(s, word: string) -> (start, end: int) {
	i := strings.index(s, word)
	if i < 0 {
		return 0, 0
	}
	return i, i + len(word)
}

destroy_pages_basic :: proc(app: ^App) {
	text_field_destroy(&app.input.name)
	text_field_destroy(&app.input.email)
	delete(app.input.submitted)
}
