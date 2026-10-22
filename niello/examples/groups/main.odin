// niello/examples/groups — the group demo: one broadcast, many components.
//
// A group is an address book of (unit, field-mask) members: it locates
// units so a caller higher up can change them everywhere with group_set.
// Joining applies nothing, and there is no retained patch — a unit's
// birth values come from its base at mint. This demo makes that visible:
//
//   - The theme button flips between light and dark with two broadcasts
//     (surface colors, text colors). Everything in the groups follows.
//   - "Add a card" mints a new card from the base unit AT RUNTIME. It is
//     born in the base (light) palette even while the dark theme is up,
//     because it missed those broadcasts. The next switch reaches it.
//   - The danger button is a full member of the surfaces group with its
//     Color PINNED: broadcasts recolor everything around it, never it.
//     (Pin is for exactly this — a reason that is obvious at a glance.)
//
// The controls keep a constant slate scheme; only the content themes.
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md):
//
//	odin run niello/examples/groups -extra-linker-flags:"-L..."
package main

import "core:fmt"
import niello "../.."
import niello_sdl "../../sdl"

// Cold units.
window_u:     niello.Unit
title_u:      niello.Unit
hint_u:       niello.Unit
btn_label_u:  niello.Unit // button text: constant scheme, never grouped
card_title_u: niello.Unit
card_body_u:  niello.Unit
theme_btn_u:  niello.Unit
add_btn_u:    niello.Unit
danger_u:     niello.Unit
row_u:        niello.Unit
card_base_u:  niello.Unit // every card is minted from this base
ov_hover_u:   niello.Unit
ov_press_u:   niello.Unit

// The two theme groups, by role. surfaces takes Color broadcasts,
// texts takes Font_Color broadcasts.
surfaces: niello.Group
texts:    niello.Group

// App state.
dark:          bool
cards:         [dynamic]niello.Unit
card_notes:    [dynamic]string
danger_clicks: int
theme_i, add_i, danger_i: niello.Instance

LIGHT_SURFACE :: niello.Color{233, 235, 239, 255}
LIGHT_TEXT    :: niello.Color{32, 34, 42, 255}
DARK_SURFACE  :: niello.Color{43, 46, 56, 255}
DARK_TEXT     :: niello.Color{232, 234, 240, 255}
DANGER_RED    :: niello.Color{178, 60, 58, 255}

apply_theme :: proc() {
	// The whole theme switch is these two calls: group_set copies the
	// value into each member's owned style through the set path.
	if dark {
		niello.group_set(surfaces, .Color, DARK_SURFACE)
		niello.group_set(texts, .Font_Color, DARK_TEXT)
	} else {
		niello.group_set(surfaces, .Color, LIGHT_SURFACE)
		niello.group_set(texts, .Font_Color, LIGHT_TEXT)
	}
}

mint_units :: proc() {
	surfaces = niello.group_new("surfaces")
	texts = niello.group_new("texts")

	niello.mint(&window_u, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		color   = LIGHT_SURFACE,
		padding = [4]u16{24, 24, 24, 24},
		gap     = 16,
	})
	// The window takes only Color from the theme; its layout is its own.
	niello.group_add_masked(surfaces, niello.Fields{.Color}, window_u)

	// The title joins the texts group at mint, via decl.groups.
	niello.mint(&title_u, niello.NO_UNIT, {
		font_size  = 26,
		font_color = LIGHT_TEXT,
		groups     = []niello.Group{texts},
	})
	niello.mint(&hint_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.Color{140, 144, 156, 255}, // mid-grey: reads on both themes
	})
	niello.mint(&btn_label_u, niello.NO_UNIT, {
		font_size  = 16,
		font_color = niello.Color{230, 232, 238, 255},
	})
	niello.mint(&card_title_u, niello.NO_UNIT, {
		font_size  = 17,
		font_color = LIGHT_TEXT,
	})
	niello.mint(&card_body_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = LIGHT_TEXT,
	})
	// Card text follows the theme's Font_Color — and only that.
	niello.group_add_masked(texts, niello.Fields{.Font_Color}, card_title_u, card_body_u)

	niello.mint(&ov_hover_u, niello.NO_UNIT, {color = niello.Color{76, 82, 100, 255}})
	niello.mint(&ov_press_u, niello.NO_UNIT, {color = niello.Color{100, 108, 134, 255}})

	button := niello.Style_Decl{
		layout        = .Left_To_Right,
		color         = niello.Color{58, 62, 74, 255},
		corner_radius = 10,
		align         = [2]niello.Align_Kind{.Center, .Center},
		cursor        = niello.Cursor_Kind.Pointer,
		hover         = ov_hover_u,
		press         = ov_press_u,
	}
	theme_decl := button
	theme_decl.size = niello.Size{niello.fixed(210), niello.fixed(48)}
	niello.mint(&theme_btn_u, niello.NO_UNIT, theme_decl)

	add_decl := button
	add_decl.size = niello.Size{niello.fixed(150), niello.fixed(48)}
	niello.mint(&add_btn_u, niello.NO_UNIT, add_decl)

	danger_decl := button
	danger_decl.size = niello.Size{niello.grow(), niello.fixed(48)}
	danger_decl.color = DANGER_RED
	niello.mint(&danger_u, niello.NO_UNIT, danger_decl)
	// A full surfaces member — but its Color is pinned, so theme
	// broadcasts pass it by. It is still a live button (click it).
	niello.group_add(surfaces, danger_u)
	niello.pin(danger_u, niello.Fields{.Color})

	niello.mint(&row_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(48)},
		gap    = 12,
	})

	// Cards are born from this base: the light palette is their birth
	// value, whatever theme is active when they are minted.
	niello.mint(&card_base_u, niello.NO_UNIT, {
		layout        = .Top_To_Bottom,
		color         = LIGHT_SURFACE,
		corner_radius = 10,
		padding       = [4]u16{14, 14, 14, 14},
		gap           = 4,
		size          = niello.Size{niello.grow(), niello.fixed(64)},
	})
	for _ in 0 ..< 3 {
		card: niello.Unit
		niello.mint(&card, card_base_u)
		// Cards take only Color from the theme; their layout is their own.
		niello.group_add_masked(surfaces, niello.Fields{.Color}, card)
		append(&cards, card)
		append(&card_notes, "Born from the base unit at startup.")
	}
}

declare :: proc() {
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u, niello.key("title"), {text = "Groups — one broadcast, many components"})
		niello.show(hint_u, niello.key("hint"), {
			text = "Switch the theme, then add a card: it is born in the base palette, because joining a group applies nothing.",
		})

		if _, ok := niello.begin(row_u); ok {
			if ti, ok := niello.begin(theme_btn_u); ok {
				theme_i = ti
				if niello.clicked(ti) {
					dark = !dark
					apply_theme()
				}
				niello.show(btn_label_u, niello.key("theme"), {
					text = "Switch to light theme" if dark else "Switch to dark theme",
				})
			}
			if ai, ok := niello.begin(add_btn_u); ok {
				add_i = ai
				if niello.clicked(ai) && len(cards) < 6 {
					// Minted right now, from the base: light palette,
					// whatever the current theme is. It joins the group
					// for FUTURE broadcasts only.
					card: niello.Unit
					niello.mint(&card, card_base_u)
					niello.group_add_masked(surfaces, niello.Fields{.Color}, card)
					append(&cards, card)
					append(&card_notes, "Minted at runtime — it missed every broadcast so far. The next switch reaches it.")
				}
				niello.show(btn_label_u, niello.key("add"), {text = "Add a card"})
			}
			if di, ok := niello.begin(danger_u); ok {
				danger_i = di
				if niello.clicked(di) {
					danger_clicks += 1
				}
				niello.show(btn_label_u, niello.key("danger"), {
					text = fmt.tprintf("Danger — pinned red · clicked %d", danger_clicks),
				})
			}
		}

		for i in 0 ..< len(cards) {
			if _, ok := niello.begin(cards[i], niello.key_int(i)); ok {
				niello.show(card_title_u, 0, {text = fmt.tprintf("Card %d", i + 1)})
				niello.show(card_body_u, 0, {text = card_notes[i]})
			}
		}

		niello.show(hint_u, niello.key("status"), {
			text = fmt.tprintf("Theme: %s · %d cards · the danger button is a group member with Color pinned.",
				"dark" if dark else "light", len(cards)),
		})
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "Groups — NielloUI", width = 760, height = 600}, declare)
}
