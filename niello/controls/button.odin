package controls

import niello ".."

// ---- button ----------------------------------------------------------------

// Button_Parts: the box and its label, and the state overlays the box uses.
// Focus needs no part: the engine's focus ring shows it.
Button_Parts :: struct {
	root, label:            niello.Unit,
	hover, press, disabled: niello.Unit,
}

Button_Kind :: enum {
	Normal,  // a raised surface
	Primary, // the accent: the main action of a view
	Danger,  // destructive actions
}

@(private)
mint_buttons :: proc(t: Theme) {
	B := &parts.button
	niello.mint(&B.hover, niello.NO_UNIT, {color = t.hover, groups = roles(groups.hover)})
	niello.mint(&B.press, niello.NO_UNIT, {color = t.press, groups = roles(groups.press)})
	niello.mint(&B.disabled, niello.NO_UNIT, {color = t.panel, cursor = .Not_Allowed, groups = roles(groups.panel)})
	niello.mint(&B.root, niello.NO_UNIT, {
		layout = .Left_To_Right, size = niello.size(niello.fit(), niello.fixed(36)),
		padding = niello.pad_xy(16, 0), align = niello.CENTER, gap = 6,
		color = t.raised, corner_radius = 8, cursor = .Pointer, focusable = true,
		hover = B.hover, press = B.press, disabled = B.disabled,
		groups = roles(groups.raised),
	})
	niello.mint(&B.label, niello.NO_UNIT, {
		font_size = 14, font_color = t.ink, disabled = parts.label.disabled, groups = roles(groups.ink),
	})

	// The accent kinds are variants of the base: its shape, padding and
	// focusability, their own surface, overlays and label.
	on_accent_label: niello.Unit
	// on_accent colors text here and fills elsewhere (the switch's knob):
	// each member joins the role for the one field it uses, or a theme
	// broadcast would paint a background behind this label.
	niello.mint(&on_accent_label, niello.NO_UNIT, {
		font_size = 14, font_color = t.on_accent,
		group_masks = []niello.Group_Mask{{groups.on_accent, {.Font_Color}}},
	})
	accent_kind :: proc(dst: ^Button_Parts, base: Button_Parts, label: niello.Unit, color, hot: Color, color_role, hot_role: niello.Group) {
		dst^ = base
		dst.label = label
		niello.mint(&dst.hover, niello.NO_UNIT, {color = hot, groups = roles(hot_role)})
		niello.mint(&dst.press, niello.NO_UNIT, {color = color, groups = roles(color_role)})
		niello.mint(&dst.root, base.root, {color = color, hover = dst.hover, press = dst.press, groups = roles(color_role)})
	}
	accent_kind(&parts.primary, parts.button, on_accent_label, t.accent, t.accent_hot, groups.accent, groups.accent_hot)
	accent_kind(&parts.danger, parts.button, on_accent_label, t.danger, t.danger_hot, groups.danger, groups.danger_hot)

	// A toggle button's on state: a persistent variant of the base root.
	niello.mint(&parts.toggle_on, niello.NO_UNIT, {color = t.accent, groups = roles(groups.accent)})
}

@(private)
kind_parts :: proc(kind: Button_Kind) -> ^Button_Parts {
	switch kind {
	case .Normal:  return &parts.button
	case .Primary: return &parts.primary
	case .Danger:  return &parts.danger
	}
	return &parts.button
}

// button declares a push button labelled text and returns its instance:
// poll it with niello.clicked (Space/Enter activate a focused button). with
// carries per-instance values (size, variant, a11y overrides); the button
// fills in its role (Button), its name (text) and disabled.
button :: proc(
	text: string,
	kind := Button_Kind.Normal,
	disabled := false,
	with: niello.With = {},
	key: niello.Key = 0,
	loc := #caller_location,
) -> (i: niello.Instance) {
	b := kind_parts(kind)
	if niello.begin(b.root, with_a11y(with, .Button, text, disabled), key = key, out = &i, loc = loc) {
		niello.show(b.label, {text = text})
	}
	return
}

// toggle_button is a button that stays on or off: a click flips on^. Its
// on state is the accent surface (a variant of the button). Reports
// whether on^ changed this frame. a11y: Button, Checked while on.
toggle_button :: proc(
	text: string,
	on: ^bool,
	disabled := false,
	key: niello.Key = 0,
	loc := #caller_location,
) -> (changed: bool) {
	b := &parts.button
	w := with_a11y({}, .Button, text, disabled)
	label := b.label
	if on^ {
		w.variant = parts.toggle_on
		w.a11y_flags += {.Checked}
		label = parts.primary.label
	}
	i: niello.Instance
	if niello.begin(b.root, w, key = key, out = &i, loc = loc) {
		niello.show(label, {text = text})
	}
	if niello.clicked(i) {
		on^ = !on^
		changed = true
	}
	return
}

// ---- switch ----------------------------------------------------------------

// Switch_Parts: the row (track + label), the track and its knob, and the
// track's on variant (accent, knob at the end).
Switch_Parts :: struct {
	row, track, knob, track_on: niello.Unit,
	track_disabled:            niello.Unit,
}

SWITCH_W :: 36
SWITCH_H :: 20

@(private)
mint_switch :: proc(t: Theme) {
	S := &parts.switch_
	niello.mint(&S.row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = niello.size(niello.fit(), niello.fixed(28)), gap = 10,
		align = niello.align(.Start, .Center), padding = niello.pad_xy(2, 0), corner_radius = 6,
		cursor = .Pointer, focusable = true,
	})
	niello.mint(&S.track_disabled, niello.NO_UNIT, {color = t.panel, groups = roles(groups.panel)})
	niello.mint(&S.track, niello.NO_UNIT, {
		layout = .Stack, size = niello.size(niello.fixed(SWITCH_W), niello.fixed(SWITCH_H)),
		padding = niello.pad(2), corner_radius = SWITCH_H / 2, align = niello.align(.Start, .Center),
		color = t.raised, border_width = 1, border_color = t.press,
		disabled = S.track_disabled, groups = roles(groups.raised),
	})
	niello.mint(&S.track_on, niello.NO_UNIT, {
		color = t.accent, align = niello.align(.End, .Center), groups = roles(groups.accent),
	})
	niello.mint(&S.knob, niello.NO_UNIT, {
		size = niello.size(niello.fixed(SWITCH_H - 4), niello.fixed(SWITCH_H - 4)),
		corner_radius = (SWITCH_H - 4) / 2, color = t.on_accent,
		group_masks = []niello.Group_Mask{{groups.on_accent, {.Color}}},
	})
}

// toggle_switch is an on/off switch labelled label: a click (or
// Space/Enter while focused) flips on^. Reports whether on^ changed this
// frame. a11y: CheckBox, Checked while on.
toggle_switch :: proc(
	label: string,
	on: ^bool,
	disabled := false,
	key: niello.Key = 0,
	loc := #caller_location,
) -> (changed: bool) {
	S := &parts.switch_
	w := with_a11y({}, .CheckBox, label, disabled)
	if on^ {
		w.a11y_flags += {.Checked}
	}
	i: niello.Instance
	if niello.begin(S.row, w, key = key, out = &i, loc = loc) {
		tw := niello.With{}
		if on^ {
			tw.variant = S.track_on
		}
		if niello.begin(S.track, tw) {
			niello.show(S.knob)
		}
		if len(label) > 0 {
			niello.show(parts.label.text, {text = label})
		}
	}
	if niello.clicked(i) {
		on^ = !on^
		changed = true
	}
	return
}
