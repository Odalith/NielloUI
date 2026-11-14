package controls

import "core:unicode"
import "core:unicode/utf8"
import niello ".."

// ---- combo box ---------------------------------------------------------------

// Combo_Box is one combo box's state, owned by the app. selected is the
// selected option's index (out of range: none yet, and the placeholder
// shows). The other fields are the control's own.
Combo_Box :: struct {
	selected:  int,
	open:      bool, // the list is showing
	highlight: int,  // the option the keyboard is on while open
	reveal:    bool, // scroll the highlighted option into view next frame
	box_i:     niello.Instance,
	list_i:    niello.Instance,
}

// Combo_Parts: the box (a variant of the button's surface), its text and
// placeholder, the arrow, the list popup, and the list's items: plain,
// the selected one, and the highlight they show under the pointer or the
// keyboard.
Combo_Parts :: struct {
	box, text, placeholder, arrow: niello.Unit,
	list, item, item_selected:     niello.Unit,
	item_hot:                      niello.Unit,
}

// COMBO_LIST_MAX_H is the tallest a combo box's list gets, in DIP; longer
// lists scroll.
COMBO_LIST_MAX_H :: 260

// COMBO_ARROW is the glyph at the end of a combo box.
COMBO_ARROW :: "▾"

@(private)
mint_combo :: proc(t: Theme) {
	C := &parts.combo
	B := &parts.button
	niello.mint(&C.box, B.root, {
		align = niello.align(.Start, .Center), corner_radius = 6, text_input = true,
		groups = roles(groups.raised),
		group_masks = joins(as(groups.control_pad, .Padding), as(groups.control_gap, .Gap)),
	})
	text := niello.Style_Decl{
		size = niello.size(niello.grow(), niello.fit()), font_size = type_sizes.body, font_color = t.ink,
		disabled = parts.label.disabled,
		group_masks = joins(as(groups.ink, .Font_Color), as(groups.body, .Font_Size)),
	}
	niello.mint(&C.text, niello.NO_UNIT, text)
	text.font_color = t.dim
	text.group_masks = joins(as(groups.dim, .Font_Color), as(groups.body, .Font_Size))
	niello.mint(&C.placeholder, niello.NO_UNIT, text)
	niello.mint(&C.arrow, niello.NO_UNIT, {
		font_size = type_sizes.body, font_color = t.dim,
		group_masks = joins(as(groups.dim, .Font_Color), as(groups.body, .Font_Size)),
	})
	niello.mint(&C.list, niello.NO_UNIT, {
		layout = .Top_To_Bottom, scroll = .Vertical, padding = niello.pad(4), gap = 0,
		color = t.panel, corner_radius = 6, border_width = 1, border_color = t.dim,
		group_masks = joins(as(groups.panel, .Color), as(groups.outline, .Border_Color)),
	})
	niello.mint(&C.item_hot, niello.NO_UNIT, {color = t.hover, group_masks = joins(as(groups.hover, .Color))})
	item := niello.Style_Decl{
		size = niello.size(niello.grow(), niello.fit()), padding = niello.pad_xy(10, 6), corner_radius = 4,
		font_size = type_sizes.body, font_color = t.ink, cursor = .Pointer,
		group_masks = joins(as(groups.ink, .Font_Color), as(groups.body, .Font_Size)),
	}
	niello.mint(&C.item, niello.NO_UNIT, item)
	item.font_weight = .Bold
	niello.mint(&C.item_selected, niello.NO_UNIT, item)
}

// combo_box is a drop-down choice among options: a box showing the
// selected option (or placeholder) that opens a list of them below it (or
// above, when there is no room). A click on the box opens or closes the
// list; a click on an option selects it and closes the list; a press
// elsewhere, Esc or moving focus away closes it without a change.
//
// The keyboard, while the box has focus:
//   - closed: Up/Down change the selection directly, Home/End go to the
//     ends; Space, Enter or Alt+Down open the list;
//   - open: Up/Down move the highlight, Home/End go to the ends, Enter
//     selects the highlighted option, Esc closes;
//   - typing a letter jumps to the next option starting with it.
//
// The box is as wide as its widest option, so it keeps its size as the
// selection changes. Reports whether cb.selected changed this frame.
// a11y: the box is a ComboBox named label, its value the selected option,
// Expanded while open; options are ComboBoxItems, the selected one Selected.
combo_box :: proc(
	cb: ^Combo_Box,
	options: []string,
	label := "",
	placeholder := "",
	disabled := false,
	key: niello.Key = 0,
	loc := #caller_location,
) -> (changed: bool) {
	C := &parts.combo
	n := len(options)
	has := cb.selected >= 0 && cb.selected < n
	if n == 0 {
		cb.open = false
	}

	// The box: sized to the widest option, so it doesn't jump.
	widest := niello.text_width(C.text, placeholder)
	for o in options {
		widest = max(widest, niello.text_width(C.text, o))
	}
	pad := spacing.control_pad
	box_w := widest + f32(spacing.control_gap) + niello.text_width(C.arrow, COMBO_ARROW) + 2 * f32(pad[0])
	w := with_a11y({size = niello.size(niello.fixed(box_w), niello.fit())}, .ComboBox, label, disabled)
	if has {
		w.value = niello.A11y_Value{text = options[cb.selected]}
	}
	if cb.open {
		w.a11y_flags += {.Expanded}
	}
	if niello.begin(C.box, w, key = key, out = &cb.box_i, loc = loc) {
		if has {
			niello.show(C.text, {text = options[cb.selected]})
		} else {
			niello.show(C.placeholder, {text = placeholder})
		}
		niello.show(C.arrow, {text = COMBO_ARROW})
	}

	// The list (its items' handles are this frame's: the pointer and the
	// reveal below read them).
	items := make([]niello.Instance, n, context.temp_allocator)
	if cb.open && !disabled {
		box, _ := niello.rect(cb.box_i)
		lw := niello.With{size = niello.size(niello.fit(min = box.size.x), niello.fit(max = COMBO_LIST_MAX_H)), role = .List}
		if niello.begin_popup(C.list, cb.box_i, .Below, lw, key = niello.Key(u64(cb.box_i)), opts = {gap = 4}, out = &cb.list_i) {
			for o, k in options {
				iw := niello.With{text = o, role = .ComboBoxItem, label = o}
				if k == cb.selected {
					iw.a11y_flags = {.Selected}
				}
				if k == cb.highlight {
					iw.variant = C.item_hot
				}
				items[k] = niello.show(k == cb.selected ? C.item_selected : C.item, iw, niello.key_int(k))
			}
		}
	}

	if disabled {
		cb.open = false
		return
	}
	set :: proc(cb: ^Combo_Box, k: int, changed: ^bool) {
		if k != cb.selected {
			cb.selected = k
			changed^ = true
		}
	}
	open_list :: proc(cb: ^Combo_Box, n: int) {
		cb.open = n > 0
		cb.highlight = cb.selected >= 0 && cb.selected < n ? cb.selected : 0
		cb.reveal = true
	}

	// Pointer: the box toggles, an option picks, the pointer highlights.
	if cb.open {
		for k in 0 ..< n {
			if niello.clicked(items[k]) {
				set(cb, k, &changed)
				cb.open = false
				break
			}
			if niello.hovered(items[k]) {
				cb.highlight = k
			}
		}
	}
	if cb.open && niello.dismiss_requested(cb.list_i) {
		// A press outside the list (the box included: the engine consumes
		// it, so no click follows), or Esc.
		cb.open = false
	} else if niello.clicked(cb.box_i) {
		if cb.open {
			cb.open = false
		} else {
			open_list(cb, n)
		}
	} else if cb.open && !niello.focused(cb.box_i) && !niello.hovered(cb.list_i) {
		cb.open = false // focus moved away (Tab, a click elsewhere)
	}

	// Keyboard (the box has text_input, so Space and Enter arrive as keys).
	if niello.focused(cb.box_i) && n > 0 {
		for ev in niello.input_keys(cb.box_i) {
			if !ev.down {
				continue
			}
			#partial switch ev.key {
			case .Up, .Down:
				step := ev.key == .Up ? -1 : 1
				if .Alt in ev.mods && ev.key == .Down && !cb.open {
					open_list(cb, n)
				} else if cb.open {
					cb.highlight = clamp(cb.highlight + step, 0, n - 1)
					cb.reveal = true
				} else {
					from := has ? cb.selected : (step > 0 ? -1 : n)
					set(cb, clamp(from + step, 0, n - 1), &changed)
				}
			case .Home, .End:
				k := ev.key == .Home ? 0 : n - 1
				if cb.open {
					cb.highlight = k
					cb.reveal = true
				} else {
					set(cb, k, &changed)
				}
			case .Space, .Enter, .Kp_Enter:
				if cb.open {
					set(cb, cb.highlight, &changed)
					cb.open = false
				} else {
					open_list(cb, n)
				}
			}
		}
		// Type to jump: the next option (after the current one, wrapping)
		// that starts with the typed letter.
		typed := niello.input_text(cb.box_i)
		if len(typed) > 0 && typed != " " {
			r, _ := utf8.decode_rune_in_string(typed)
			r = unicode.to_lower(r)
			from := cb.open ? cb.highlight : (has ? cb.selected : -1)
			for step in 1 ..= n {
				k := ((from + step) % n + n) % n
				first, _ := utf8.decode_rune_in_string(options[k])
				if unicode.to_lower(first) == r {
					if cb.open {
						cb.highlight = k
						cb.reveal = true
					} else {
						set(cb, k, &changed)
					}
					break
				}
			}
		}
	}

	// Keep the highlighted option in view (its rect is last frame's).
	if cb.open && cb.reveal && cb.highlight >= 0 && cb.highlight < n {
		item, iok := niello.rect(items[cb.highlight])
		list, lok := niello.rect(cb.list_i)
		if iok && lok {
			off := niello.scroll_offset(cb.list_i)
			top, bottom := list.pos.y + 4, list.pos.y + list.size.y - 4
			if item.pos.y < top {
				off.y -= top - item.pos.y
			} else if item.pos.y + item.size.y > bottom {
				off.y += item.pos.y + item.size.y - bottom
			}
			niello.scroll_to(cb.list_i, off)
			cb.reveal = false
		}
	}
	return
}
