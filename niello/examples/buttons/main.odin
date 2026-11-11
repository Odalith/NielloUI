// niello/examples/buttons — the input demo: clickable controls with no
// callbacks anywhere.
//
// Everything is polled during declare against last frame's hit test:
// clicked() completes a press+release, pressed() holds through capture
// (drag off the button and it stays pressed), hovered()/hover_duration()
// track the cursor, and a disabled button absorbs clicks instead of
// letting them fall through. State overlays (hover/press/disabled) are
// units minted next to the buttons; the cursor comes from Style.cursor
// via Frame_Result.
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md):
//
//	odin run niello/examples/buttons
package main

import "core:fmt"
import niello "../.."
import niello_sdl "../../sdl"

// Cold units.
window_u:     niello.Unit
title_u:      niello.Unit
hint_u:       niello.Unit
label_u:      niello.Unit // shared by every button (per-instance text via With)
counter_u:    niello.Unit
row_u:        niello.Unit
toggle_u:     niello.Unit
swatch_u:     niello.Unit
disabled_u:   niello.Unit
status_u:     niello.Unit
ov_hover_u:   niello.Unit
ov_press_u:   niello.Unit
ov_disabled_u: niello.Unit

// App state. Handlers are just code inside declare that reads it.
count:     int
sound_on:  bool = true
counter_i, toggle_i, disabled_i: niello.Instance

GREEN :: niello.Color{86, 178, 110, 255}
GREY :: niello.Color{90, 94, 104, 255}

mint_units :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		color   = niello.rgb(0x1e2028),
		padding = niello.pad(24),
		gap     = 16,
	})
	niello.mint(&title_u, niello.NO_UNIT, {
		font_size  = 26,
		font_color = niello.rgb(0xf0f0f5),
	})
	niello.mint(&hint_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.rgb(0x969aa8),
	})
	niello.mint(&label_u, niello.NO_UNIT, {
		font_size  = 16,
		font_color = niello.rgb(0xe6e8ee),
	})

	// State overlays: only the fields they set are merged, with precedence
	// disabled > press > hover > focus > base.
	niello.mint(&ov_hover_u, niello.NO_UNIT, {color = niello.rgb(0x40465a)})
	niello.mint(&ov_press_u, niello.NO_UNIT, {color = niello.rgb(0x5c6682)})
	niello.mint(&ov_disabled_u, niello.NO_UNIT, {color = niello.rgb(0x2c2e34)})

	button := niello.Style_Decl{
		layout        = .Left_To_Right,
		color         = niello.rgb(0x2e323e),
		corner_radius = 10,
		align         = niello.CENTER,
		cursor        = niello.Cursor_Kind.Pointer,
		hover         = ov_hover_u,
		press         = ov_press_u,
	}
	counter_decl := button
	counter_decl.size = niello.size(niello.grow(), niello.fixed(56))
	niello.mint(&counter_u, niello.NO_UNIT, counter_decl)

	niello.mint(&row_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.size(niello.grow(), niello.fixed(48)),
		gap    = 12,
	})
	toggle_decl := button
	toggle_decl.size = niello.size(niello.fixed(230), niello.fixed(48))
	niello.mint(&toggle_u, niello.NO_UNIT, toggle_decl)

	niello.mint(&swatch_u, niello.NO_UNIT, {
		size          = niello.size(niello.fixed(48), niello.fixed(48)),
		color         = GREEN,
		corner_radius = 8,
	})

	disabled_decl := button
	disabled_decl.size = niello.size(niello.grow(), niello.fixed(48))
	disabled_decl.disabled = ov_disabled_u
	niello.mint(&disabled_u, niello.NO_UNIT, disabled_decl)

	niello.mint(&status_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.rgb(0xaaaebc),
	})
}

declare :: proc() {
	if niello.begin(window_u) {
		niello.show(title_u, {text = "Buttons — polled input, no callbacks"})
		niello.show(hint_u, {
			text = "Hover, press, drag off mid-press. The disabled button absorbs its clicks.",
		})

		if niello.begin(counter_u, out = &counter_i) {
			// The handler is ordinary code next to the declaration: the
			// click completed at this frame's dispatch (frame_begin).
			if niello.clicked(counter_i) {
				count += 1
			}
			niello.show(label_u, {
				text = fmt.tprintf("Clicked %d times — click me", count),
			})
		}

		if niello.begin(row_u) {
			if niello.begin(toggle_u, out = &toggle_i) {
				if niello.clicked(toggle_i) {
					sound_on = !sound_on
					niello.set(swatch_u, .Color, GREEN if sound_on else GREY)
				}
				niello.show(label_u, {
					text = fmt.tprintf("Sound: %s", "on" if sound_on else "off"),
				})
			}
			niello.show(swatch_u)
			if niello.begin(disabled_u, {disabled = true}, out = &disabled_i) {
				niello.show(label_u, {
					text = "Disabled — clicks stop here",
				})
			}
		}

		// A live readout of the queries, declared last so it can read the
		// instances this frame produced.
		status := "Move the mouse over the controls."
		if niello.pressed(counter_i) {
			status = "Counter pressed — capture holds it even off the button."
		} else if niello.hovered(disabled_i) {
			status = "Over the disabled button: it is the pick, and it absorbs."
		} else if niello.hovered(counter_i) {
			status = fmt.tprintf("Hovering the counter for %.1fs.", niello.hover_duration(counter_i))
		} else if niello.hovered(toggle_i) {
			status = "Over the toggle."
		}
		niello.show(status_u, {text = status})
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "Buttons — NielloUI input", width = 720, height = 480}, declare)
}
