// Form demo: keyboard focus and text input (TODO #8, §3.17) — and the
// seed of TODO #10's form example.
//
// Two text fields, two buttons, one tab order (declaration order).
// Tab / Shift+Tab moves, clicking a field focuses it, Enter inside a
// field jumps to the next stop. Space/Enter activates the focused
// button. The fields are demo-side components: the app owns the text
// buffer and the caret, the engine only routes input to whichever
// instance holds focus — input_text delivers committed characters,
// input_keys delivers the editing keys (Backspace, Delete, arrows,
// Home/End), and this file applies them.
package main

import "core:fmt"
import niello "../.."
import sdl "../../sdl"

BG :: niello.Color{24, 25, 32, 255}
PANEL :: niello.Color{38, 41, 54, 255}
INK :: niello.Color{232, 234, 240, 255}
DIM :: niello.Color{150, 154, 168, 255}
ACCENT :: niello.Color{84, 120, 200, 255}
BTN :: niello.Color{52, 56, 72, 255}
BTN_HOVER :: niello.Color{66, 71, 90, 255}
BTN_PRESS :: niello.Color{40, 43, 56, 255}

// SDL scancodes for the editing keys (Key_Event space is SDL's).
SC_BACKSPACE :: 42
SC_DELETE :: 76
SC_HOME :: 74
SC_END :: 77
SC_RIGHT :: 79
SC_LEFT :: 80

window_u, title_u, hint_u, caption_u, status_u: niello.Unit
field_u, field_focus_u, field_text_u, caret_u, placeholder_u: niello.Unit
btn_u, btn_hover_u, btn_press_u, btn_focus_u, btn_label_u: niello.Unit

Field :: struct {
	buf:   [dynamic]u8,
	caret: int, // byte offset into buf
	inst:  niello.Instance,
}

name_f, quest_f: Field
clear_i, submit_i: niello.Instance
status_buf: [512]u8
status: string = "Tab into a field and type."

// ---------------------------------------------------------------------------
// The text-field component (demo-side; a #12 component would own this)

rune_before :: proc(buf: []u8, i: int) -> int {
	i := i
	if i > len(buf) {
		i = len(buf)
	}
	if i == 0 {
		return 0
	}
	i -= 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}

rune_after :: proc(buf: []u8, i: int) -> int {
	i := i
	if i >= len(buf) {
		return len(buf)
	}
	i += 1
	for i < len(buf) && (buf[i] & 0xC0) == 0x80 {
		i += 1
	}
	return i
}

edit_field :: proc(f: ^Field) {
	if f.inst == 0 {
		return
	}
	if t := niello.input_text(f.inst); t != "" {
		inject_at(&f.buf, f.caret, ..transmute([]u8)t)
		f.caret += len(t)
	}
	for ev in niello.input_keys(f.inst) {
		if !ev.down {
			continue
		}
		switch ev.scancode {
		case SC_BACKSPACE:
			if f.caret > 0 {
				lo := rune_before(f.buf[:], f.caret)
				remove_range(&f.buf, lo, f.caret)
				f.caret = lo
			}
		case SC_DELETE:
			if f.caret < len(f.buf) {
				remove_range(&f.buf, f.caret, rune_after(f.buf[:], f.caret))
			}
		case SC_LEFT:
			f.caret = rune_before(f.buf[:], f.caret)
		case SC_RIGHT:
			f.caret = rune_after(f.buf[:], f.caret)
		case SC_HOME:
			f.caret = 0
		case SC_END:
			f.caret = len(f.buf)
		case niello.SCANCODE_RETURN, niello.SCANCODE_KP_ENTER:
			niello.focus_next() // Enter commits and moves on
		}
	}
}

show_field :: proc(f: ^Field, key: niello.Key, placeholder: string) {
	i, open := niello.begin(field_u, key)
	f.inst = i
	if !open {
		return
	}
	if len(f.buf) == 0 && !niello.focused(i) {
		niello.show(placeholder_u, niello.key_int(1), {text = placeholder})
	} else if niello.focused(i) {
		if f.caret > 0 {
			niello.show(field_text_u, niello.key_int(1), {text = string(f.buf[:f.caret])})
		}
		niello.show(caret_u, niello.key_int(2))
		if f.caret < len(f.buf) {
			niello.show(field_text_u, niello.key_int(3), {text = string(f.buf[f.caret:])})
		}
	} else {
		niello.show(field_text_u, niello.key_int(1), {text = string(f.buf[:])})
	}
}

// ---------------------------------------------------------------------------

mint :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = BG, padding = [4]u16{24, 24, 24, 24}, gap = 10,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 24, font_color = INK})
	niello.mint(&hint_u, niello.NO_UNIT, {font_size = 13.5, font_color = DIM})
	niello.mint(&caption_u, niello.NO_UNIT, {font_size = 13, font_color = DIM})
	niello.mint(&status_u, niello.NO_UNIT, {font_size = 13.5, font_color = DIM})

	niello.mint(&field_focus_u, niello.NO_UNIT, {
		color = niello.Color{44, 48, 64, 255},
		overlay_border_color = ACCENT, overlay_border_width = 2,
	})
	niello.mint(&field_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(1), niello.fixed(44)},
		color = PANEL, corner_radius = 6,
		padding = [4]u16{12, 0, 12, 0}, gap = 0,
		align = [2]niello.Align_Kind{.Start, .Center},
		focus = field_focus_u, focusable = true,
	})
	niello.mint(&field_text_u, niello.NO_UNIT, {
		font_size = 16, font_color = INK,
		// §3.18: editable text preserves whitespace, so the caret
		// (which sits at the pre-caret label's width) tracks spaces.
		whitespace = niello.Whitespace.Preserve,
	})
	niello.mint(&caret_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(2), niello.fixed(22)},
		color = ACCENT,
	})
	niello.mint(&placeholder_u, niello.NO_UNIT, {font_size = 16, font_color = DIM})

	niello.mint(&btn_hover_u, niello.NO_UNIT, {color = BTN_HOVER})
	niello.mint(&btn_press_u, niello.NO_UNIT, {color = BTN_PRESS})
	niello.mint(&btn_focus_u, niello.NO_UNIT, {
		overlay_border_color = ACCENT, overlay_border_width = 2,
	})
	niello.mint(&btn_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(130), niello.fixed(40)},
		color = BTN, corner_radius = 6,
		align = [2]niello.Align_Kind{.Center, .Center},
		hover = btn_hover_u, press = btn_press_u, focus = btn_focus_u,
		focusable = true, cursor = niello.Cursor_Kind.Pointer,
	})
	niello.mint(&btn_label_u, niello.NO_UNIT, {font_size = 15, font_color = INK})
	niello.mint(&buttons_row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right, gap = 12,
	})
}

declare :: proc() {
	// Input first, against last frame's instances; display after.
	edit_field(&name_f)
	edit_field(&quest_f)

	root_i, open := niello.begin(window_u)
	_ = root_i
	if !open {
		return
	}
	niello.show(title_u, 0, {text = "Form"})
	niello.show(hint_u, 0, {text = "Tab / Shift+Tab to move · click a field to focus · Enter jumps on · Space/Enter pushes a focused button"})

	niello.show(caption_u, 0, {text = "NAME"})
	show_field(&name_f, niello.key_int(1), "e.g. Ada")
	niello.show(caption_u, 0, {text = "QUEST"})
	show_field(&quest_f, niello.key_int(2), "e.g. To seek the grail")

	declare_buttons()

	focus_name := "nothing"
	if niello.focused(name_f.inst) {
		focus_name = "Name"
	} else if niello.focused(quest_f.inst) {
		focus_name = "Quest"
	} else if niello.focused(clear_i) {
		focus_name = "Clear"
	} else if niello.focused(submit_i) {
		focus_name = "Submit"
	}
	niello.show(status_u, 0, {text = fmt.bprintf(focus_buf[:], "focused: %s", focus_name)})
	niello.show(status_u, 0, {text = status})
}

buttons_row_u: niello.Unit
focus_buf: [128]u8

declare_buttons :: proc() {
	if _, ok := niello.begin(buttons_row_u); !ok {
		return
	}
	if i, ok := niello.begin(btn_u, niello.key_int(1)); ok {
		clear_i = i
		niello.show(btn_label_u, 0, {text = "Clear"})
		if niello.clicked(i) {
			clear(&name_f.buf)
			clear(&quest_f.buf)
			name_f.caret, quest_f.caret = 0, 0
			status = "Cleared."
		}
	}
	if i, ok := niello.begin(btn_u, niello.key_int(2)); ok {
		submit_i = i
		niello.show(btn_label_u, 0, {text = "Submit"})
		if niello.clicked(i) {
			if len(name_f.buf) == 0 {
				status = "The name field is empty — Tab over and type something."
			} else {
				status = fmt.bprintf(
					status_buf[:],
					"Submitted — name: %s · quest: %s",
					string(name_f.buf[:]),
					string(quest_f.buf[:]),
				)
			}
		}
	}
}

main :: proc() {
	mint()
	sdl.run({title = "NielloUI — form", width = 680, height = 520}, declare)
}
