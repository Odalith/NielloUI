// pages_basic.odin — Controls, Layout, Text, and Keyboard & focus.
package main

import "core:fmt"
import "core:strings"
import niello "../.."
import controls "../../controls"

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
	niello.show(ui.title, {text = "Controls"})
	note("Every control is polled during declare — clicked(), hovered(), pressed() — against last frame's hit test. No callbacks anywhere. Hover, press and focus states are overlay units merged over the base style.")

	if niello.begin(ui.card) {
		heading("Buttons")
		if niello.begin(ui.row) {
			s.count_i = controls.button(fmt.tprintf("Clicked %d times", s.clicks))
			if niello.clicked(s.count_i) {
				s.clicks += 1
				status_set(&app.status, "Button clicked (%d)", s.clicks)
			}
			if niello.clicked(controls.button("Primary", .Primary)) {
				status_set(&app.status, "Primary clicked")
			}
			if niello.clicked(controls.button("Danger", .Danger)) {
				status_set(&app.status, "Danger clicked")
			}
			dis := controls.button("Disabled", .Normal, disabled = !s.locked)
			if niello.clicked(dis) {
				status_set(&app.status, "The unlocked button clicked")
			}
			if niello.hovered(dis) && !s.locked {
				status_set(&app.status, "Disabled: it is hovered (and shows the not-allowed cursor) but absorbs clicks")
			}
			if niello.clicked(controls.button("Reset count")) {
				s.clicks = 0
			}
		}
		if niello.pressed(s.count_i) {
			note("Pressed: the press captures — drag off the button and it stays pressed; release elsewhere cancels the click.")
		}
	}

	if niello.begin(ui.card) {
		heading("Toggles, switches and checkboxes")
		if niello.begin(ui.row) {
			if controls.toggle_button("Notifications", &s.notify) {
				status_set(&app.status, "Notifications %s (a variant overlay)", s.notify ? "on" : "off")
			}
			controls.toggle_switch("Sound", &s.sound)
			checkbox("Option A", &s.opt_a)
			checkbox("Option B", &s.opt_b)
			if checkbox("Enable the disabled button", &s.locked) {
				status_set(&app.status, "Disabled button %s", s.locked ? "enabled" : "disabled")
			}
		}
	}

	if niello.begin(ui.card) {
		heading("Hover, tooltips and cursors")
		s.hover_i = controls.button("Hover me")
		tooltip(s.hover_i, "Tooltips are popups shown once hover_duration passes 0.5 s.")
		d := niello.hover_duration(s.hover_i)
		note(d > 0 ? fmt.tprintf("hovered for %.1f s", d) : "not hovered")
		if niello.begin(ui.row) {
			for k in niello.Cursor_Kind {
				s.cursor_i[k] = niello.show(cursor_units[k], {text = fmt.tprintf("%v", k)})
			}
		}
		note("Each chip sets Style.cursor; the host applies the hovered instance's cursor from Frame_Result.")
	}
}

// =====================================================================
// Layout
// =====================================================================

Layout_State :: struct {
	squeeze:          controls.Slider,
	wrap_align:       [2]niello.Align_Kind, // the Wrap demo's align, cycled by its buttons
	wrap_x_i, wrap_y_i: niello.Instance,
}

WRAP_WORDS := [?]string{
	"layout", "wrap", "rows", "tags", "chips", "a taller one", "alignment", "per line",
	"line_gap", "gap", "Start", "Center", "End", "grow", "fit", "resize the window",
	"Odin", "Skia",
}

layout_units: struct {
	box_row, sized, demo_label, align_cell, align_dot, clip_box, spill_box, wide: niello.Unit,
	squeeze_row, squeeze_label, squeeze_label_low: niello.Unit,
	wrap_box, wrap_tag, wrap_tall: niello.Unit,
	fixed_b, fit_b, grow_b, grow2_b, grow_max_b, percent_b: niello.Unit,
	align_cells: [9]niello.Unit,
}

page_layout :: proc(app: ^App) {
	s := &app.layout
	L := &layout_units
	niello.show(ui.title, {text = "Layout"})
	note("Row, column and stack containers. Each axis sizes as Fixed, Fit (content), Grow (share the leftover) or Percent (of the parent), with min/max clamps. Resize the window to watch Grow and Percent react.")

	if niello.begin(ui.card) {
		heading("Sizing kinds")
		if niello.begin(L.box_row) {
			niello.show(L.fixed_b, {text = "fixed(140)"})
			niello.show(L.fit_b, {text = "fit() — sized to this label"})
			niello.show(L.grow_b, {text = "grow()"})
			niello.show(L.percent_b, {text = "percent(0.2)"})
		}
		if niello.begin(L.box_row) {
			niello.show(L.grow_max_b, {text = "grow(max = 160)"})
			niello.show(L.grow_b, {text = "grow()"})
			niello.show(L.grow_b, {text = "grow()"})
		}
		if niello.begin(L.box_row) {
			niello.show(L.grow2_b, {text = "grow(2)"})
			niello.show(L.grow_b, {text = "grow()"})
		}
		note("Growers split the leftover by weight — grow(2) takes twice the share of grow() — and one clamped by its max gives the rest away.")
	}

	if niello.begin(ui.card) {
		heading("Alignment (stack layout, align = [x, y])")
		if niello.begin(ui.row) {
			for k in 0 ..< 9 {
				if niello.begin(L.align_cells[k]) {
					niello.show(L.align_dot)
				}
			}
		}
	}

	if niello.begin(ui.card) {
		heading("Wrap")
		note("Layout.Wrap: children run left to right and start a new line when the next one doesn't fit; resize the window to watch them rewrap. align[0] places each line, align[1] the block of lines and each chip within its line.")
		names := [3]string{"Start", "Center", "End"}
		if niello.begin(ui.row) {
			s.wrap_x_i = controls.button(fmt.tprintf("align x: %s", names[s.wrap_align[0]]))
			if niello.clicked(s.wrap_x_i) {
				s.wrap_align[0] = niello.Align_Kind((int(s.wrap_align[0]) + 1) % 3)
				niello.set(L.wrap_box, .Align, s.wrap_align)
			}
			s.wrap_y_i = controls.button(fmt.tprintf("align y: %s", names[s.wrap_align[1]]))
			if niello.clicked(s.wrap_y_i) {
				s.wrap_align[1] = niello.Align_Kind((int(s.wrap_align[1]) + 1) % 3)
				niello.set(L.wrap_box, .Align, s.wrap_align)
			}
		}
		if niello.begin(L.wrap_box) {
			for word, k in WRAP_WORDS {
				niello.show(k == 5 ? L.wrap_tall : L.wrap_tag, {text = word}, niello.key_int(k))
			}
		}
	}

	if niello.begin(ui.card) {
		heading("Shrinking and ellipsis")
		note("Drag the slider to squeeze the row. Fit children shrink fairly toward their floors; text past its box is trimmed with an ellipsis at paint time.")
		controls.slider(&s.squeeze, "Row width")
		w := 160 + s.squeeze.value * 480 // 160: three padded labels at their floors
		niello.set(L.squeeze_row, .Size, size(fixed(w), fixed(34)))
		if niello.begin(L.squeeze_row) {
			niello.show(L.squeeze_label, {text = "The first label is fairly long"})
			niello.show(L.squeeze_label, {text = "Second label"})
			niello.show(L.squeeze_label, {text = "Third, also somewhat long"})
		}
		note("The same row with the first label at fit(priority = -1): it gives way first, and the others only shrink once it reaches its floor.")
		if niello.begin(L.squeeze_row) {
			niello.show(L.squeeze_label_low, {text = "The first label is fairly long"})
			niello.show(L.squeeze_label, {text = "Second label"})
			niello.show(L.squeeze_label, {text = "Third, also somewhat long"})
		}
		note(fmt.tprintf("row width %.0f DIP", w))
	}

	if niello.begin(ui.card) {
		heading("Overflow: spill vs clip")
		if niello.begin(ui.row) {
			if niello.begin(L.spill_box) {
				niello.show(L.wide, {text = "Spill (default): I draw past my parent"})
			}
			if niello.begin(L.clip_box) {
				niello.show(L.wide, {text = "Clip: I am cut at my parent's edge"})
			}
		}
		note("In debug builds the F12 debugger lists the spill as an overflow.")
	}
}

// =====================================================================
// Text
// =====================================================================

Text_State :: struct {
	width: controls.Slider,
}

text_units: struct {
	sizes:   [5]niello.Unit,
	weights: [len(niello.Font_Weight)]niello.Unit,
	slants:  [len(niello.Font_Slant)]niello.Unit,
	spans, wrapped, justified, collapse, preserve, ws_box, ellipsis, no_ellipsis, trim_box: niello.Unit,
	valign: [3]niello.Unit,
}

TEXT_SIZES := [5]f32{11, 14, 18, 24, 32}

SPAN_TEXT :: "Spans style runs inside one string: bold, colored, italic, and BIG."
WRAP_TEXT :: "Word wrap packs words into lines at the box's width. Drag the slider to change the width; the paragraph re-wraps every frame without re-measuring a single word, because measurements are cached per word."

page_text :: proc(app: ^App) {
	s := &app.text
	T := &text_units
	niello.show(ui.title, {text = "Text"})

	if niello.begin(ui.card) {
		heading("Size, weight, slant")
		if niello.begin(ui.row) {
			for u, k in T.sizes {
				niello.show(u, {text = fmt.tprintf("%.0f px", TEXT_SIZES[k])})
			}
		}
		if niello.begin(ui.row) {
			k := 0
			for w in niello.Font_Weight {
				niello.show(T.weights[k], {text = fmt.tprintf("%v", w)})
				k += 1
			}
		}
		if niello.begin(ui.row) {
			k := 0
			for sl in niello.Font_Slant {
				niello.show(T.slants[k], {text = fmt.tprintf("%v slant", sl)})
				k += 1
			}
		}
		niello.show(ui.body, {text = "Unicode: Grüße, café, naïve, ½ → ✓"})
		niello.show(ui.body, {text = "Explicit newlines\nalways break,\neven without wrap."})
	}

	if niello.begin(ui.card) {
		heading("Rich text spans")
		niello.show(T.spans, {text = SPAN_TEXT})
	}

	if niello.begin(ui.card) {
		heading("Wrapping")
		controls.slider(&s.width, "Paragraph width")
		w := 160 + s.width.value * 500
		niello.set(T.wrapped, .Size, size(fixed(w), fit()))
		niello.show(T.wrapped, {text = WRAP_TEXT})
		note("The same paragraph with justify: every line but the last spreads to the full width.")
		niello.set(T.justified, .Size, size(fixed(w), fit()))
		niello.show(T.justified, {text = WRAP_TEXT})
		note(fmt.tprintf("width %.0f DIP", w))
	}

	if niello.begin(ui.card) {
		heading("Alignment inside a leaf")
		note("A leaf's align places its text: align[0] each line across the box, align[1] the block down it — inside the padding. One leaf makes a centered button.")
		if niello.begin(ui.row) {
			niello.show(T.valign[0], {text = "Start, Start"})
			niello.show(T.valign[1], {text = "Center, Center"})
			niello.show(T.valign[2], {text = "End, End"})
		}
	}

	if niello.begin(ui.card) {
		heading("Whitespace and trimming")
		if niello.begin(ui.row) {
			if niello.begin(T.ws_box) {
				niello.show(T.collapse, {text = "  Collapse:   runs   fold  "})
			}
			if niello.begin(T.ws_box) {
				niello.show(T.preserve, {text = "  Preserve:   runs   stay  "})
			}
		}
		if niello.begin(ui.row) {
			if niello.begin(T.trim_box) {
				niello.show(T.ellipsis, {text = "ellipsis on: this sentence is too long for the box"})
			}
			if niello.begin(T.trim_box) {
				niello.show(T.no_ellipsis, {text = "ellipsis off: this sentence is too long for the box"})
			}
		}
	}
}

// =====================================================================
// Keyboard & focus
// =====================================================================

KEY_LOG :: 10

Input_State :: struct {
	name, email:  controls.Text_Box,
	submitted:    string,
	key_box_i:    niello.Instance,
	key_log:      [KEY_LOG]niello.Key_Event,
	key_log_n:    int,
	typed:        [64]u8,
	typed_n:      int,
}

input_units: struct {
	key_box: niello.Unit,
}

page_input :: proc(app: ^App) {
	s := &app.input
	niello.show(ui.title, {text = "Keyboard & focus"})
	note("Tab / Shift+Tab walk the focusable instances in declaration order; clicking focuses. The engine draws the focus ring for keyboard focus only (clicking a button shows none, the next key press does); fields and the key box opt into it on click with focus_ring = .Always, and Tab scrolls the focused control into view. Text and keys route to the focused instance only: input_text for typed characters, input_keys for key events as Key_Codes.")

	if niello.begin(ui.card) {
		heading("Text boxes (niello/controls)")
		niello.show(ui.small, {text = "NAME"})
		if controls.text_box(&s.name, "e.g. Ada Lovelace").submitted {
			niello.focus_next()
		}
		niello.show(ui.small, {text = "EMAIL"})
		if controls.text_box(&s.email, "ada@example.com").submitted {
			niello.focus_next()
		}
		note("Select with Shift+arrows or the mouse (double-click a word, triple-click all); Ctrl+A / C / X / V use the system clipboard; Ctrl+Z / Ctrl+Y undo and redo; Ctrl+Backspace and Ctrl+Left/Right work by word; Enter moves on.")
		if niello.begin(ui.row) {
			if niello.clicked(controls.button("Submit", .Primary)) {
				delete(s.submitted)
				s.submitted = fmt.aprintf("Submitted: %q <%s>", string(s.name.buf[:]), string(s.email.buf[:]))
			}
			if niello.clicked(controls.button("Clear")) {
				controls.text_box_set(&s.name, "")
				controls.text_box_set(&s.email, "")
				niello.focus(s.name.inst)
			}
		}
		if s.submitted != "" {
			niello.show(ui.accent_text, {text = s.submitted})
		}
	}

	if niello.begin(ui.card) {
		heading("Key tester")
		note("Click the box (or Tab to it) and press keys. Each event shows its logical key (what the layout produces), its physical key (the US-QWERTY position) and the held modifiers.")
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
		if niello.begin(input_units.key_box, {role = .Pane, label = "Key tester"}, out = &s.key_box_i) {
			niello.show(ui.small, {
				text = focused ? "focused — press keys (Tab leaves)" : "click to focus",
			})
			for k in 0 ..< s.key_log_n {
				ev := s.key_log[k]
				niello.show(ui.mono, {text = fmt.tprintf(
					"%-4s key=%-12s physical=%-12s mods=%v%s",
					ev.down ? "down" : "up", fmt.tprint(ev.key), fmt.tprint(ev.physical), ev.mods, ev.repeat ? " (repeat)" : "",
				)})
			}
			niello.show(ui.mono, {text = fmt.tprintf("typed: %s", string(s.typed[:s.typed_n]))})
		}
	}
}

// =====================================================================
// Minting the basic pages' units
// =====================================================================

mint_pages_basic :: proc(t: Theme) {
	label := niello.Style_Decl{font_size = 13, font_color = t.ink, groups = []niello.Group{controls.groups.ink}}

	for k in niello.Cursor_Kind {
		niello.mint(&cursor_units[k], niello.NO_UNIT, {
			size = size(fit(), fixed(28)), padding = pad_xy(10, 6), corner_radius = 6,
			color = t.raised, font_size = 12, font_color = t.ink, cursor = k,
			hover = controls.parts.button.hover,
			groups = []niello.Group{controls.groups.raised, controls.groups.ink},
		})
	}

	L := &layout_units
	niello.mint(&L.box_row, niello.NO_UNIT, {layout = .Left_To_Right, size = size(grow(), fixed(44)), gap = 8})
	box := niello.Style_Decl{
		size = size(fixed(140), grow()), padding = pad_xy(10, 13), corner_radius = 6,
		color = t.raised, font_size = 13, font_color = t.ink,
		groups = []niello.Group{controls.groups.raised, controls.groups.ink},
	}
	niello.mint(&L.fixed_b, niello.NO_UNIT, box)
	box.size = size(fit(), grow())
	niello.mint(&L.fit_b, niello.NO_UNIT, box)
	box.size = size(percent(0.2), grow())
	niello.mint(&L.percent_b, niello.NO_UNIT, box)
	box.groups = []niello.Group{controls.groups.ink}
	box.size = size(grow(), grow())
	box.color = rgb(0x3d5a8c)
	niello.mint(&L.grow_b, niello.NO_UNIT, box)
	box.size = size(grow(2), grow())
	box.color = rgb(0x3d7a8c)
	niello.mint(&L.grow2_b, niello.NO_UNIT, box)
	box.size = size(grow(max = 160), grow())
	box.color = rgb(0x5a3d8c)
	niello.mint(&L.grow_max_b, niello.NO_UNIT, box)

	niello.mint(&L.align_dot, niello.NO_UNIT, {size = size(fixed(16), fixed(16)), corner_radius = 8, color = t.accent})
	kinds := [3]niello.Align_Kind{.Start, .Center, .End}
	for k in 0 ..< 9 {
		niello.mint(&L.align_cells[k], niello.NO_UNIT, {
			layout = .Stack, size = size(fixed(64), fixed(64)), padding = pad(6),
			corner_radius = 6, color = t.raised,
			align = niello.align(kinds[k % 3], kinds[k / 3]),
			groups = []niello.Group{controls.groups.raised},
		})
	}
	niello.mint(&L.wrap_box, niello.NO_UNIT, {
		layout = .Wrap, size = size(grow(), fixed(160)), gap = 6, line_gap = 6,
		padding = pad(8), corner_radius = 6, color = t.bg,
		groups = []niello.Group{controls.groups.bg},
	})
	niello.mint(&L.wrap_tag, niello.NO_UNIT, {
		padding = pad_xy(10, 5), corner_radius = 12, color = t.raised,
		font_size = 13, font_color = t.ink,
		groups = []niello.Group{controls.groups.raised, controls.groups.ink},
	})
	niello.mint(&L.wrap_tall, L.wrap_tag, {
		padding = pad_xy(10, 14),
		groups = []niello.Group{controls.groups.raised, controls.groups.ink},
	})
	niello.mint(&L.squeeze_row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(fixed(400), fixed(34)), gap = 6,
		padding = pad(4), corner_radius = 6, color = t.bg,
		groups = []niello.Group{controls.groups.bg},
	})
	niello.mint(&L.squeeze_label, niello.NO_UNIT, {
		size = size(fit(), grow()), padding = pad_xy(8, 4), corner_radius = 4,
		color = t.raised, font_size = 13, font_color = t.ink,
		groups = []niello.Group{controls.groups.raised, controls.groups.ink},
	})
	niello.mint(&L.squeeze_label_low, niello.NO_UNIT, {
		size = size(fit(priority = -1), grow()), padding = pad_xy(8, 4), corner_radius = 4,
		color = t.raised, font_size = 13, font_color = t.ink,
		groups = []niello.Group{controls.groups.raised, controls.groups.ink},
	})
	niello.mint(&L.spill_box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(200), fixed(50)), padding = pad(8),
		corner_radius = 6, border_width = 1, border_color = t.dim,
	})
	niello.mint(&L.clip_box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(200), fixed(50)), padding = pad(8),
		corner_radius = 6, border_width = 1, border_color = t.dim, overflow = .Clip,
	})
	niello.mint(&L.wide, niello.NO_UNIT, {
		size = size(fixed(320), fixed(30)), padding = pad_xy(8, 7), corner_radius = 4,
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
		font_size = 16, font_color = t.ink, groups = []niello.Group{controls.groups.ink},
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
		groups = []niello.Group{controls.groups.ink, controls.groups.raised},
	})
	niello.mint(&T.justified, T.wrapped, {justify = true})
	niello.group_add(controls.groups.ink, T.justified)
	niello.group_add(controls.groups.raised, T.justified)
	aligns := [3]niello.Align_Kind{.Start, .Center, .End}
	for k in 0 ..< 3 {
		niello.mint(&T.valign[k], niello.NO_UNIT, {
			size = size(fixed(170), fixed(70)), padding = pad(8), corner_radius = 6,
			color = t.raised, font_size = 13, font_color = t.ink,
			align = niello.align(aligns[k], aligns[k]),
			groups = []niello.Group{controls.groups.raised, controls.groups.ink},
		})
	}
	niello.mint(&T.ws_box, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(fit(), fit()),
		color = t.bg, corner_radius = 4, groups = []niello.Group{controls.groups.bg},
	})
	niello.mint(&T.collapse, niello.NO_UNIT, {font_size = 14, font_color = t.ink, color = rgb(0x3d5a8c, 160), groups = []niello.Group{controls.groups.ink}})
	niello.mint(&T.preserve, niello.NO_UNIT, {font_size = 14, font_color = t.ink, whitespace = .Preserve, color = rgb(0x3d5a8c, 160), groups = []niello.Group{controls.groups.ink}})
	niello.mint(&T.trim_box, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(fixed(240), fixed(30)), padding = pad_xy(8, 6),
		overflow = .Clip, corner_radius = 4, color = t.raised, groups = []niello.Group{controls.groups.raised},
	})
	niello.mint(&T.ellipsis, niello.NO_UNIT, {font_size = 13, font_color = t.ink, groups = []niello.Group{controls.groups.ink}})
	niello.mint(&T.no_ellipsis, niello.NO_UNIT, {font_size = 13, font_color = t.ink, ellipsis = false, groups = []niello.Group{controls.groups.ink}})

	niello.mint(&input_units.key_box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fixed(230)), padding = pad(12), gap = 2,
		color = t.bg, corner_radius = 8, focusable = true, cursor = .Text,
		focus_ring = .Always, overflow = .Clip,
		groups = []niello.Group{controls.groups.bg},
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
	controls.text_box_destroy(&app.input.name)
	controls.text_box_destroy(&app.input.email)
	delete(app.input.submitted)
}
