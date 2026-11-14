package model

import niello "niello:."

// ANCHOR: theme
// Theme is a value for every role.
Theme :: struct {
	surface, ink, action: niello.Color,
}

LIGHT :: Theme {
	surface = {255, 255, 255, 255},
	ink     = {30, 32, 40, 255},
	action  = {11, 87, 208, 255},
}

DARK :: Theme {
	surface = {24, 26, 32, 255},
	ink     = {228, 230, 235, 255},
	action  = {138, 180, 248, 255},
}

// Roles are the groups a theme broadcasts through: one per role.
Roles :: struct {
	surface, ink, action: niello.Group,
}

roles: Roles
page_u, label_u, action_u, delete_u: niello.Unit
// ANCHOR_END: theme

// ANCHOR: join
mint_themed :: proc(t: Theme) {
	roles = {
		surface = niello.group_new("surface"),
		ink     = niello.group_new("ink"),
		action  = niello.group_new("action"),
	}
	// Each unit joins the roles it plays, for the field it plays them with.
	niello.mint(&page_u, niello.NO_UNIT, {
		color       = t.surface,
		layout      = .Top_To_Bottom,
		group_masks = {{roles.surface, {.Color}}},
	})
	niello.mint(&label_u, niello.NO_UNIT, {
		font_color  = t.ink,
		group_masks = {{roles.ink, {.Font_Color}}},
	})
	niello.mint(&action_u, niello.NO_UNIT, {
		color       = t.action,
		font_color  = t.surface,
		group_masks = {{roles.action, {.Color}}, {roles.surface, {.Font_Color}}},
	})
	// Delete is an action too, but always red: it joins and pins.
	niello.mint(&delete_u, action_u, {
		color       = niello.rgb(0xd93025),
		group_masks = {{roles.action, {.Color}}, {roles.surface, {.Font_Color}}},
	})
	niello.pin(delete_u, {.Color})
}
// ANCHOR_END: join

// ANCHOR: apply
// apply_theme writes a theme into every role, gliding over ms (0: at once).
apply_theme :: proc(t: Theme, ms: u32 = 0) {
	niello.group_set(roles.surface, .Color, t.surface, ms)
	niello.group_set(roles.surface, .Font_Color, t.surface, ms)
	niello.group_set(roles.ink, .Font_Color, t.ink, ms)
	niello.group_set(roles.action, .Color, t.action, ms)
}
// ANCHOR_END: apply

// ANCHOR: later
dialog_u, note_u: niello.Unit

// mint_dialog runs after the app has switched themes. Minted from page_u,
// the dialog starts as a copy of page_u as it is now: the current theme.
// note_u gets its colors from its own decl, whatever the theme; joining
// ink applies nothing until the next broadcast.
mint_dialog :: proc() {
	niello.mint(&dialog_u, page_u, {
		padding     = niello.pad(24),
		group_masks = {{roles.surface, {.Color}}},
	})
	niello.mint(&note_u, niello.NO_UNIT, {
		font_color  = LIGHT.ink,
		group_masks = {{roles.ink, {.Font_Color}}},
	})
}
// ANCHOR_END: later
