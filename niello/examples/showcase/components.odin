// components.odin — the showcase's reusable pieces: style helpers, the
// shared units, and the small components niello/controls does not ship
// yet (tooltip). Buttons, toggles, the switch, check boxes, radio groups,
// text boxes, sliders, progress bars and scrollbars are niello/controls'.
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
import controls "../../controls"

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
//
// The theme is niello/controls': its Theme, LIGHT and DARK, and its role
// groups (controls.groups). The showcase's own units join the same roles,
// so one controls.apply_theme re-themes the shipped controls and the pages
// alike.

Theme       :: controls.Theme
DARK_THEME  :: controls.DARK
LIGHT_THEME :: controls.LIGHT

DANGER  :: niello.Color{190, 64, 60, 255}
SUCCESS :: niello.Color{70, 160, 105, 255}
WARM    :: niello.Color{232, 160, 80, 255}

// ---- shared units ----------------------------------------------------------

Units :: struct {
	// text
	title, heading, body, dim, small, mono, accent_text: niello.Unit,
	// containers
	column, row, flow, card, card_row, wrap_box: niello.Unit,
	// popups
	tooltip, tooltip_text, menu, menu_item, menu_item_hover, backdrop, dialog: niello.Unit,
}
ui: Units

// mint_units mints the showcase's own units. controls.init has run: the
// role groups exist.
//
// Each unit joins the roles it plays, for the field it plays them in:
// a color role (ink, dim, panel…), a type role for its font size, a
// spacing role for its gap or padding. The header's text-size and
// spacing sliders, like the theme switch, are then one broadcast each.
mint_units :: proc(t: Theme) {
	G := &controls.groups
	as :: controls.as
	ty := controls.DEFAULT_TYPE
	sp := controls.DEFAULT_SPACING

	niello.mint(&ui.title, niello.NO_UNIT, {
		font_size = ty.title, font_weight = .SemiBold, font_color = t.ink,
		group_masks = []niello.Group_Mask{as(G.ink, .Font_Color), as(G.title, .Font_Size)},
	})
	niello.mint(&ui.heading, niello.NO_UNIT, {
		font_size = ty.subtitle, font_weight = .SemiBold, font_color = t.ink,
		group_masks = []niello.Group_Mask{as(G.ink, .Font_Color), as(G.subtitle, .Font_Size)},
	})
	niello.mint(&ui.body, niello.NO_UNIT, {
		font_size = ty.body, font_color = t.ink,
		group_masks = []niello.Group_Mask{as(G.ink, .Font_Color), as(G.body, .Font_Size)},
	})
	// Notes fill their parent's width (a Fit-width paragraph would
	// wrap at the offered width too; grow just makes every note
	// span the card).
	niello.mint(&ui.dim, niello.NO_UNIT, {
		size = size(grow(), fit()), font_size = ty.caption, font_color = t.dim, wrap = .Word,
		group_masks = []niello.Group_Mask{as(G.dim, .Font_Color), as(G.caption, .Font_Size)},
	})
	niello.mint(&ui.small, niello.NO_UNIT, {
		font_size = ty.caption, font_color = t.dim,
		group_masks = []niello.Group_Mask{as(G.dim, .Font_Color), as(G.caption, .Font_Size)},
	})
	niello.mint(&ui.mono, niello.NO_UNIT, {
		font_size = ty.body, font_color = t.ink, whitespace = .Preserve,
		group_masks = []niello.Group_Mask{as(G.ink, .Font_Color), as(G.body, .Font_Size)},
	})
	niello.mint(&ui.accent_text, niello.NO_UNIT, {
		font_size = ty.body, font_weight = .SemiBold, font_color = t.accent,
		group_masks = []niello.Group_Mask{as(G.body, .Font_Size)},
	})

	niello.mint(&ui.column, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fit()), gap = sp.gap,
		group_masks = []niello.Group_Mask{as(G.gap, .Gap)},
	})
	niello.mint(&ui.row, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fit()), gap = sp.gap, align = START_CENTER,
		group_masks = []niello.Group_Mask{as(G.gap, .Gap)},
	})
	// A row that wraps: controls flow onto further lines instead of
	// squeezing into ellipses when the window is narrow.
	niello.mint(&ui.flow, niello.NO_UNIT, {
		layout = .Wrap, size = size(grow(), fit()), gap = sp.gap, line_gap = 4,
		align = START_CENTER, group_masks = []niello.Group_Mask{as(G.gap, .Gap)},
	})
	card_roles := []niello.Group_Mask{as(G.panel, .Color), as(G.panel_pad, .Padding), as(G.gap, .Gap)}
	niello.mint(&ui.card, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fit()),
		color = t.panel, corner_radius = 10, padding = pad(sp.panel_pad), gap = sp.gap,
		group_masks = card_roles,
	})
	// A variant shares its base's look, not its memberships: it joins too.
	niello.mint(&ui.card_row, ui.card, {layout = .Left_To_Right, align = START_CENTER, group_masks = card_roles})
	niello.mint(&ui.wrap_box, niello.NO_UNIT, {layout = .Top_To_Bottom, size = size(fixed(300), fit())})

	niello.mint(&ui.tooltip, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fit(max = 260), fit()),
		color = niello.rgb(0x0c0e12, 235), corner_radius = 6, padding = pad_xy(10, 6),
	})
	niello.mint(&ui.tooltip_text, niello.NO_UNIT, {font_size = 12, font_color = niello.rgb(0xf0f0f5), wrap = .Word})
	niello.mint(&ui.menu, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(190), fit()),
		color = t.panel, corner_radius = 8, border_width = 1, border_color = t.hover,
		padding = pad(4), gap = 2,
		groups = []niello.Group{G.panel},
	})
	niello.mint(&ui.menu_item_hover, niello.NO_UNIT, {color = t.hover, groups = []niello.Group{G.hover}})
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
		groups = []niello.Group{G.panel},
	})
}

// ---- layout shorthands -----------------------------------------------------

heading :: proc(text: string, loc := #caller_location) {
	niello.show(ui.heading, {text = text, role = .Header}, loc = loc)
}

note :: proc(text: string, loc := #caller_location) {
	niello.show(ui.dim, {text = text}, loc = loc)
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
