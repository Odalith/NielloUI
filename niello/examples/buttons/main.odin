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
//	odin run niello/examples/buttons -extra-linker-flags:"-L..."
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
		color   = niello.Color{30, 32, 40, 255},
		padding = [4]u16{24, 24, 24, 24},
		gap     = 16,
	})
	niello.mint(&title_u, niello.NO_UNIT, {
		font_size  = 26,
		font_color = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&hint_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.Color{150, 154, 168, 255},
	})
	niello.mint(&label_u, niello.NO_UNIT, {
		font_size  = 16,
		font_color = niello.Color{230, 232, 238, 255},
	})

	// State overlays: only the fields they set are merged, with precedence
	// disabled > press > hover > focus > base.
	niello.mint(&ov_hover_u, niello.NO_UNIT, {color = niello.Color{64, 70, 90, 255}})
	niello.mint(&ov_press_u, niello.NO_UNIT, {color = niello.Color{92, 102, 130, 255}})
	niello.mint(&ov_disabled_u, niello.NO_UNIT, {color = niello.Color{44, 46, 52, 255}})

	button := niello.Style_Decl{
		layout        = .Left_To_Right,
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 10,
		align         = [2]niello.Align_Kind{.Center, .Center},
		cursor        = niello.Cursor_Kind.Pointer,
		hover         = ov_hover_u,
		press         = ov_press_u,
	}
	counter_decl := button
	counter_decl.size = niello.Size{niello.grow(), niello.fixed(56)}
	niello.mint(&counter_u, niello.NO_UNIT, counter_decl)

	niello.mint(&row_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(48)},
		gap    = 12,
	})
	toggle_decl := button
	toggle_decl.size = niello.Size{niello.fixed(230), niello.fixed(48)}
	niello.mint(&toggle_u, niello.NO_UNIT, toggle_decl)

	niello.mint(&swatch_u, niello.NO_UNIT, {
		size          = niello.Size{niello.fixed(48), niello.fixed(48)},
		color         = GREEN,
		corner_radius = 8,
	})

	disabled_decl := button
	disabled_decl.size = niello.Size{niello.grow(), niello.fixed(48)}
	disabled_decl.disabled = ov_disabled_u
	niello.mint(&disabled_u, niello.NO_UNIT, disabled_decl)

	niello.mint(&status_u, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.Color{170, 174, 188, 255},
	})
}

declare :: proc() {
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u, niello.key("title"), {text = "Buttons — polled input, no callbacks"})
		niello.show(hint_u, niello.key("hint"), {
			text = "Hover, press, drag off mid-press. The disabled button absorbs its clicks.",
		})

		if ci, ok := niello.begin(counter_u); ok {
			counter_i = ci
			// The handler is ordinary code next to the declaration: the
			// click completed at this frame's dispatch (frame_begin).
			if niello.clicked(ci) {
				count += 1
			}
			niello.show(label_u, niello.key("counter"), {
				text = fmt.tprintf("Clicked %d times — click me", count),
			})
		}

		if _, ok := niello.begin(row_u); ok {
			if ti, ok := niello.begin(toggle_u); ok {
				toggle_i = ti
				if niello.clicked(ti) {
					sound_on = !sound_on
					niello.set(swatch_u, .Color, GREEN if sound_on else GREY)
				}
				niello.show(label_u, niello.key("toggle"), {
					text = fmt.tprintf("Sound: %s", "on" if sound_on else "off"),
				})
			}
			niello.show(swatch_u)
			if di, ok := niello.begin(disabled_u, 0, {disabled = true}); ok {
				disabled_i = di
				niello.show(label_u, niello.key("disabled"), {
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
		niello.show(status_u, niello.key("status"), {text = status})
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "Buttons — NielloUI input", width = 720, height = 480}, declare)
}
