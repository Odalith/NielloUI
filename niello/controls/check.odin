package controls

import niello ".."

// ---- check box and radio group ----------------------------------------------

// Check_Parts: the row (box + label), the box, its checked variant (an
// accent fill with the check mark), the box's disabled look, and the
// label, which wraps.
Check_Parts :: struct {
	row, box, box_on, box_disabled, label: niello.Unit,
}

// Radio_Parts: a group's container (a column, or a row with horizontal),
// each option's row (ring + label), the ring, its selected variant, the
// dot a selected ring shows, the ring's disabled look, and each option's
// label, which wraps.
Radio_Parts :: struct {
	column, row_group:             niello.Unit,
	row, ring, ring_on, dot:       niello.Unit,
	ring_disabled, label:          niello.Unit,
}

// CHECK_SIZE is a check box's box, and a radio button's ring, in DIP.
CHECK_SIZE :: 18
// RADIO_DOT is the dot a selected radio button shows, in DIP.
RADIO_DOT :: 8

// CHECK_MARK is the glyph a checked box shows.
CHECK_MARK :: "✓"

@(private)
mint_check :: proc(t: Theme) {
	// A row: the box or ring and its label, the whole row clickable and
	// one Tab stop (the engine's focus ring goes round it). The label
	// wraps when the row is narrower than it, so a row short of space
	// gives way first (priority -1): its label takes another line before
	// a neighbour (a button beside it) is cut short. The box sits at the
	// label's first line.
	row := niello.Style_Decl{
		layout = .Left_To_Right, size = niello.size(niello.fit(priority = -1), niello.fit()), gap = spacing.control_gap,
		align = niello.align(.Start, .Start), padding = niello.pad_xy(2, 4), corner_radius = 6,
		cursor = .Pointer, focusable = true,
		group_masks = joins(as(groups.control_gap, .Gap)),
	}
	// The label: the label part's look, wrapping (a part of its own, so
	// restyling it leaves other labels alone).
	label := niello.Style_Decl{
		font_size = type_sizes.body, font_color = t.ink, disabled = parts.label.disabled, wrap = .Word,
		group_masks = joins(as(groups.ink, .Font_Color), as(groups.body, .Font_Size)),
	}
	C := &parts.check
	niello.mint(&C.row, niello.NO_UNIT, row)
	niello.mint(&C.label, niello.NO_UNIT, label)
	niello.mint(&C.box_disabled, niello.NO_UNIT, {opacity = 110})
	niello.mint(&C.box, niello.NO_UNIT, {
		size = niello.size(niello.fixed(CHECK_SIZE), niello.fixed(CHECK_SIZE)), corner_radius = 4,
		align = niello.CENTER, border_width = 2, border_color = t.dim,
		font_size = 13, font_weight = .Bold, font_color = t.on_accent,
		disabled = C.box_disabled,
		group_masks = joins(as(groups.outline, .Border_Color), as(groups.on_accent, .Font_Color)),
	})
	niello.mint(&C.box_on, niello.NO_UNIT, {
		color = t.accent, border_width = 0,
		group_masks = joins(as(groups.accent, .Color)),
	})

	R := &parts.radio
	niello.mint(&R.column, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fit(priority = -1), niello.fit()), gap = 2,
	})
	niello.mint(&R.row_group, niello.NO_UNIT, {
		layout = .Left_To_Right, size = niello.size(niello.fit(priority = -1), niello.fit()), gap = spacing.gap,
		group_masks = joins(as(groups.gap, .Gap)),
	})
	niello.mint(&R.row, niello.NO_UNIT, row)
	niello.mint(&R.label, niello.NO_UNIT, label)
	niello.mint(&R.ring_disabled, niello.NO_UNIT, {opacity = 110})
	niello.mint(&R.ring, niello.NO_UNIT, {
		layout = .Stack, size = niello.size(niello.fixed(CHECK_SIZE), niello.fixed(CHECK_SIZE)),
		corner_radius = CHECK_SIZE / 2, align = niello.CENTER, border_width = 2, border_color = t.dim,
		disabled = R.ring_disabled,
		group_masks = joins(as(groups.outline, .Border_Color)),
	})
	niello.mint(&R.ring_on, niello.NO_UNIT, {
		color = t.accent, border_width = 0,
		group_masks = joins(as(groups.accent, .Color)),
	})
	niello.mint(&R.dot, niello.NO_UNIT, {
		size = niello.size(niello.fixed(RADIO_DOT), niello.fixed(RADIO_DOT)),
		corner_radius = RADIO_DOT / 2, color = t.on_accent,
		group_masks = joins(as(groups.on_accent, .Color)),
	})
}

// checkbox is a check box labelled label: a click (or Space/Enter while
// focused) flips checked^. Reports whether checked^ changed this frame.
// A label wider than the row's room wraps onto more lines, and the row
// gives way first beside a neighbour (fit(priority = -1)), so it needs no
// size to wrap. with carries per-instance values for the row (a size,
// a11y overrides); the checkbox fills in its role (CheckBox), its name
// (label) and disabled. A size replaces the row's give-way: to fill a
// row and still give way, use grow(priority = -1).
// a11y: CheckBox, Checked while checked.
checkbox :: proc(
	label: string,
	checked: ^bool,
	disabled := false,
	with: niello.With = {},
	key: niello.Key = 0,
	loc := #caller_location,
) -> (changed: bool) {
	C := &parts.check
	w := with_a11y(with, .CheckBox, label, disabled)
	if checked^ {
		w.a11y_flags += {.Checked}
	}
	i: niello.Instance
	if niello.begin(C.row, w, key = key, out = &i, loc = loc) {
		bw := niello.With{}
		if checked^ {
			bw.variant = C.box_on
			bw.text = CHECK_MARK
		}
		niello.show(C.box, bw)
		if len(label) > 0 {
			niello.show(C.label, {text = label})
		}
	}
	if niello.clicked(i) {
		checked^ = !checked^
		changed = true
	}
	return
}

// radio_group is a group of radio buttons, one per option, of which one is
// selected: selected^ is its index (out of range: none yet). A click, or
// Space/Enter on the focused option, selects it; the arrow keys move the
// selection (and focus) to the previous or next option, wrapping. The
// group is one Tab stop, on the selected option (the first when none is).
// Options stack in a column, or sit in a row with horizontal; an option's
// text wider than its room wraps. with carries per-instance values for the
// group's container (a size, a11y overrides). Reports whether selected^
// changed this frame.
// a11y: the group is a Group named label; each option a RadioButton,
// Checked while selected.
radio_group :: proc(
	options: []string,
	selected: ^int,
	horizontal := false,
	label := "",
	disabled := false,
	with: niello.With = {},
	key: niello.Key = 0,
	loc := #caller_location,
) -> (changed: bool) {
	R := &parts.radio
	n := len(options)
	stop := selected^ >= 0 && selected^ < n ? selected^ : 0
	items := make([]niello.Instance, n, context.temp_allocator)
	gw := with_a11y(with, .Group, label, disabled)
	if niello.begin(horizontal ? R.row_group : R.column, gw, key = key, loc = loc) {
		for text, k in options {
			on := k == selected^
			w := with_a11y({focusable = k == stop}, .RadioButton, text, false)
			if on {
				w.a11y_flags += {.Checked}
			}
			if niello.begin(R.row, w, niello.key_int(k), out = &items[k]) {
				rw := niello.With{}
				if on {
					rw.variant = R.ring_on
				}
				if niello.begin(R.ring, rw) {
					if on {
						niello.show(R.dot)
					}
				}
				if len(text) > 0 {
					niello.show(R.label, {text = text})
				}
			}
		}
	}
	if n == 0 {
		return
	}
	for k in 0 ..< n {
		if niello.clicked(items[k]) && selected^ != k {
			selected^ = k
			changed = true
		}
		if !niello.focused(items[k]) {
			continue
		}
		for ev in niello.input_keys(items[k]) {
			if !ev.down {
				continue
			}
			step := 0
			#partial switch ev.key {
			case .Up, .Left:
				step = -1
			case .Down, .Right:
				step = 1
			}
			if step == 0 {
				continue
			}
			from := selected^ >= 0 && selected^ < n ? selected^ : k
			to := ((from + step) % n + n) % n
			if to != selected^ {
				selected^ = to
				changed = true
			}
			niello.focus(items[to])
		}
	}
	return
}
