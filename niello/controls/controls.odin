// Package controls is NielloUI's shipped control collection (TODO #12):
// buttons, a text box, a slider, a progress bar and a scrollbar, built on
// niello's public API only.
//
//	controls.init()                       // once, after niello is up: mints every part
//	if niello.clicked(controls.button("Save", .Primary)) { save() }
//	controls.text_box(&app.name, "Your name")
//	controls.apply_theme(controls.LIGHT, 250) // re-theme everything, gliding
//
// The convention (UI_API_Design.md §4): a control's units are its parts,
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
// look; the shipped default look is TODO #29.
package controls

import niello ".."

Color :: niello.Color

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

// Roles are the theme's groups, one per Theme color. apply_theme writes
// each role's color into the field its members use it for: surfaces take
// .Color, ink and dim take .Font_Color.
Roles :: struct {
	bg, panel, raised, hover, press: niello.Group,
	ink, dim:                        niello.Group,
	accent, accent_hot, on_accent:   niello.Group,
	danger, danger_hot, success:     niello.Group,
	selection:                       niello.Group,
}

groups: Roles

// theme is the theme last applied (init or apply_theme).
theme: Theme

// Parts are every control's units, minted once by init.
Parts :: struct {
	label:     Label_Parts,
	button:    Button_Parts,
	primary:   Button_Parts,
	danger:    Button_Parts,
	toggle_on: niello.Unit, // a toggle button's on variant (root)
	switch_:   Switch_Parts,
	text_box:  Text_Box_Parts,
	slider:    Slider_Parts,
	scrollbar: Scrollbar_Parts,
}

parts: Parts

// Label_Parts: the text controls set beside themselves (a switch's label),
// and its dimmed look when the control is disabled.
Label_Parts :: struct {
	text, disabled: niello.Unit,
}

// init creates the role groups and mints every part from t, and sets the
// engine focus ring to t's accent. Call it once, before declaring any
// control (again after niello.shutdown, which frees units and groups).
init :: proc(t := DARK) {
	theme = t
	groups = Roles{
		bg = niello.group_new("controls.bg"), panel = niello.group_new("controls.panel"),
		raised = niello.group_new("controls.raised"), hover = niello.group_new("controls.hover"),
		press = niello.group_new("controls.press"), ink = niello.group_new("controls.ink"),
		dim = niello.group_new("controls.dim"), accent = niello.group_new("controls.accent"),
		accent_hot = niello.group_new("controls.accent_hot"), on_accent = niello.group_new("controls.on_accent"),
		danger = niello.group_new("controls.danger"), danger_hot = niello.group_new("controls.danger_hot"),
		success = niello.group_new("controls.success"), selection = niello.group_new("controls.selection"),
	}
	mint_label(t)
	mint_buttons(t)
	mint_switch(t)
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
	niello.set_focus_ring({color = t.accent, width = 2, offset = 2})
}

// ---- shared helpers --------------------------------------------------------

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
		font_size = 14, font_color = t.ink, disabled = P.disabled, groups = roles(groups.ink),
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
