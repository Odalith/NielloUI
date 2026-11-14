package controls

import "core:strings"
import "core:unicode/utf8"
import niello ".."

// ---- text box --------------------------------------------------------------
//
// A single-line text input. The app owns the state (Text_Box); the box
// applies the input routed to it each frame, then declares itself:
//
//	app.name: controls.Text_Box            // zero value: empty, editable
//	if r := controls.text_box(&app.name, "Your name"); r.submitted { … }
//	controls.text_box_text(&app.name)       // the current text
//	controls.text_box_destroy(&app.name)
//
// Editing: typing replaces the selection; Backspace/Delete (with the word
// modifier: by word); Left/Right (word modifier: by word; Shift extends);
// Home/End (Shift extends); select all / copy / cut / paste and undo / redo
// (Ctrl, or Cmd on macOS: A, C, X, V, Z, Y and Shift+Z). Enter reports
// submitted. Mouse: a press places the caret, a drag selects, a double click
// selects a word, a triple click everything. The box scrolls sideways to
// keep the caret in view. Not in v1: multi-line, IME composition display,
// Shift+click.
//
// a11y: Edit, named by the placeholder, valued by the text, ReadOnly while
// read-only.

// Text_Box_Parts are the text box's parts: the box and its state overlays,
// the text and placeholder, and the caret and selection marks.
Text_Box_Parts :: struct {
	box, focus, disabled:    niello.Unit, // the box and its state overlays
	content:                 niello.Unit, // the layers' row
	text, placeholder:       niello.Unit,
	caret, selection, spacer: niello.Unit,
	layer:                   niello.Unit, // a spacer-then-mark row (caret, selection)
}

// Text_Box is one text box's state, owned by the app: its text, the caret
// and selection (anchor..caret), its undo history, and whether it is
// read-only or disabled. The zero value is an empty, editable box; free it
// with text_box_destroy.
Text_Box :: struct {
	buf:       [dynamic]u8,
	caret:     int, // byte offset into buf
	anchor:    int, // the selection's other end; == caret: no selection
	read_only: bool,
	disabled:  bool,
	inst:      niello.Instance,

	undo, redo: [dynamic]Text_Box_Edit,
	last_op:    Edit_Op, // what the last edit was, for coalescing undo steps
}

// Text_Box_Edit is one undo step: the state before an edit.
@(private)
Text_Box_Edit :: struct {
	text:          string, // owned
	caret, anchor: int,
}

@(private)
Edit_Op :: enum u8 {
	None,
	Type,
	Delete,
}

// UNDO_LIMIT is how many undo steps a text box keeps.
UNDO_LIMIT :: 100

// Text_Box_Result is what happened to a text box this frame.
Text_Box_Result :: struct {
	changed:   bool, // the text changed this frame
	submitted: bool, // Enter was pressed
}

// The shortcut modifier (clipboard, undo, select all) and the word
// modifier (word moves and deletes): Ctrl, or Cmd / Option on macOS.
when ODIN_OS == .Darwin {
	CMD_MOD  :: niello.Modifier.Super
	WORD_MOD :: niello.Modifier.Alt
} else {
	CMD_MOD  :: niello.Modifier.Ctrl
	WORD_MOD :: niello.Modifier.Ctrl
}

// CARET_W is the caret's width in DIP.
CARET_W :: 2

@(private)
mint_text_box :: proc(t: Theme) {
	P := &parts.text_box
	niello.mint(&P.focus, niello.NO_UNIT, {color = t.bg, groups = roles(groups.bg)})
	niello.mint(&P.disabled, niello.NO_UNIT, {color = t.panel, cursor = .Not_Allowed, groups = roles(groups.panel)})
	niello.mint(&P.box, niello.NO_UNIT, {
		// Its height is a line of its text plus the vertical control_pad:
		// it follows the type and the spacing.
		layout = .Stack, size = niello.size(niello.grow(), niello.fit()),
		padding = niello.pad_xy(spacing.control_pad[0], spacing.control_pad[1]),
		align = niello.align(.Start, .Center),
		group_masks = joins(as(groups.control_pad, .Padding)),
		scroll = .Horizontal, color = t.raised, corner_radius = 6, cursor = .Text,
		focusable = true, focus_ring = .Always, text_input = true, focus = P.focus, disabled = P.disabled,
		groups = roles(groups.raised),
	})
	niello.mint(&P.text, niello.NO_UNIT, {
		font_size = type_sizes.body, font_color = t.ink, whitespace = .Preserve, ellipsis = false,
		disabled = parts.label.disabled,
		group_masks = joins(as(groups.ink, .Font_Color), as(groups.body, .Font_Size)),
	})
	niello.mint(&P.placeholder, niello.NO_UNIT, {
		font_size = type_sizes.body, font_color = t.dim, ellipsis = false,
		group_masks = joins(as(groups.dim, .Font_Color), as(groups.body, .Font_Size)),
	})
	niello.mint(&P.layer, niello.NO_UNIT, {layout = .Left_To_Right, size = niello.size(niello.fit(), niello.fit()), align = niello.align(.Start, .Center)})
	niello.mint(&P.spacer, niello.NO_UNIT, {})
	// The caret's and the selection's height is the text's line height, set
	// per frame (text_box), so both follow the type.
	niello.mint(&P.caret, niello.NO_UNIT, {size = niello.size(niello.fixed(CARET_W), niello.fixed(type_sizes.body)), color = t.accent, groups = roles(groups.accent)})
	niello.mint(&P.selection, niello.NO_UNIT, {corner_radius = 2, color = t.selection, groups = roles(groups.selection)})
}

// text_box applies this frame's input to tb, then declares it. placeholder
// shows while the box is empty, and names it for accessibility.
text_box :: proc(tb: ^Text_Box, placeholder: string, key: niello.Key = 0, loc := #caller_location) -> (r: Text_Box_Result) {
	P := &parts.text_box
	clamp_state(tb)
	r = apply_input(tb)

	w := with_a11y({}, .Edit, placeholder, tb.disabled)
	w.value = niello.A11y_Value{text = string(tb.buf[:])}
	if tb.read_only {
		w.a11y_flags += {.ReadOnly}
	}
	focused := niello.focused(tb.inst)
	lh := niello.text_line_height(P.text)
	if niello.begin(P.box, w, key = key, out = &tb.inst, loc = loc) {
		lo, hi := selection(tb)
		if focused && lo != hi {
			x0 := niello.text_width(P.text, string(tb.buf[:lo]))
			x1 := niello.text_width(P.text, string(tb.buf[:hi]))
			if niello.begin(P.layer) {
				niello.show(P.spacer, {size = niello.size(niello.fixed(x0), niello.fixed(1))})
				niello.show(P.selection, {size = niello.size(niello.fixed(x1 - x0), niello.fixed(lh))})
			}
		}
		if len(tb.buf) == 0 {
			niello.show(P.placeholder, {text = placeholder})
		} else {
			niello.show(P.text, {text = string(tb.buf[:])})
		}
		if focused {
			cx := niello.text_width(P.text, string(tb.buf[:tb.caret]))
			if niello.begin(P.layer) {
				niello.show(P.spacer, {size = niello.size(niello.fixed(cx), niello.fixed(1))})
				niello.show(P.caret, {size = niello.size(niello.fixed(CARET_W), niello.fixed(lh))})
			}
			keep_caret_visible(tb, cx)
		}
	}
	return
}

// text_box_text is tb's current text (borrowed: valid until tb changes).
text_box_text :: proc(tb: ^Text_Box) -> string {
	return string(tb.buf[:])
}

// text_box_set replaces tb's text, putting the caret at the end and
// clearing the undo history.
text_box_set :: proc(tb: ^Text_Box, text: string) {
	clear(&tb.buf)
	append(&tb.buf, ..transmute([]u8)text)
	tb.caret, tb.anchor = len(tb.buf), len(tb.buf)
	clear_history(tb)
}

// text_box_destroy frees tb's buffer and history.
text_box_destroy :: proc(tb: ^Text_Box) {
	clear_history(tb)
	delete(tb.buf)
	delete(tb.undo)
	delete(tb.redo)
	tb^ = {}
}

// ---- input -----------------------------------------------------------------

@(private)
apply_input :: proc(tb: ^Text_Box) -> (r: Text_Box_Result) {
	if tb.inst == 0 || tb.disabled {
		return
	}
	pointer_input(tb)
	editable := !tb.read_only
	if t := niello.input_text(tb.inst); t != "" && editable {
		clean := single_line(t)
		if len(clean) > 0 {
			insert_text(tb, clean, .Type)
			r.changed = true
		}
	}
	for ev in niello.input_keys(tb.inst) {
		if !ev.down {
			continue
		}
		shift := .Shift in ev.mods
		cmd := CMD_MOD in ev.mods
		word := WORD_MOD in ev.mods
		#partial switch ev.key {
		case .Left:
			if !shift && tb.caret != tb.anchor {
				lo, _ := selection(tb)
				tb.caret = lo
			} else {
				tb.caret = word ? word_before(tb.buf[:], tb.caret) : rune_before(tb.buf[:], tb.caret)
			}
			end_move(tb, shift)
		case .Right:
			if !shift && tb.caret != tb.anchor {
				_, hi := selection(tb)
				tb.caret = hi
			} else {
				tb.caret = word ? word_after(tb.buf[:], tb.caret) : rune_after(tb.buf[:], tb.caret)
			}
			end_move(tb, shift)
		case .Home:
			tb.caret = 0
			end_move(tb, shift)
		case .End:
			tb.caret = len(tb.buf)
			end_move(tb, shift)
		case .Backspace:
			if !editable {
				continue
			}
			if tb.caret == tb.anchor {
				tb.anchor = word ? word_before(tb.buf[:], tb.caret) : rune_before(tb.buf[:], tb.caret)
			}
			if delete_selection(tb, .Delete) {
				r.changed = true
			}
		case .Delete:
			if !editable {
				continue
			}
			if tb.caret == tb.anchor {
				tb.anchor = word ? word_after(tb.buf[:], tb.caret) : rune_after(tb.buf[:], tb.caret)
			}
			if delete_selection(tb, .Delete) {
				r.changed = true
			}
		case .Enter, .Kp_Enter:
			r.submitted = true
		case .A:
			if cmd {
				tb.anchor, tb.caret = 0, len(tb.buf)
				tb.last_op = .None
			}
		case .C:
			if cmd {
				copy_selection(tb)
			}
		case .X:
			if cmd {
				copy_selection(tb)
				if editable && delete_selection(tb, .None) {
					r.changed = true
				}
			}
		case .V:
			if cmd && editable {
				clip := single_line(niello.clipboard_text())
				if len(clip) > 0 || tb.caret != tb.anchor {
					insert_text(tb, clip, .None)
					r.changed = true
				}
			}
		case .Z:
			if cmd && editable {
				r.changed |= shift ? redo(tb) : undo(tb)
			}
		case .Y:
			if cmd && editable {
				r.changed |= redo(tb)
			}
		}
	}
	return
}

// pointer_input: a press places the caret (a double click selects a word,
// a triple click everything); holding it drags the selection.
@(private)
pointer_input :: proc(tb: ^Text_Box) {
	if !niello.pointer_pressed(tb.inst) {
		return
	}
	x, ok := pointer_x(tb)
	if !ok {
		return
	}
	at := index_at(tb, x)
	if clicks := niello.press_clicks(); clicks > 0 {
		tb.last_op = .None
		switch {
		case clicks == 2:
			tb.anchor, tb.caret = word_around(tb.buf[:], at)
		case clicks >= 3:
			tb.anchor, tb.caret = 0, len(tb.buf)
		case:
			tb.caret, tb.anchor = at, at
		}
		return
	}
	if niello.dragging(tb.inst) {
		tb.caret = at
	}
}

// pointer_x is the pointer's x in text space: from the text's start,
// scroll included.
@(private)
pointer_x :: proc(tb: ^Text_Box) -> (f32, bool) {
	r, ok := niello.rect(tb.inst)
	if !ok {
		return 0, false
	}
	p := niello.drag_pos(tb.inst)
	pad := f32(niello.style_of(parts.text_box.box).padding[0])
	return p.x - pad + niello.scroll_offset(tb.inst).x, r.size.x > 0
}

// index_at is the rune boundary nearest text-space x.
@(private)
index_at :: proc(tb: ^Text_Box, x: f32) -> int {
	if x <= 0 || len(tb.buf) == 0 {
		return 0
	}
	u := parts.text_box.text
	bounds := make([dynamic]int, 0, len(tb.buf) + 1, context.temp_allocator)
	for i := 0; i < len(tb.buf); i = rune_after(tb.buf[:], i) {
		append(&bounds, i)
	}
	append(&bounds, len(tb.buf))
	// The first boundary at or past x, then the nearer of it and the one
	// before.
	lo, hi := 0, len(bounds) - 1
	if niello.text_width(u, string(tb.buf[:])) <= x {
		return len(tb.buf)
	}
	for lo < hi {
		mid := (lo + hi) / 2
		if niello.text_width(u, string(tb.buf[:bounds[mid]])) < x {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return 0
	}
	after := niello.text_width(u, string(tb.buf[:bounds[lo]]))
	before := niello.text_width(u, string(tb.buf[:bounds[lo - 1]]))
	return x - before < after - x ? bounds[lo - 1] : bounds[lo]
}

// keep_caret_visible scrolls the box sideways so the caret (at text-space
// cx) stays inside it.
@(private)
keep_caret_visible :: proc(tb: ^Text_Box, cx: f32) {
	r, ok := niello.rect(tb.inst)
	if !ok {
		return
	}
	s := niello.style_of(parts.text_box.box)
	inner := r.size.x - f32(s.padding[0]) - f32(s.padding[2])
	if inner <= 0 {
		return
	}
	off := niello.scroll_offset(tb.inst)
	x := off.x
	if cx < x {
		x = cx
	} else if cx + CARET_W > x + inner {
		x = cx + CARET_W - inner
	}
	if x != off.x {
		niello.scroll_to(tb.inst, {max(0, x), off.y})
	}
}

// ---- editing ---------------------------------------------------------------

@(private)
selection :: proc(tb: ^Text_Box) -> (lo, hi: int) {
	return min(tb.caret, tb.anchor), max(tb.caret, tb.anchor)
}

@(private)
clamp_state :: proc(tb: ^Text_Box) {
	tb.caret = clamp(tb.caret, 0, len(tb.buf))
	tb.anchor = clamp(tb.anchor, 0, len(tb.buf))
}

@(private)
end_move :: proc(tb: ^Text_Box, extend: bool) {
	if !extend {
		tb.anchor = tb.caret
	}
	tb.last_op = .None
}

// insert_text replaces the selection with text. op is the undo coalescing
// kind: runs of typing merge into one undo step.
@(private)
insert_text :: proc(tb: ^Text_Box, text: string, op: Edit_Op) {
	lo, hi := selection(tb)
	if op == .None || tb.last_op != op || lo != hi {
		push_undo(tb)
	}
	remove_range(&tb.buf, lo, hi)
	inject_at(&tb.buf, lo, ..transmute([]u8)text)
	tb.caret = lo + len(text)
	tb.anchor = tb.caret
	tb.last_op = op
	clear_redo(tb)
}

@(private)
delete_selection :: proc(tb: ^Text_Box, op: Edit_Op) -> bool {
	lo, hi := selection(tb)
	if lo == hi {
		return false
	}
	if op == .None || tb.last_op != op {
		push_undo(tb)
	}
	remove_range(&tb.buf, lo, hi)
	tb.caret, tb.anchor = lo, lo
	tb.last_op = op
	clear_redo(tb)
	return true
}

@(private)
copy_selection :: proc(tb: ^Text_Box) {
	lo, hi := selection(tb)
	if lo != hi {
		niello.set_clipboard_text(string(tb.buf[lo:hi]))
	}
}

// single_line folds line breaks to spaces and drops other control
// characters: the box holds one line.
@(private)
single_line :: proc(s: string) -> string {
	clean := true
	for r in s {
		if r < 0x20 || r == 0x7f {
			clean = false
			break
		}
	}
	if clean {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch {
		case r == '\n' || r == '\t':
			strings.write_rune(&b, ' ')
		case r < 0x20 || r == 0x7f:
		case:
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

// ---- undo ------------------------------------------------------------------

@(private)
snapshot :: proc(tb: ^Text_Box) -> Text_Box_Edit {
	return Text_Box_Edit{text = strings.clone(string(tb.buf[:])), caret = tb.caret, anchor = tb.anchor}
}

@(private)
restore :: proc(tb: ^Text_Box, e: Text_Box_Edit) {
	clear(&tb.buf)
	append(&tb.buf, ..transmute([]u8)e.text)
	tb.caret, tb.anchor = e.caret, e.anchor
	clamp_state(tb)
	delete(e.text)
}

@(private)
push_undo :: proc(tb: ^Text_Box) {
	if len(tb.undo) >= UNDO_LIMIT {
		delete(tb.undo[0].text)
		ordered_remove(&tb.undo, 0)
	}
	append(&tb.undo, snapshot(tb))
}

@(private)
undo :: proc(tb: ^Text_Box) -> bool {
	if len(tb.undo) == 0 {
		return false
	}
	append(&tb.redo, snapshot(tb))
	restore(tb, pop(&tb.undo))
	tb.last_op = .None
	return true
}

@(private)
redo :: proc(tb: ^Text_Box) -> bool {
	if len(tb.redo) == 0 {
		return false
	}
	append(&tb.undo, snapshot(tb))
	restore(tb, pop(&tb.redo))
	tb.last_op = .None
	return true
}

@(private)
clear_redo :: proc(tb: ^Text_Box) {
	for e in tb.redo {
		delete(e.text)
	}
	clear(&tb.redo)
}

@(private)
clear_history :: proc(tb: ^Text_Box) {
	for e in tb.undo {
		delete(e.text)
	}
	clear(&tb.undo)
	clear_redo(tb)
	tb.last_op = .None
}

// ---- rune and word boundaries ------------------------------------------------

@(private)
rune_before :: proc(buf: []u8, i: int) -> int {
	i := min(i, len(buf))
	if i == 0 {
		return 0
	}
	i -= 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}

@(private)
rune_after :: proc(buf: []u8, i: int) -> int {
	if i >= len(buf) {
		return len(buf)
	}
	i := i + 1
	for i < len(buf) && (buf[i] & 0xC0) == 0x80 {
		i += 1
	}
	return i
}

@(private)
is_word_byte :: proc(buf: []u8, i: int) -> bool {
	r, _ := utf8.decode_rune(buf[i:])
	return !(r == ' ' || r == '\t' || r == '.' || r == ',' || r == ';' || r == ':' || r == '/' || r == '-' || r == '(' || r == ')')
}

// word_around is the word containing (or starting at) i, for a double
// click; on a separator, that one character.
@(private)
word_around :: proc(buf: []u8, i: int) -> (lo, hi: int) {
	at := min(i, len(buf))
	if at == len(buf) && at > 0 {
		at = rune_before(buf, at) // past the end: the last character's word
	}
	if len(buf) == 0 {
		return 0, 0
	}
	if !is_word_byte(buf, at) {
		return at, rune_after(buf, at)
	}
	lo, hi = at, at
	for lo > 0 && is_word_byte(buf, rune_before(buf, lo)) {
		lo = rune_before(buf, lo)
	}
	for hi < len(buf) && is_word_byte(buf, hi) {
		hi = rune_after(buf, hi)
	}
	return
}

// word_before: the start of the word before i (skipping separators first).
@(private)
word_before :: proc(buf: []u8, i: int) -> int {
	i := i
	for i > 0 && !is_word_byte(buf, rune_before(buf, i)) {
		i = rune_before(buf, i)
	}
	for i > 0 && is_word_byte(buf, rune_before(buf, i)) {
		i = rune_before(buf, i)
	}
	return i
}

// word_after: the end of the word at or after i (skipping separators first).
@(private)
word_after :: proc(buf: []u8, i: int) -> int {
	i := i
	for i < len(buf) && !is_word_byte(buf, i) {
		i = rune_after(buf, i)
	}
	for i < len(buf) && is_word_byte(buf, i) {
		i = rune_after(buf, i)
	}
	return i
}
