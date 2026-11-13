// components.odin — the showcase's reusable pieces: style helpers,
// the shared units, and small components (button, toggle, checkbox,
// slider, text field, scrollbar, tooltip).
//
// The component convention: a component's units are its PARTS — public
// fields of a struct minted once (button_mint, slider_mint, …). A
// consumer restyles a part directly (niello.set(ui.button.label, …)),
// every part of a family through the theme's groups, and one instance
// through With (variant, size). There is no selector syntax because
// there is nothing hidden to select. Per-instance state (a slider's
// value, a scrollbar's drag) lives in a separate small struct the app
// owns; it holds no units, so every instance shares the parts.
package main

import "core:fmt"
import niello "../.."

// ---- style helpers ---------------------------------------------------------
//
// The core's sizing and style shorthands, aliased for brevity.

fixed   :: niello.fixed
grow    :: niello.grow
fit     :: niello.fit
percent :: niello.percent
size    :: niello.size
rgb     :: niello.rgb
pad     :: niello.pad
pad_xy  :: niello.pad_xy
CENTER  :: niello.CENTER

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
	// The engine focus ring is app-wide: one call re-themes it.
	niello.set_focus_ring({color = t.accent, width = 2, offset = 2})
}

// ---- shared units ----------------------------------------------------------

Units :: struct {
	// text
	title, heading, body, dim, small, mono, accent_text: niello.Unit,
	// containers
	column, row, card, card_row, wrap_box: niello.Unit,
	// components, by their parts
	button, button_primary, button_danger: Button,
	check:     Checkbox,
	slider:    Slider_Parts,
	field:     Field,
	scrollbar: Scrollbar_Parts,
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
	// Notes fill their parent's width (a Fit-width paragraph would
	// wrap at the offered width too; grow just makes every note
	// span the card).
	niello.mint(&ui.dim, niello.NO_UNIT, {size = size(grow(), fit()), font_size = 13, font_color = t.dim, wrap = .Word, groups = dim})
	niello.mint(&ui.small, niello.NO_UNIT, {font_size = 12, font_color = t.dim, groups = dim})
	niello.mint(&ui.mono, niello.NO_UNIT, {font_size = 13, font_color = t.ink, whitespace = .Preserve, groups = ink})
	niello.mint(&ui.accent_text, niello.NO_UNIT, {font_size = 14, font_weight = .SemiBold, font_color = t.accent})

	niello.mint(&ui.column, niello.NO_UNIT, {layout = .Top_To_Bottom, size = size(grow(), fit()), gap = 10})
	niello.mint(&ui.row, niello.NO_UNIT, {layout = .Left_To_Right, size = size(grow(), fit()), gap = 10, align = START_CENTER})
	niello.mint(&ui.card, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fit()),
		color = t.panel, corner_radius = 10, padding = pad(16), gap = 10,
		groups = []niello.Group{groups.panel},
	})
	niello.mint(&ui.card_row, ui.card, {layout = .Left_To_Right, align = START_CENTER})
	niello.group_add(groups.panel, ui.card_row)
	niello.mint(&ui.wrap_box, niello.NO_UNIT, {layout = .Top_To_Bottom, size = size(fixed(300), fit())})

	// Focus shows through the engine's ring (set_focus_ring), so no
	// component carries a ring overlay of its own.
	niello.set_focus_ring({color = t.accent, width = 2, offset = 2})
	ui.button = button_mint(t)
	// Variants inherit the base's overlays and focusability; group
	// memberships are explicit. The danger button joins the raised group
	// but pins its color, so theme broadcasts pass it by.
	ui.button_primary = button_variant(ui.button, {color = t.accent}, on_accent = true)
	ui.button_danger = button_variant(ui.button, {color = DANGER, groups = []niello.Group{groups.raised}}, on_accent = true)
	niello.pin(ui.button_danger.root, niello.Fields{.Color})
	ui.check = checkbox_mint(t)
	ui.slider = slider_mint(t)
	ui.field = field_mint(t)
	ui.scrollbar = scrollbar_mint()

	niello.mint(&ui.tooltip, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fit(max = 260), fit()),
		color = niello.rgb(0x0c0e12, 235), corner_radius = 6, padding = pad_xy(10, 6),
	})
	niello.mint(&ui.tooltip_text, niello.NO_UNIT, {font_size = 12, font_color = niello.rgb(0xf0f0f5), wrap = .Word})
	niello.mint(&ui.menu, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(190), fit()),
		color = t.panel, corner_radius = 8, border_width = 1, border_color = t.hover,
		padding = pad(4), gap = 2,
		groups = []niello.Group{groups.panel},
	})
	niello.mint(&ui.menu_item_hover, niello.NO_UNIT, {color = t.hover, groups = []niello.Group{groups.hover}})
	niello.mint(&ui.menu_item, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fixed(30)),
		corner_radius = 5, padding = pad_xy(10, 0), align = START_CENTER,
		focusable = true, cursor = .Pointer,
		hover = ui.menu_item_hover,
	})
	niello.mint(&ui.backdrop, niello.NO_UNIT, {size = size(percent(1), percent(1)), color = niello.rgb(0x000000, 120)})
	niello.mint(&ui.dialog, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(360), fit()),
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

// Button's parts: the box and its label, the state overlays the box
// uses, and the "on" pair a toggle switches to. Focus needs no part:
// the engine's ring shows it.
Button :: struct {
	root, label:            niello.Unit,
	hover, press, disabled: niello.Unit,
	on, label_on:                  niello.Unit, // a toggle's on state (root variant, label)
}

button_mint :: proc(t: Theme) -> (b: Button) {
	niello.mint(&b.hover, niello.NO_UNIT, {color = t.hover, groups = []niello.Group{groups.hover}})
	niello.mint(&b.press, niello.NO_UNIT, {color = t.press, groups = []niello.Group{groups.press}})
	niello.mint(&b.disabled, niello.NO_UNIT, {color = t.panel, cursor = .Not_Allowed, groups = []niello.Group{groups.panel}})
	niello.mint(&b.on, niello.NO_UNIT, {color = t.accent})
	niello.mint(&b.root, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(fit(), fixed(36)),
		padding = pad_xy(16, 0), align = CENTER,
		color = t.raised, corner_radius = 8, cursor = .Pointer,
		hover = b.hover, press = b.press, disabled = b.disabled,
		focusable = true,
		groups = []niello.Group{groups.raised},
	})
	niello.mint(&b.label, niello.NO_UNIT, {font_size = 14, font_color = t.ink, groups = []niello.Group{groups.ink}})
	niello.mint(&b.label_on, niello.NO_UNIT, {font_size = 14, font_color = niello.rgb(0xffffff)})
	return
}

// button_variant mints a sibling family: the root from base.root (its
// overlays come along), restyled by root_decl. on_accent gives it the
// light label of the accent-colored buttons.
button_variant :: proc(base: Button, root_decl: niello.Style_Decl, on_accent := false) -> (b: Button) {
	b = base
	niello.mint(&b.root, base.root, root_decl)
	if on_accent {
		b.label = base.label_on
	}
	return
}

button :: proc(text: string, kind := Button_Kind.Normal, disabled := false, loc := #caller_location) -> (i: niello.Instance) {
	b := &ui.button
	switch kind {
	case .Normal:
	case .Primary: b = &ui.button_primary
	case .Danger:  b = &ui.button_danger
	}
	if niello.begin(b.root, {disabled = disabled, role = .Button, label = text}, out = &i, loc = loc) {
		niello.show(b.label, {text = text})
	}
	return
}

Button_Kind :: enum {
	Normal,
	Primary,
	Danger,
}

// toggle is a button whose "on" state is a variant overlay: the same
// unit, a persistent per-instance restyle.
toggle :: proc(text: string, on: ^bool, loc := #caller_location) -> bool {
	b := &ui.button
	w := niello.With{role = .Button, label = text, a11y_flags = on^ ? {.Checked} : {}}
	if on^ {
		w.variant = b.on
	}
	i: niello.Instance
	if niello.begin(b.root, w, out = &i, loc = loc) {
		niello.show(on^ ? b.label_on : b.label, {text = text})
	}
	if niello.clicked(i) {
		on^ = !on^
		return true
	}
	return false
}

// ---- checkbox --------------------------------------------------------------

Checkbox :: struct {
	row, box, box_on: niello.Unit, // box_on: the checked variant of box
}

checkbox_mint :: proc(t: Theme) -> (c: Checkbox) {
	niello.mint(&c.row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(fit(), fixed(28)), gap = 8,
		align = START_CENTER, cursor = .Pointer, focusable = true,
		padding = pad_xy(4, 0), corner_radius = 6,
	})
	niello.mint(&c.box, niello.NO_UNIT, {
		size = size(fixed(18), fixed(18)), corner_radius = 4, align = CENTER,
		border_width = 2, border_color = t.dim, font_size = 13,
		font_color = niello.rgb(0xffffff),
	})
	niello.mint(&c.box_on, niello.NO_UNIT, {color = t.accent, border_color = t.accent})
	return
}

checkbox :: proc(text: string, checked: ^bool, loc := #caller_location) -> bool {
	c := &ui.check
	w := niello.With{role = .CheckBox, label = text, a11y_flags = checked^ ? {.Checked} : {}}
	i: niello.Instance
	if niello.begin(c.row, w, out = &i, loc = loc) {
		box_w := niello.With{text = checked^ ? "✓" : ""}
		if checked^ {
			box_w.variant = c.box_on
		}
		niello.show(c.box, box_w)
		niello.show(ui.body, {text = text})
	}
	if niello.clicked(i) {
		checked^ = !checked^
		return true
	}
	return false
}

// ---- slider ----------------------------------------------------------------

// Slider_Parts are shared by every slider and progress bar: the fill's
// length is per instance, carried by With.size.
Slider_Parts :: struct {
	track, fill, progress_fill: niello.Unit,
}

// Slider is one slider's state.
Slider :: struct {
	value: f32, // 0..1
	inst:  niello.Instance,
}

slider_mint :: proc(t: Theme) -> (p: Slider_Parts) {
	niello.mint(&p.track, niello.NO_UNIT, {
		layout = .Stack, size = size(grow(), fixed(22)),
		color = t.raised, corner_radius = 11, cursor = .Pointer,
		groups = []niello.Group{groups.raised},
	})
	niello.mint(&p.fill, niello.NO_UNIT, {color = t.accent, corner_radius = 11})
	niello.mint(&p.progress_fill, niello.NO_UNIT, {color = SUCCESS, corner_radius = 11})
	return
}

slider :: proc(s: ^Slider, label: string, loc := #caller_location) -> bool {
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
	w := niello.With{
		focusable = true, role = .Slider, label = label,
		value = niello.A11y_Value{num = s.value * 100, has_num = true, min = 0, max = 100},
	}
	if niello.begin(ui.slider.track, w, out = &s.inst, loc = loc) {
		niello.show(ui.slider.fill, {size = size(percent(s.value), percent(1))})
	}
	return changed
}

// progress_bar draws a slider's track and fill with no interaction.
progress_bar :: proc(s: ^Slider, label: string, loc := #caller_location) {
	w := niello.With{
		role = .ProgressBar, label = label,
		value = niello.A11y_Value{num = s.value * 100, has_num = true, min = 0, max = 100},
	}
	if niello.begin(ui.slider.track, w, loc = loc) {
		niello.show(ui.slider.progress_fill, {size = size(percent(s.value), percent(1))})
	}
}

// ---- text field ------------------------------------------------------------

Field :: struct {
	box, focus, text, caret, placeholder: niello.Unit,
}

field_mint :: proc(t: Theme) -> (f: Field) {
	// focus is state styling (the field sinks to the page color while
	// it is being edited); the engine ring is the focus indicator, and
	// a field shows it on click too (focus_ring = .Always).
	niello.mint(&f.focus, niello.NO_UNIT, {color = t.bg, groups = []niello.Group{groups.bg}})
	niello.mint(&f.box, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fixed(38)),
		color = t.raised, corner_radius = 6, padding = pad_xy(10, 0),
		align = START_CENTER, cursor = .Text,
		focus = f.focus, focusable = true, focus_ring = .Always,
		groups = []niello.Group{groups.raised},
	})
	niello.mint(&f.text, niello.NO_UNIT, {font_size = 14, font_color = t.ink, whitespace = .Preserve, groups = []niello.Group{groups.ink}})
	niello.mint(&f.caret, niello.NO_UNIT, {size = size(fixed(2), fixed(18)), color = t.accent})
	niello.mint(&f.placeholder, niello.NO_UNIT, {font_size = 14, font_color = t.dim, groups = []niello.Group{groups.dim}})
	return
}

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
	p := &ui.field
	if niello.begin(p.box, w, out = &f.inst, loc = loc) {
		focused := niello.focused(f.inst)
		switch {
		case len(f.buf) == 0 && !focused:
			niello.show(p.placeholder, {text = placeholder})
		case focused:
			if f.caret > 0 {
				niello.show(p.text, {text = string(f.buf[:f.caret])})
			}
			niello.show(p.caret)
			if f.caret < len(f.buf) {
				niello.show(p.text, {text = string(f.buf[f.caret:])})
			}
		case:
			niello.show(p.text, {text = string(f.buf[:])})
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

// Scrollbar_Parts are shared by every bar: the thumb's length and its
// offset (the spacer) are per instance, carried by With.size.
Scrollbar_Parts :: struct {
	strip:               [Bar_Axis]niello.Unit,
	spacer, thumb, hot:  niello.Unit,
}

// Scrollbar is one bar's state: its axis, and its drag.
Scrollbar :: struct {
	axis:             Bar_Axis,
	strip_i, thumb_i: niello.Instance,
	dragging:         bool,
	grab:             f32,
	track_down:       bool,
}

BAR_WIDTH     :: 10
BAR_MIN_THUMB :: f32(24)

scrollbar_mint :: proc() -> (p: Scrollbar_Parts) {
	for axis in Bar_Axis {
		vert := axis == .Vertical
		niello.mint(&p.strip[axis], niello.NO_UNIT, {
			layout = vert ? niello.Layout.Top_To_Bottom : niello.Layout.Left_To_Right,
			size = vert ? size(fixed(BAR_WIDTH), grow()) : size(grow(), fixed(BAR_WIDTH)),
			padding = pad(2),
		})
	}
	niello.mint(&p.spacer, niello.NO_UNIT, {})
	niello.mint(&p.hot, niello.NO_UNIT, {color = rgb(0xa0aac0)})
	niello.mint(&p.thumb, niello.NO_UNIT, {
		color = rgb(0x6a7488, 200), corner_radius = 3,
		hover = p.hot, press = p.hot,
	})
	return
}

scrollbar_init :: proc(sb: ^Scrollbar, axis: Bar_Axis) {
	sb.axis = axis
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

	// The parts are shared; this bar's geometry rides on With.size.
	spacer_size := vert ? size(fixed(0), fixed(pos)) : size(fixed(pos), fixed(0))
	thumb_size := vert ? size(grow(), fixed(thumb)) : size(fixed(thumb), grow())
	p := &ui.scrollbar
	if niello.begin(p.strip[sb.axis], {anchored = true}, out = &sb.strip_i, loc = loc) {
		niello.show(p.spacer, {size = spacer_size})
		sb.thumb_i = niello.show(p.thumb, {size = thumb_size})
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
