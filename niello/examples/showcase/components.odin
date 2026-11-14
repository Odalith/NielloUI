// components.odin — the showcase's reusable pieces: style helpers, the
// shared units, and the small pieces only the showcase needs (heading,
// note, the status line). Every control (buttons, toggles, the switch,
// check boxes, radio groups, tooltips, text boxes, sliders, progress bars
// and scrollbars) is niello/controls'.
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
// The showcase's own palettes: a darker page under distinct sidebar and
// card surfaces, an indigo accent dark enough for white text on it, and
// secondary text with real contrast.
DARK_THEME :: Theme{
	bg = {12, 14, 19, 255}, panel = {21, 24, 32, 255}, raised = {40, 45, 58, 255},
	hover = {52, 58, 75, 255}, press = {66, 73, 94, 255},
	ink = {233, 236, 242, 255}, dim = {148, 155, 173, 255},
	accent = {84, 114, 240, 255}, accent_hot = {106, 134, 250, 255}, on_accent = {255, 255, 255, 255},
	danger = {205, 64, 64, 255}, danger_hot = {222, 84, 84, 255},
	success = {52, 176, 120, 255}, selection = {84, 114, 240, 110},
}
LIGHT_THEME :: Theme{
	bg = {243, 245, 249, 255}, panel = {255, 255, 255, 255}, raised = {236, 239, 245, 255},
	hover = {224, 229, 238, 255}, press = {210, 216, 228, 255},
	ink = {20, 24, 34, 255}, dim = {90, 98, 117, 255},
	accent = {59, 91, 219, 255}, accent_hot = {47, 77, 199, 255}, on_accent = {255, 255, 255, 255},
	danger = {200, 50, 50, 255}, danger_hot = {178, 40, 40, 255},
	success = {24, 135, 86, 255}, selection = {59, 91, 219, 70},
}

// accent_soft is the accent at low strength (the selected page's fill): a
// role of the showcase's own, since a Theme has no slot for it.
accent_soft: niello.Group
ACCENT_SOFT_DARK :: niello.Color{84, 114, 240, 46}
ACCENT_SOFT_LIGHT :: niello.Color{59, 91, 219, 30}

// line is the hairline color (card and panel edges), another role of the
// showcase's own: controls' roles each broadcast one field (hover is a
// .Color), so a border can't ride one of them.
line: niello.Group
LINE_DARK :: niello.Color{38, 43, 56, 255}
LINE_LIGHT :: niello.Color{222, 227, 236, 255}

// apply_showcase_theme re-themes the controls and the showcase's own roles
// together, gliding over ms.
apply_showcase_theme :: proc(dark: bool, ms: u32) {
	controls.apply_theme(dark ? DARK_THEME : LIGHT_THEME, ms)
	niello.group_set(accent_soft, .Color, dark ? ACCENT_SOFT_DARK : ACCENT_SOFT_LIGHT, ms)
	niello.group_set(line, .Border_Color, dark ? LINE_DARK : LINE_LIGHT, ms)
}

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
	menu, menu_item, menu_item_hover, backdrop, dialog: niello.Unit,
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
		// Capped: a line of prose much past 90 characters is hard to read.
		size = size(grow(max = 760), fit()), font_size = ty.caption, font_color = t.dim, wrap = .Word,
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
	// A card: the panel surface with a hairline edge (the line role).
	line = niello.group_new("showcase.line")
	card_roles = []niello.Group_Mask{as(G.panel, .Color), as(line, .Border_Color), as(G.panel_pad, .Padding), as(G.gap, .Gap)}
	niello.mint(&ui.card, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fit()),
		color = t.panel, corner_radius = 12, border_width = 1, border_color = LINE_DARK,
		padding = pad(sp.panel_pad), gap = sp.gap,
		group_masks = card_roles,
	})
	// A variant shares its base's look, not its memberships: it joins too.
	// Columns in a card row hang from the top: centered, a shorter
	// column's heading sat lower than its neighbour's.
	niello.mint(&ui.card_row, ui.card, {layout = .Left_To_Right, align = niello.align(.Start, .Start), group_masks = card_roles})
	niello.mint(&ui.wrap_box, niello.NO_UNIT, {layout = .Top_To_Bottom, size = size(fixed(300), fit())})

	niello.mint(&ui.menu, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(190), fit()),
		color = t.panel, corner_radius = 8, border_width = 1, border_color = LINE_DARK,
		padding = pad(4), gap = 2,
		group_masks = []niello.Group_Mask{as(G.panel, .Color), as(line, .Border_Color)},
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
		border_width = 1, border_color = LINE_DARK,
		group_masks = []niello.Group_Mask{as(G.panel, .Color), as(line, .Border_Color)},
	})
}

// ---- layout shorthands -----------------------------------------------------

heading :: proc(text: string, loc := #caller_location) {
	niello.show(ui.heading, {text = text, role = .Header}, loc = loc)
}

note :: proc(text: string, loc := #caller_location) {
	niello.show(ui.dim, {text = text}, loc = loc)
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
