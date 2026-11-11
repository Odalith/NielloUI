// components.odin — the showcase's reusable pieces: style helpers,
// the shared units, and small components (button, toggle, checkbox,
// slider, text field, scrollbar, tooltip). Each component is plain
// declare code over units minted once in mint_units.
package main

import "core:fmt"
import niello "../.."

// ---- style helpers ---------------------------------------------------------

fixed   :: niello.fixed
grow    :: niello.grow
fit     :: niello.fit
percent :: niello.percent

rgb :: proc(hex: u32, a: u8 = 255) -> niello.Color {
	return niello.Color{u8(hex >> 16), u8(hex >> 8), u8(hex), a}
}

sz :: proc(w, h: niello.Sizing) -> niello.Size {
	return niello.Size{w, h}
}

// Padding is [left, top, right, bottom].
pad :: proc(all: u16) -> [4]u16 {
	return [4]u16{all, all, all, all}
}

pad_xy :: proc(x, y: u16) -> [4]u16 {
	return [4]u16{x, y, x, y}
}

CENTER       :: [2]niello.Align_Kind{.Center, .Center}
START_CENTER :: [2]niello.Align_Kind{.Start, .Center}

// ---- theme -----------------------------------------------------------------

Theme :: struct {
	bg, panel, raised, hover, press: niello.Color,
	ink, dim, accent, accent_hot:    niello.Color,
}

DARK_THEME :: Theme{
	bg = {22, 24, 30, 255}, panel = {33, 36, 45, 255}, raised = {46, 50, 62, 255},
	hover = {60, 66, 82, 255}, press = {78, 86, 108, 255},
	ink = {232, 235, 241, 255}, dim = {148, 154, 170, 255},
	accent = {92, 140, 230, 255}, accent_hot = {130, 170, 245, 255},
}

LIGHT_THEME :: Theme{
	bg = {236, 238, 243, 255}, panel = {250, 251, 253, 255}, raised = {222, 226, 234, 255},
	hover = {208, 214, 226, 255}, press = {190, 198, 214, 255},
	ink = {30, 33, 42, 255}, dim = {104, 110, 126, 255},
	accent = {50, 104, 210, 255}, accent_hot = {80, 130, 230, 255},
}

DANGER  :: niello.Color{190, 64, 60, 255}
SUCCESS :: niello.Color{70, 160, 105, 255}
WARM    :: niello.Color{232, 160, 80, 255}

// Groups locate the units each theme role belongs to; apply_theme
// broadcasts the role's color to all of them.
Theme_Groups :: struct {
	bg, panel, raised, hover, press, ink, dim: niello.Group,
}
groups: Theme_Groups

apply_theme :: proc(t: Theme, ms: u32) {
	niello.group_set(groups.bg, .Color, t.bg, ms)
	niello.group_set(groups.panel, .Color, t.panel, ms)
	niello.group_set(groups.raised, .Color, t.raised, ms)
	niello.group_set(groups.hover, .Color, t.hover, ms)
	niello.group_set(groups.press, .Color, t.press, ms)
	niello.group_set(groups.ink, .Font_Color, t.ink, ms)
	niello.group_set(groups.dim, .Font_Color, t.dim, ms)
}

// ---- shared units ----------------------------------------------------------

Units :: struct {
	// text
	title, heading, body, dim, small, mono, accent_text: niello.Unit,
	// containers
	column, row, card, card_row, wrap_box: niello.Unit,
	// buttons
	btn, btn_primary, btn_danger, btn_label, btn_label_on: niello.Unit,
	btn_hover, btn_press, btn_on, btn_disabled, focus_ring: niello.Unit,
	// checkbox
	check_row, check_box, check_box_on: niello.Unit,
	// slider
	track: niello.Unit,
	// text field
	field, field_focus, field_text, caret, placeholder: niello.Unit,
	// popups
	tooltip, tooltip_text, menu, menu_item, menu_item_hover, backdrop, dialog: niello.Unit,
}
ui: Units

mint_units :: proc(t: Theme) {
	groups = Theme_Groups{
		bg = niello.group_new("bg"), panel = niello.group_new("panel"),
		raised = niello.group_new("raised"), hover = niello.group_new("hover"),
		press = niello.group_new("press"), ink = niello.group_new("ink"),
		dim = niello.group_new("dim"),
	}
	ink := []niello.Group{groups.ink}
	dim := []niello.Group{groups.dim}

	niello.mint(&ui.title, niello.NO_UNIT, {font_size = 22, font_weight = .SemiBold, font_color = t.ink, groups = ink})
	niello.mint(&ui.heading, niello.NO_UNIT, {font_size = 15, font_weight = .SemiBold, font_color = t.ink, groups = ink})
	niello.mint(&ui.body, niello.NO_UNIT, {font_size = 14, font_color = t.ink, groups = ink})
	// Wrapped text needs a width to wrap at: a Fit-width paragraph
	// measures unwrapped, so notes grow to their parent's width.
	niello.mint(&ui.dim, niello.NO_UNIT, {size = sz(grow(), fit()), font_size = 13, font_color = t.dim, wrap = .Word, groups = dim})
	niello.mint(&ui.small, niello.NO_UNIT, {font_size = 12, font_color = t.dim, groups = dim})
	niello.mint(&ui.mono, niello.NO_UNIT, {font_size = 13, font_color = t.ink, whitespace = .Preserve, groups = ink})
	niello.mint(&ui.accent_text, niello.NO_UNIT, {font_size = 14, font_weight = .SemiBold, font_color = t.accent})

	niello.mint(&ui.column, niello.NO_UNIT, {layout = .Top_To_Bottom, size = sz(grow(), fit()), gap = 10})
	niello.mint(&ui.row, niello.NO_UNIT, {layout = .Left_To_Right, size = sz(grow(), fit()), gap = 10, align = START_CENTER})
	niello.mint(&ui.card, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(grow(), fit()),
		color = t.panel, corner_radius = 10, padding = pad(16), gap = 10,
		groups = []niello.Group{groups.panel},
	})
	niello.mint(&ui.card_row, ui.card, {layout = .Left_To_Right, align = START_CENTER})
	niello.group_add(groups.panel, ui.card_row)
	niello.mint(&ui.wrap_box, niello.NO_UNIT, {layout = .Top_To_Bottom, size = sz(fixed(300), fit())})

	niello.mint(&ui.btn_hover, niello.NO_UNIT, {color = t.hover, groups = []niello.Group{groups.hover}})
	niello.mint(&ui.btn_press, niello.NO_UNIT, {color = t.press, groups = []niello.Group{groups.press}})
	niello.mint(&ui.btn_on, niello.NO_UNIT, {color = t.accent})
	niello.mint(&ui.btn_disabled, niello.NO_UNIT, {color = t.panel, cursor = .Not_Allowed, groups = []niello.Group{groups.panel}})
	niello.mint(&ui.focus_ring, niello.NO_UNIT, {overlay_border_color = t.accent, overlay_border_width = 2})
	// A base unit passes on its style only, not its state overlays,
	// so the three button kinds share one decl instead.
	btn := niello.Style_Decl{
		layout = .Left_To_Right, size = sz(fit(), fixed(36)),
		padding = pad_xy(16, 0), align = CENTER,
		color = t.raised, corner_radius = 8, cursor = .Pointer,
		hover = ui.btn_hover, press = ui.btn_press, focus = ui.focus_ring,
		disabled = ui.btn_disabled, focusable = true,
		groups = []niello.Group{groups.raised},
	}
	niello.mint(&ui.btn, niello.NO_UNIT, btn)
	btn.groups = nil
	btn.color = t.accent
	niello.mint(&ui.btn_primary, niello.NO_UNIT, btn)
	// The danger button joins the raised group but pins its color, so
	// theme broadcasts pass it by.
	btn.color = DANGER
	btn.groups = []niello.Group{groups.raised}
	niello.mint(&ui.btn_danger, niello.NO_UNIT, btn)
	niello.pin(ui.btn_danger, niello.Fields{.Color})
	niello.mint(&ui.btn_label, niello.NO_UNIT, {font_size = 14, font_color = t.ink, groups = ink})
	niello.mint(&ui.btn_label_on, niello.NO_UNIT, {font_size = 14, font_color = niello.Color{255, 255, 255, 255}})

	niello.mint(&ui.check_row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(fit(), fixed(28)), gap = 8,
		align = START_CENTER, cursor = .Pointer, focusable = true,
		padding = pad_xy(4, 0), corner_radius = 6, focus = ui.focus_ring,
	})
	niello.mint(&ui.check_box, niello.NO_UNIT, {
		size = sz(fixed(18), fixed(18)), corner_radius = 4, align = CENTER,
		border_width = 2, border_color = t.dim, font_size = 13,
		font_color = niello.Color{255, 255, 255, 255},
	})
	niello.mint(&ui.check_box_on, niello.NO_UNIT, {color = t.accent, border_color = t.accent})

	niello.mint(&ui.track, niello.NO_UNIT, {
		layout = .Stack, size = sz(grow(), fixed(22)),
		color = t.raised, corner_radius = 11, cursor = .Pointer,
		groups = []niello.Group{groups.raised},
	})

	niello.mint(&ui.field_focus, niello.NO_UNIT, {overlay_border_color = t.accent, overlay_border_width = 2})
	niello.mint(&ui.field, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(grow(), fixed(38)),
		color = t.raised, corner_radius = 6, padding = pad_xy(10, 0),
		align = START_CENTER, cursor = .Text,
		focus = ui.field_focus, focusable = true,
		groups = []niello.Group{groups.raised},
	})
	niello.mint(&ui.field_text, niello.NO_UNIT, {font_size = 14, font_color = t.ink, whitespace = .Preserve, groups = ink})
	niello.mint(&ui.caret, niello.NO_UNIT, {size = sz(fixed(2), fixed(18)), color = t.accent})
	niello.mint(&ui.placeholder, niello.NO_UNIT, {font_size = 14, font_color = t.dim, groups = dim})

	niello.mint(&ui.tooltip, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(fit(max = 260), fit()),
		color = niello.Color{12, 14, 18, 235}, corner_radius = 6, padding = pad_xy(10, 6),
	})
	niello.mint(&ui.tooltip_text, niello.NO_UNIT, {font_size = 12, font_color = niello.Color{240, 240, 245, 255}, wrap = .Word})
	niello.mint(&ui.menu, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(fixed(190), fit()),
		color = t.panel, corner_radius = 8, border_width = 1, border_color = t.hover,
		padding = pad(4), gap = 2,
		groups = []niello.Group{groups.panel},
	})
	niello.mint(&ui.menu_item_hover, niello.NO_UNIT, {color = t.hover, groups = []niello.Group{groups.hover}})
	niello.mint(&ui.menu_item, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(grow(), fixed(30)),
		corner_radius = 5, padding = pad_xy(10, 0), align = START_CENTER,
		focusable = true, cursor = .Pointer,
		hover = ui.menu_item_hover, focus = ui.focus_ring,
	})
	niello.mint(&ui.backdrop, niello.NO_UNIT, {size = sz(percent(1), percent(1)), color = niello.Color{0, 0, 0, 120}})
	niello.mint(&ui.dialog, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(fixed(360), fit()),
		color = t.panel, corner_radius = 12, padding = pad(20), gap = 14,
		border_width = 1, border_color = t.hover,
		groups = []niello.Group{groups.panel},
	})
}

// ---- layout shorthands -----------------------------------------------------

heading :: proc(text: string, loc := #caller_location) {
	niello.show(ui.heading, {text = text, role = .Header}, loc = loc)
}

note :: proc(text: string, loc := #caller_location) {
	niello.show(ui.dim, {text = text}, loc = loc)
}

// ---- button ----------------------------------------------------------------

Button_Kind :: enum {
	Normal,
	Primary,
	Danger,
}

button :: proc(text: string, kind := Button_Kind.Normal, disabled := false, loc := #caller_location) -> (i: niello.Instance) {
	unit := ui.btn
	label := ui.btn_label
	switch kind {
	case .Normal:
	case .Primary:
		unit, label = ui.btn_primary, ui.btn_label_on
	case .Danger:
		unit, label = ui.btn_danger, ui.btn_label_on
	}
	if niello.begin(unit, {disabled = disabled, role = .Button, label = text}, out = &i, loc = loc) {
		niello.show(label, {text = text})
	}
	return
}

// toggle is a button whose "on" state is a variant overlay: the same
// unit, a persistent per-instance restyle.
toggle :: proc(text: string, on: ^bool, loc := #caller_location) -> bool {
	w := niello.With{role = .Button, label = text, a11y_flags = on^ ? {.Checked} : {}}
	if on^ {
		w.variant = ui.btn_on
	}
	i: niello.Instance
	if niello.begin(ui.btn, w, out = &i, loc = loc) {
		niello.show(on^ ? ui.btn_label_on : ui.btn_label, {text = text})
	}
	if niello.clicked(i) {
		on^ = !on^
		return true
	}
	return false
}

checkbox :: proc(text: string, checked: ^bool, loc := #caller_location) -> bool {
	w := niello.With{role = .CheckBox, label = text, a11y_flags = checked^ ? {.Checked} : {}}
	i: niello.Instance
	if niello.begin(ui.check_row, w, out = &i, loc = loc) {
		box_w := niello.With{text = checked^ ? "✓" : ""}
		if checked^ {
			box_w.variant = ui.check_box_on
		}
		niello.show(ui.check_box, box_w)
		niello.show(ui.body, {text = text})
	}
	if niello.clicked(i) {
		checked^ = !checked^
		return true
	}
	return false
}

// ---- slider ----------------------------------------------------------------

// Slider owns its fill unit: the fill's width is the value, set fresh
// each frame, so two sliders must never share it.
Slider :: struct {
	value: f32, // 0..1
	fill:  niello.Unit,
	inst:  niello.Instance,
}

slider :: proc(s: ^Slider, label: string, loc := #caller_location) -> bool {
	if s.fill == niello.NO_UNIT {
		niello.mint(&s.fill, niello.NO_UNIT, {color = DARK_THEME.accent, corner_radius = 11})
	}
	changed := false
	if niello.pressed(s.inst) || niello.dragging(s.inst) {
		if r, ok := niello.rect(s.inst); ok && r.size.x > 0 {
			v := clamp(niello.drag_pos(s.inst).x / r.size.x, 0, 1)
			changed = v != s.value
			s.value = v
		}
	}
	for ev in niello.input_keys(s.inst) {
		if !ev.down {
			continue
		}
		#partial switch ev.key {
		case .Left, .Down:
			s.value = max(0, s.value - 0.05)
			changed = true
		case .Right, .Up:
			s.value = min(1, s.value + 0.05)
			changed = true
		case .Home:
			s.value = 0
			changed = true
		case .End:
			s.value = 1
			changed = true
		}
	}
	niello.set(s.fill, .Size, sz(percent(s.value), percent(1)))
	w := niello.With{
		focusable = true, role = .Slider, label = label,
		value = niello.A11y_Value{num = s.value * 100, has_num = true, min = 0, max = 100},
	}
	if niello.begin(ui.track, w, out = &s.inst, loc = loc) {
		if niello.begin(s.fill) {}
	}
	return changed
}

// progress_bar draws a slider's track and fill with no interaction.
progress_bar :: proc(s: ^Slider, label: string, loc := #caller_location) {
	if s.fill == niello.NO_UNIT {
		niello.mint(&s.fill, niello.NO_UNIT, {color = SUCCESS, corner_radius = 11})
	}
	niello.set(s.fill, .Size, sz(percent(s.value), percent(1)))
	w := niello.With{
		role = .ProgressBar, label = label,
		value = niello.A11y_Value{num = s.value * 100, has_num = true, min = 0, max = 100},
	}
	if niello.begin(ui.track, w, loc = loc) {
		if niello.begin(s.fill) {}
	}
}

// ---- text field ------------------------------------------------------------

// Text_Field: the app owns the buffer and the caret; the engine routes
// committed text and key events to whichever instance holds focus.
Text_Field :: struct {
	buf:   [dynamic]u8,
	caret: int, // byte offset into buf
	inst:  niello.Instance,
}

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

word_before :: proc(buf: []u8, i: int) -> int {
	i := i
	for i > 0 && buf[i - 1] == ' ' {
		i -= 1
	}
	for i > 0 && buf[i - 1] != ' ' {
		i -= 1
	}
	return i
}

// text_field_input applies this frame's typing to f. Returns true when
// Enter was pressed. Call it before declaring the field.
text_field_input :: proc(f: ^Text_Field) -> (submitted: bool) {
	if f.inst == 0 {
		return false
	}
	if t := niello.input_text(f.inst); t != "" {
		inject_at(&f.buf, f.caret, ..transmute([]u8)t)
		f.caret += len(t)
	}
	for ev in niello.input_keys(f.inst) {
		if !ev.down {
			continue
		}
		ctrl := .Ctrl in ev.mods
		#partial switch ev.key {
		case .Backspace:
			if f.caret > 0 {
				lo := ctrl ? word_before(f.buf[:], f.caret) : rune_before(f.buf[:], f.caret)
				remove_range(&f.buf, lo, f.caret)
				f.caret = lo
			}
		case .Delete:
			if f.caret < len(f.buf) {
				remove_range(&f.buf, f.caret, rune_after(f.buf[:], f.caret))
			}
		case .Left:
			f.caret = ctrl ? word_before(f.buf[:], f.caret) : rune_before(f.buf[:], f.caret)
		case .Right:
			f.caret = rune_after(f.buf[:], f.caret)
		case .Home:
			f.caret = 0
		case .End:
			f.caret = len(f.buf)
		case .Enter, .Kp_Enter:
			submitted = true
		}
	}
	return
}

text_field :: proc(f: ^Text_Field, placeholder: string, loc := #caller_location) {
	w := niello.With{role = .Edit, label = placeholder, value = {text = string(f.buf[:])}}
	if niello.begin(ui.field, w, out = &f.inst, loc = loc) {
		focused := niello.focused(f.inst)
		switch {
		case len(f.buf) == 0 && !focused:
			niello.show(ui.placeholder, {text = placeholder})
		case focused:
			if f.caret > 0 {
				niello.show(ui.field_text, {text = string(f.buf[:f.caret])})
			}
			niello.show(ui.caret)
			if f.caret < len(f.buf) {
				niello.show(ui.field_text, {text = string(f.buf[f.caret:])})
			}
		case:
			niello.show(ui.field_text, {text = string(f.buf[:])})
		}
	}
}

text_field_destroy :: proc(f: ^Text_Field) {
	delete(f.buf)
}

// ---- tooltip ---------------------------------------------------------------

TOOLTIP_DELAY :: 0.5 // seconds

// tooltip shows text below anchor once the cursor has rested on it.
// hover_duration keeps frames coming while the hover lasts, so the
// tooltip appears even when nothing else is animating.
tooltip :: proc(anchor: niello.Instance, text: string) {
	if anchor == 0 || niello.hover_duration(anchor) < TOOLTIP_DELAY {
		return
	}
	if niello.begin_popup(ui.tooltip, anchor, .Below, key = niello.Key(u64(anchor)), opts = {gap = 6, stay = true}) {
		niello.show(ui.tooltip_text, {text = text})
	}
}

// ---- scrollbar -------------------------------------------------------------
//
// Declared inside its scroller, after the content, as an anchored
// child: it takes no flow slot and does not scroll with the content.
// The scroller's align places it.

Bar_Axis :: enum {
	Vertical,
	Horizontal,
}

Scrollbar :: struct {
	axis:                       Bar_Axis,
	strip_u, spacer_u, thumb_u: niello.Unit,
	hot_u:                      niello.Unit,
	strip_i, thumb_i:           niello.Instance,
	dragging:                   bool,
	grab:                       f32,
	track_down:                 bool,
}

BAR_WIDTH     :: 10
BAR_MIN_THUMB :: f32(24)

scrollbar_init :: proc(sb: ^Scrollbar, axis: Bar_Axis) {
	if sb.strip_u != niello.NO_UNIT {
		return
	}
	sb.axis = axis
	vert := axis == .Vertical
	niello.mint(&sb.strip_u, niello.NO_UNIT, {
		layout = vert ? niello.Layout.Top_To_Bottom : niello.Layout.Left_To_Right,
		size = vert ? sz(fixed(BAR_WIDTH), grow()) : sz(grow(), fixed(BAR_WIDTH)),
		padding = pad(2),
	})
	niello.mint(&sb.spacer_u, niello.NO_UNIT, {})
	niello.mint(&sb.hot_u, niello.NO_UNIT, {color = rgb(0xa0aac0)})
	niello.mint(&sb.thumb_u, niello.NO_UNIT, {
		color = rgb(0x6a7488, 200), corner_radius = 3,
		hover = sb.hot_u, press = sb.hot_u,
	})
}

scrollbar :: proc(sb: ^Scrollbar, scroller: niello.Instance, loc := #caller_location) {
	vert := sb.axis == .Vertical
	rng := niello.scroll_range(scroller)
	range_ := vert ? rng.y : rng.x
	if range_ <= 0 {
		sb.strip_i, sb.thumb_i, sb.dragging = 0, 0, false
		return
	}
	off := niello.scroll_offset(scroller)
	cur := vert ? off.y : off.x

	track := f32(0)
	if r, ok := niello.rect(sb.strip_i); ok {
		track = vert ? r.size.y : r.size.x
	} else if r, ok := niello.rect(scroller); ok {
		track = vert ? r.size.y : r.size.x
	}
	track = max(track - 4, 0) // the strip's padding
	thumb := clamp(track * track / (track + range_), BAR_MIN_THUMB, max(track, BAR_MIN_THUMB))
	travel := max(track - thumb, 0)
	pos := clamp(travel * cur / range_, 0, travel)

	if mouse, ok := niello.mouse_position(); ok && sb.thumb_i != 0 {
		m := vert ? mouse.y : mouse.x
		if niello.pressed(sb.thumb_i) {
			thumb_r, _ := niello.rect(sb.thumb_i)
			if !sb.dragging {
				sb.dragging = true
				sb.grab = m - (vert ? thumb_r.pos.y : thumb_r.pos.x)
			}
			if travel > 0 {
				strip_r, _ := niello.rect(sb.strip_i)
				start := (vert ? strip_r.pos.y : strip_r.pos.x) + 2
				frac := clamp((m - start - sb.grab) / travel, 0, 1)
				target := off
				target[vert ? 1 : 0] = frac * range_
				niello.scroll_to(scroller, target)
				pos = travel * frac
			}
		} else {
			sb.dragging = false
		}
		down := niello.pressed(sb.strip_i) && !niello.pressed(sb.thumb_i)
		if down && !sb.track_down {
			thumb_r, _ := niello.rect(sb.thumb_i)
			page := vert ? (m < thumb_r.pos.y ? -track : track) : (m < thumb_r.pos.x ? -track : track)
			target := off
			ax := vert ? 1 : 0
			target[ax] = clamp(off[ax] + page, 0, range_)
			niello.scroll_to(scroller, target)
		}
		sb.track_down = down
	}

	if vert {
		niello.set(sb.spacer_u, .Size, sz(fixed(0), fixed(pos)))
		niello.set(sb.thumb_u, .Size, sz(grow(), fixed(thumb)))
	} else {
		niello.set(sb.spacer_u, .Size, sz(fixed(pos), fixed(0)))
		niello.set(sb.thumb_u, .Size, sz(fixed(thumb), grow()))
	}
	if niello.begin(sb.strip_u, {anchored = true}, out = &sb.strip_i, loc = loc) {
		niello.show(sb.spacer_u)
		sb.thumb_i = niello.show(sb.thumb_u)
	} else {
		sb.strip_i, sb.thumb_i = 0, 0
	}
}

// ---- misc ------------------------------------------------------------------

Status :: struct {
	buf: [256]u8,
	len: int,
}

status_set :: proc(s: ^Status, format: string, args: ..any) {
	s.len = len(fmt.bprintf(s.buf[:], format, ..args))
}

status_text :: proc(s: ^Status) -> string {
	return string(s.buf[:s.len])
}
