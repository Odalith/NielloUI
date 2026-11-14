// Package controls is NielloUI's shipped control collection: buttons, a
// switch, check boxes, radio groups, tooltips, a text box, a slider, a
// progress bar and a scrollbar, built on niello's public API only.
//
//	controls.init()                       // once, after niello is up: mints every part
//	if niello.clicked(controls.button("Save", .Primary)) { save() }
//	controls.text_box(&app.name, "Your name")
//	controls.apply_theme(controls.LIGHT, 250) // re-theme everything, gliding
//
// The convention: a control's units are its parts,
// minted once by init and shared by every instance. They are public: restyle
// one part with niello.set (niello.set(controls.parts.button.label,
// .Font_Size, 15)), a role across every control with the theme's groups, one
// instance with the With a control takes. Per-instance state (a text box's
// buffer, a slider's value) is a small struct the app owns; it holds no units.
//
// Every control carries its accessibility role, name and state.
//
// The theme: a Theme is a set of role colors; each part joins the role groups
// it plays at mint, and apply_theme broadcasts a theme through them. An app
// adds its own units to the same roles (niello.group_add(controls.groups.ink,
// my_label)) and one apply_theme re-themes both. LIGHT and DARK are a basic
// look; a fuller default theme will follow.
package controls

import niello ".."

// Color is niello.Color.
Color :: niello.Color

// Theme is a set of role colors (see Roles): what apply_theme broadcasts.
Theme :: struct {
	bg, panel, raised:      Color, // page, panel and control surfaces
	hover, press:           Color, // state overlays on raised surfaces
	ink, dim:               Color, // text, secondary text
	accent, accent_hot:     Color, // primary actions, on states, fills, caret
	on_accent:              Color, // text and knobs on accent surfaces
	danger, danger_hot:     Color, // destructive actions
	success:                Color, // progress
	selection:              Color, // selected text
}

// DARK is the basic dark theme.
DARK :: Theme{
	bg = {22, 24, 30, 255}, panel = {33, 36, 45, 255}, raised = {46, 50, 62, 255},
	hover = {60, 66, 82, 255}, press = {78, 86, 108, 255},
	ink = {232, 235, 241, 255}, dim = {148, 154, 170, 255},
	accent = {92, 140, 230, 255}, accent_hot = {130, 170, 245, 255},
	on_accent = {255, 255, 255, 255},
	danger = {190, 64, 60, 255}, danger_hot = {215, 92, 86, 255},
	success = {70, 160, 105, 255},
	selection = {92, 140, 230, 110},
}

// LIGHT is the basic light theme.
LIGHT :: Theme{
	bg = {236, 238, 243, 255}, panel = {250, 251, 253, 255}, raised = {222, 226, 234, 255},
	hover = {208, 214, 226, 255}, press = {190, 198, 214, 255},
	ink = {30, 33, 42, 255}, dim = {104, 110, 126, 255},
	accent = {50, 104, 210, 255}, accent_hot = {80, 130, 230, 255},
	on_accent = {255, 255, 255, 255},
	danger = {190, 64, 60, 255}, danger_hot = {210, 84, 78, 255},
	success = {60, 150, 95, 255},
	selection = {50, 104, 210, 80},
}

// Type_Sizes is the type ramp: the font size of each text role. Every
// control's text plays one role, and an app's text joins the same roles
// (niello.group_add(controls.groups.body, my_label, {.Font_Size}) or a
// group_masks entry at mint), so one apply_type resizes all of it in
// proportion: apply_type(scale_type(DEFAULT_TYPE, 1.25)).
Type_Sizes :: struct {
	caption:  f32, // secondary text: notes, captions, status
	body:     f32, // control labels and running text
	subtitle: f32, // section headings
	title:    f32, // page titles
}

// DEFAULT_TYPE is the type ramp the controls start with.
DEFAULT_TYPE :: Type_Sizes{caption = 12, body = 14, subtitle = 16, title = 22}

// Spacing is the space between and inside things. Controls size from
// their content plus control_pad (a button is its label's line plus the
// vertical pad), so spacing and type together set their size. The layout
// roles are for an app's own containers.
Spacing :: struct {
	control_pad: [2]u16, // inside buttons and text boxes: horizontal, vertical
	control_gap: u16,    // between a control's own parts (a switch and its label)
	gap:         u16,    // layout: between the items of an app's rows and columns
	panel_pad:   u16,    // layout: inside an app's panels and cards
}

// DEFAULT_SPACING is the spacing the controls start with.
DEFAULT_SPACING :: Spacing{control_pad = {14, 8}, control_gap = 8, gap = 10, panel_pad = 16}

// scale_type is ty with every size times f.
scale_type :: proc(ty: Type_Sizes, f: f32) -> Type_Sizes {
	return Type_Sizes{caption = ty.caption * f, body = ty.body * f, subtitle = ty.subtitle * f, title = ty.title * f}
}

// scale_spacing is sp with every distance times f, rounded to whole DIP.
scale_spacing :: proc(sp: Spacing, f: f32) -> Spacing {
	s :: proc(v: u16, f: f32) -> u16 {
		return u16(max(0, f32(v) * f + 0.5))
	}
	return Spacing{
		control_pad = {s(sp.control_pad[0], f), s(sp.control_pad[1], f)},
		control_gap = s(sp.control_gap, f), gap = s(sp.gap, f), panel_pad = s(sp.panel_pad, f),
	}
}

// Roles are the groups the theme, the type ramp and the spacing broadcast
// through, one per token. Each member joins a role for the one field it
// uses the token for (a label joins ink for .Font_Color and body for
// .Font_Size): apply_theme, apply_type and apply_spacing write the token
// into that field of every member.
Roles :: struct {
	// colors (Theme)
	bg, panel, raised, hover, press: niello.Group,
	ink, dim:                        niello.Group,
	accent, accent_hot, on_accent:   niello.Group,
	danger, danger_hot, success:     niello.Group,
	selection:                       niello.Group,
	outline:                         niello.Group, // .Border_Color from dim: unchecked boxes and rings
	// type (Type_Sizes): .Font_Size
	caption, body, subtitle, title:  niello.Group,
	// spacing (Spacing): control_pad and panel_pad .Padding, the gaps .Gap
	control_pad, control_gap:        niello.Group,
	gap, panel_pad:                  niello.Group,
}

// groups holds the role groups (created by init).
groups: Roles

// theme is the theme last applied (init or apply_theme).
theme: Theme

// type_sizes is the type ramp last applied (init or apply_type).
type_sizes: Type_Sizes

// spacing is the spacing last applied (init or apply_spacing).
spacing: Spacing

// Parts are every control's units, minted once by init.
Parts :: struct {
	label:     Label_Parts,
	button:    Button_Parts,
	primary:   Button_Parts,
	danger:    Button_Parts,
	toggle_on: niello.Unit, // a toggle button's on variant (root)
	switch_:   Switch_Parts,
	check:     Check_Parts,
	radio:     Radio_Parts,
	tooltip:   Tooltip_Parts,
	text_box:  Text_Box_Parts,
	slider:    Slider_Parts,
	scrollbar: Scrollbar_Parts,
}

// parts holds every control's parts (minted by init): restyle one with
// niello.set(controls.parts.button.label, .Font_Size, f32(15)).
parts: Parts

// Label_Parts: the text controls set beside themselves (a switch's label),
// and its dimmed look when the control is disabled.
Label_Parts :: struct {
	text, disabled: niello.Unit,
}

// init creates the role groups and mints every part from the tokens, and
// sets the engine focus ring to t's accent. Call it once, before declaring
// any control (again after niello.shutdown, which frees units and groups).
init :: proc(t := DARK, ty := DEFAULT_TYPE, sp := DEFAULT_SPACING) {
	theme, type_sizes, spacing = t, ty, sp
	groups = Roles{
		bg = niello.group_new("controls.bg"), panel = niello.group_new("controls.panel"),
		raised = niello.group_new("controls.raised"), hover = niello.group_new("controls.hover"),
		press = niello.group_new("controls.press"), ink = niello.group_new("controls.ink"),
		dim = niello.group_new("controls.dim"), accent = niello.group_new("controls.accent"),
		accent_hot = niello.group_new("controls.accent_hot"), on_accent = niello.group_new("controls.on_accent"),
		danger = niello.group_new("controls.danger"), danger_hot = niello.group_new("controls.danger_hot"),
		success = niello.group_new("controls.success"), selection = niello.group_new("controls.selection"),
		outline = niello.group_new("controls.outline"),
		caption = niello.group_new("controls.caption"), body = niello.group_new("controls.body"),
		subtitle = niello.group_new("controls.subtitle"), title = niello.group_new("controls.title"),
		control_pad = niello.group_new("controls.control_pad"), control_gap = niello.group_new("controls.control_gap"),
		gap = niello.group_new("controls.gap"), panel_pad = niello.group_new("controls.panel_pad"),
	}
	mint_label(t)
	mint_buttons(t)
	mint_switch(t)
	mint_check(t)
	mint_tooltip(t)
	mint_text_box(t)
	mint_slider(t)
	mint_scrollbar(t)
	niello.set_focus_ring({color = t.accent, width = 2, offset = 2})
}

// apply_theme re-themes every control (and every app unit in the role
// groups), gliding over ms.
apply_theme :: proc(t: Theme, ms: u32 = 0) {
	theme = t
	G := &groups
	niello.group_set(G.bg, .Color, t.bg, ms)
	niello.group_set(G.panel, .Color, t.panel, ms)
	niello.group_set(G.raised, .Color, t.raised, ms)
	niello.group_set(G.hover, .Color, t.hover, ms)
	niello.group_set(G.press, .Color, t.press, ms)
	niello.group_set(G.ink, .Font_Color, t.ink, ms)
	niello.group_set(G.dim, .Font_Color, t.dim, ms)
	niello.group_set(G.accent, .Color, t.accent, ms)
	niello.group_set(G.accent_hot, .Color, t.accent_hot, ms)
	// on_accent members join for the field they use: labels for
	// .Font_Color, the switch knob for .Color.
	niello.group_set(G.on_accent, .Font_Color, t.on_accent, ms)
	niello.group_set(G.on_accent, .Color, t.on_accent, ms)
	niello.group_set(G.danger, .Color, t.danger, ms)
	niello.group_set(G.danger_hot, .Color, t.danger_hot, ms)
	niello.group_set(G.success, .Color, t.success, ms)
	niello.group_set(G.selection, .Color, t.selection, ms)
	niello.group_set(G.outline, .Border_Color, t.dim, ms)
	niello.set_focus_ring({color = t.accent, width = 2, offset = 2})
}

// apply_type resizes every member of the type roles, gliding over ms.
apply_type :: proc(ty: Type_Sizes, ms: u32 = 0) {
	type_sizes = ty
	niello.group_set(groups.caption, .Font_Size, ty.caption, ms)
	niello.group_set(groups.body, .Font_Size, ty.body, ms)
	niello.group_set(groups.subtitle, .Font_Size, ty.subtitle, ms)
	niello.group_set(groups.title, .Font_Size, ty.title, ms)
}

// apply_spacing respaces every member of the spacing roles, gliding over ms.
apply_spacing :: proc(sp: Spacing, ms: u32 = 0) {
	spacing = sp
	niello.group_set(groups.control_pad, .Padding, niello.pad_xy(sp.control_pad[0], sp.control_pad[1]), ms)
	niello.group_set(groups.control_gap, .Gap, sp.control_gap, ms)
	niello.group_set(groups.gap, .Gap, sp.gap, ms)
	niello.group_set(groups.panel_pad, .Padding, niello.pad(sp.panel_pad), ms)
}

// ---- shared helpers --------------------------------------------------------

// as joins a role for one field: a group_masks entry.
as :: proc(g: niello.Group, f: niello.Field) -> niello.Group_Mask {
	return niello.Group_Mask{group = g, fields = {f}}
}

// joins builds a decl's group_masks from as() entries.
@(private)
joins :: proc(ms: ..niello.Group_Mask) -> []niello.Group_Mask {
	out := make([]niello.Group_Mask, len(ms), context.temp_allocator)
	copy(out, ms)
	return out
}

// role joins a decl to role groups for every field.
@(private)
roles :: proc(gs: ..niello.Group) -> []niello.Group {
	out := make([]niello.Group, len(gs), context.temp_allocator)
	copy(out, gs)
	return out
}

@(private)
mint_label :: proc(t: Theme) {
	P := &parts.label
	niello.mint(&P.disabled, niello.NO_UNIT, {font_color = t.dim, groups = roles(groups.dim)})
	niello.mint(&P.text, niello.NO_UNIT, {
		font_size = type_sizes.body, font_color = t.ink, disabled = P.disabled,
		group_masks = joins(as(groups.ink, .Font_Color), as(groups.body, .Font_Size)),
	})
}

// with_a11y fills a control's With: the caller's With wins where it set
// something, the control supplies its role and name.
@(private)
with_a11y :: proc(w: niello.With, role: niello.A11y_Role, name: string, disabled: bool) -> niello.With {
	w := w
	if w.role == .None {
		w.role = role
	}
	if _, ok := w.label.?; !ok && len(name) > 0 {
		w.label = name
	}
	w.disabled = w.disabled || disabled
	return w
}
