// Animate demo: the mutation layer (TODO #7) in one window.
//
//   - Crossfade theme: group_tween glides every surface/text member
//     toward a pose unit's style over 250ms (compare the groups demo,
//     where the same switch landed instantly via group_set).
//   - Cycle accent + propagate: the cards are minted FROM card_proto.
//     The button writes the proto's color and propagates; cards that
//     never set their own color follow, in one transitive push.
//   - Click a card: a transient pulse flashes that one instance
//     (in 120ms, out 240ms) — no unit changes, no other card moves.
//   - Glide the box: tween() walks a box between two pose units
//     (size + color); click again mid-glide and it retargets from
//     wherever it currently is.
package main

import "core:fmt"
import niello "../.."
import niello_sdl "../../sdl"

BG :: niello.Color{24, 25, 32, 255}
BTN :: niello.Color{52, 56, 72, 255}
BTN_HOVER :: niello.Color{66, 71, 90, 255}
BTN_PRESS :: niello.Color{40, 43, 56, 255}

LIGHT_SURFACE :: niello.Color{226, 228, 234, 255}
LIGHT_TEXT :: niello.Color{32, 34, 42, 255}
DARK_SURFACE :: niello.Color{43, 46, 56, 255}
DARK_TEXT :: niello.Color{232, 234, 240, 255}

ACCENTS := [3]niello.Color{
	{84, 120, 200, 255},
	{196, 110, 66, 255},
	{86, 160, 110, 255},
}

window_u, title_u, hint_u, label_u, status_u: niello.Unit
row_u, btn_u, btn_hover_u, btn_press_u, btn_label_u: niello.Unit
pose_light_u, pose_dark_u: niello.Unit
card_proto_u, card_title_u, card_body_u, flash_u: niello.Unit
box_u, pose_a_u, pose_b_u: niello.Unit

surfaces, texts: niello.Group

dark := true
accent_idx := 0
box_at_b := false
card_units: [3]niello.Unit
card_inst: [3]niello.Instance

mint :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = BG, padding = [4]u16{24, 24, 24, 24}, gap = 14,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 24, font_color = DARK_TEXT})
	niello.mint(&hint_u, niello.NO_UNIT, {font_size = 13.5, font_color = niello.Color{150, 154, 168, 255}})
	niello.mint(&label_u, niello.NO_UNIT, {font_size = 14})
	niello.mint(&status_u, niello.NO_UNIT, {font_size = 13.5, font_color = niello.Color{150, 154, 168, 255}})
	niello.mint(&row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right, gap = 12,
		size = niello.Size{niello.grow(), niello.fit()},
	})

	surfaces = niello.group_new("surfaces")
	texts = niello.group_new("texts")

	// Buttons: one shared scheme, themed through the groups.
	niello.mint(&btn_hover_u, niello.NO_UNIT, {color = BTN_HOVER})
	niello.mint(&btn_press_u, niello.NO_UNIT, {color = BTN_PRESS})
	niello.mint(&btn_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.fit(), niello.fixed(40)},
		padding = [4]u16{16, 0, 16, 0},
		align = [2]niello.Align_Kind{.Center, .Center},
		color = BTN, corner_radius = 8,
		hover = btn_hover_u, press = btn_press_u, cursor = niello.Cursor_Kind.Pointer,
		groups = []niello.Group{surfaces},
	})
	niello.mint(&btn_label_u, niello.NO_UNIT, {
		font_size = 14, font_color = DARK_TEXT,
		groups = []niello.Group{texts},
	})

	// Theme poses: style-only units a tween can aim at.
	niello.mint(&pose_light_u, niello.NO_UNIT, {color = LIGHT_SURFACE, font_color = LIGHT_TEXT})
	niello.mint(&pose_dark_u, niello.NO_UNIT, {color = DARK_SURFACE, font_color = DARK_TEXT})

	// Cards: minted from the proto, so propagate can restyle them.
	niello.mint(&card_proto_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(), niello.fixed(108)},
		padding = [4]u16{14, 12, 14, 12}, gap = 6,
		color = ACCENTS[0], corner_radius = 10,
	})
	niello.mint(&card_title_u, niello.NO_UNIT, {font_size = 16, font_color = DARK_TEXT, groups = []niello.Group{texts}})
	niello.mint(&card_body_u, niello.NO_UNIT, {font_size = 13, font_color = DARK_TEXT, groups = []niello.Group{texts}})
	// Note the cards are NOT surfaces members: their color belongs to
	// the accent/proto story below, and the theme must not fight it.
	// Their text still crossfades (card_title/card_body are in texts).
	for k in 0 ..< 3 {
		niello.mint(&card_units[k], card_proto_u)
	}
	// The flash: a transient unit — only its color participates.
	niello.mint(&flash_u, niello.NO_UNIT, {color = niello.Color{255, 255, 255, 255}})

	// The glide box and its two poses.
	niello.mint(&box_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(120), niello.fixed(56)},
		color = niello.Color{64, 130, 160, 255}, corner_radius = 10,
	})
	niello.mint(&pose_a_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(120), niello.fixed(56)},
		color = niello.Color{64, 130, 160, 255},
	})
	niello.mint(&pose_b_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(300), niello.fixed(56)},
		color = niello.Color{200, 120, 60, 255},
	})
	// Cards and buttons are born dark-themed; the window/panel stay
	// constant so the crossfade reads clearly. (Birth values come
	// from mint — groups apply nothing.)
	niello.set(btn_u, .Color, DARK_SURFACE)
}

button :: proc(key: string, text: string) -> niello.Instance {
	i, _ := niello.begin(btn_u, niello.key(key))
	niello.show(btn_label_u, 0, {text = text})
	return i
}

declare :: proc() {
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u, niello.key("title"), {text = "Animate — tweens, propagate, transients"})
		niello.show(hint_u, niello.key("hint"), {text = "Theme crossfades via group_tween. Accent cycles the card proto + propagate. Click a card for a transient flash."})

		if _, ok2 := niello.begin(row_u, niello.key("controls")); ok2 {
			theme_i := button("theme", "Crossfade theme")
			if niello.clicked(theme_i) {
				dark = !dark
				pose := dark ? pose_dark_u : pose_light_u
				niello.group_tween(surfaces, pose, 250, niello.Fields{.Color})
				niello.group_tween(texts, pose, 250, niello.Fields{.Font_Color})
			}
			accent_i := button("accent", "Cycle accent + propagate")
			if niello.clicked(accent_i) {
				accent_idx = (accent_idx + 1) % len(ACCENTS)
				niello.set(card_proto_u, .Color, ACCENTS[accent_idx])
				niello.propagate(card_proto_u, niello.Fields{.Color})
			}
			glide_i := button("glide", "Glide the box")
			if niello.clicked(glide_i) {
				box_at_b = !box_at_b
				niello.tween(box_u, box_at_b ? pose_b_u : pose_a_u, 300, niello.Fields{.Size, .Color})
			}
		}

		if _, ok3 := niello.begin(row_u, niello.key("cards")); ok3 {
			for k in 0 ..< 3 {
				if ci, ok4 := niello.begin(card_units[k], niello.key_int(k)); ok4 {
					card_inst[k] = ci
					niello.show(card_title_u, 0, {text = fmt.tprintf("Card %d", k + 1)})
					niello.show(card_body_u, 0, {text = "Minted from the proto. Click me."})
				}
				if niello.clicked(card_inst[k]) {
					niello.transient(card_inst[k], flash_u, 120, 240)
				}
			}
		}

		if _, ok5 := niello.begin(row_u, niello.key("boxrow")); ok5 {
			niello.show(box_u, niello.key("box"))
		}

		niello.show(status_u, niello.key("status"), {
			text = fmt.tprintf("theme %s · accent %d of %d · box at %s",
				dark ? "dark" : "light", accent_idx + 1, len(ACCENTS), box_at_b ? "B" : "A"),
		})
	}
}

main :: proc() {
	mint()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "NielloUI — animate", width = 780, height = 520}, declare)
}
